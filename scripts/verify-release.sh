#!/bin/sh
# Read-only release gates. Never signs, staples, submits, or reads credentials.
exec python3 - "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile

APP_ID = "wang.robby.tokenbar"
WIDGET_ID = APP_ID + ".widget"
DEVELOPER_ID_REQUIREMENT = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
MAX_ZIP_FILES = 2048
MAX_ZIP_BYTES = 512 * 1024 * 1024


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def run(arguments, label, timeout=60):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    require(result.returncode == 0, label + " failed (exit " + str(result.returncode) + ")")
    return result


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def plist(path):
    with path.open("rb") as handle:
        return plistlib.load(handle)


def signing_details(path, team, architecture=None, runtime=False):
    command = ["codesign", "--display", "--verbose=4"]
    if architecture:
        command += ["--architecture", architecture]
    text = run(command + [str(path)], "Signature metadata").stderr.decode("utf-8", errors="replace")
    require(re.search(r"^Authority=Developer ID Application: .+$", text, re.M),
            "Developer ID Application signature required: " + path.name)
    require(re.search(r"^TeamIdentifier=" + re.escape(team) + r"$", text, re.M), "Signing Team ID mismatch")
    require(re.search(r"^Timestamp=.+$", text, re.M), "Secure signing timestamp missing")
    if runtime:
        flags = re.search(r"\bflags=0x([0-9a-fA-F]+)", text)
        require(flags is not None and int(flags.group(1), 16) & 0x10000, "Hardened Runtime missing")
    return text


def verify_signature(path):
    run(["codesign", "--verify", "--deep", "--strict", "--all-architectures",
         "--test-requirement", "=" + DEVELOPER_ID_REQUIREMENT, str(path)], "Developer ID trust and signature verification")


def entitlements(path, architecture):
    result = run(["codesign", "--display", "--architecture", architecture,
                  "--entitlements", "-", "--xml", str(path)], "Entitlements read")
    return plistlib.loads(result.stdout)


def verify_app(app, team):
    require(app.is_dir() and not app.is_symlink(), "An existing, nonsymlink .app is required")
    info = plist(app / "Contents/Info.plist")
    require(info.get("CFBundleIdentifier") == APP_ID, "Unexpected application bundle ID")
    require(info.get("CFBundleExecutable") == "TokenBar" and info.get("LSUIElement") is True, "Unexpected application executable or menu-bar mode")
    version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid application version")
    require(isinstance(build, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build), "Invalid build number")
    widget = app / "Contents/PlugIns/TokenBarWidget.appex"
    require(widget.is_dir() and not widget.is_symlink(), "The release must include the native WidgetKit extension")
    widget_info = plist(widget / "Contents/Info.plist")
    require(widget_info.get("CFBundleIdentifier") == WIDGET_ID and widget_info.get("CFBundleExecutable") == "TokenBarWidget", "Unexpected widget identity")
    require(widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension", "Wrong widget extension point")
    require(widget_info.get("CFBundleShortVersionString") == version and widget_info.get("CFBundleVersion") == build, "Application and widget versions differ")
    group = team + "." + APP_ID
    for bundle, metadata, executable, sandboxed in [(app, info, "TokenBar", False), (widget, widget_info, "TokenBarWidget", True)]:
        binary = bundle / "Contents/MacOS" / executable
        require(metadata.get("TokenBarAppGroup") == group, "App Group metadata mismatch")
        require(metadata.get("LSMinimumSystemVersion") == "14.0", "Bundle minimum macOS version must match the advertised macOS 14 support")
        architectures = run(["lipo", "-archs", str(binary)], "Binary architectures").stdout.decode().split()
        require(set(architectures) == {"arm64", "x86_64"} and len(architectures) == 2, "Release must contain both arm64 and x86_64")
        for architecture in architectures:
            signing_details(bundle, team, architecture, runtime=True)
            rights = entitlements(bundle, architecture)
            expected = {"com.apple.security.application-groups": [group]}
            if sandboxed:
                expected["com.apple.security.app-sandbox"] = True
            require(rights == expected, "Unexpected or missing release entitlements; review before distribution")
            # Check the actual load command, not just the Info.plist promise.
            load = run(["xcrun", "vtool", "-arch", architecture, "-show-build", str(binary)], "Mach-O deployment target").stdout.decode()
            require(re.search(r"\bplatform MACOS\b", load), "Binary is not built for macOS")
            minimum = re.search(r"\bminos ([0-9.]+)", load)
            require(minimum is not None and tuple(int(n) for n in minimum.group(1).split(".")) <= (14, 0, 0), "Binary deployment target exceeds macOS 14")
        verify_signature(bundle)
    symbols = run(["xcrun", "nm", "-u", str(widget / "Contents/MacOS/TokenBarWidget")], "Widget entry-point reference").stdout
    require(b"_NSExtensionMain" in symbols, "Widget binary lacks the application-extension entry point")
    return {"version": version, "build": build, "teamIdentifier": team, "architectures": ["arm64", "x86_64"], "widget": True}


def verify_ticket(path):
    run(["xcrun", "stapler", "validate", str(path)], "Stapled notarization ticket validation")


def pre_notary_policy(app):
    require(shutil.which("syspolicy_check") is not None, "syspolicy_check is required for notarization readiness verification")
    readiness = subprocess.run(["syspolicy_check", "notary-submission", str(app)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if readiness.returncode == 0:
        return "notary-submission-ready"
    # A signed candidate has not received its notarization ticket yet. Classify
    # only this independently confirmed expected state; every other error fails.
    assessment = subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose=4", str(app)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    result = (assessment.stdout + b"\n" + assessment.stderr).decode("utf-8", errors="replace")
    require(assessment.returncode == 3 and
            re.search(r"^source=Unnotarized Developer ID$", result, re.M) is not None,
            "Notarization readiness failed for a reason other than a pending notarization ticket")
    return "notarization-pending"


def verify_checksums(checksums, archive, image):
    require(checksums.is_file() and not checksums.is_symlink(), "A checksum file is required")
    require(checksums.stat().st_size <= 4096, "Unexpected checksum file size")
    rows = checksums.read_text().splitlines()
    expected = {archive.name: archive, image.name: image}
    require(len(rows) == 2, "Checksum file must list exactly the final ZIP and DMG")
    seen = set()
    for row in rows:
        match = re.fullmatch(r"([0-9a-f]{64}) [ *]([^/\\]+)", row)
        require(match is not None, "Invalid SHA-256 row or nonlocal filename")
        checksum, name = match.groups()
        require(name in expected and name not in seen, "Unexpected or duplicate checksum target")
        require(sha256(expected[name]) == checksum, "Final SHA-256 mismatch: " + name)
        seen.add(name)
    require(seen == set(expected), "Incomplete checksum set")


def validate_zip(archive):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        require(0 < len(entries) <= MAX_ZIP_FILES, "Unexpected ZIP entry count")
        total, seen = 0, set()
        for entry in entries:
            require(entry.orig_filename == entry.filename, "ZIP filename was truncated or rewritten")
            name = entry.filename.rstrip("/")
            parts = name.split("/")
            require(name and "\\" not in name and not PurePosixPath(name).is_absolute() and
                    all(part not in ("", ".", "..") for part in parts), "Unsafe ZIP path")
            require(parts[0] in ("TokenBar.app", "__MACOSX"), "Unexpected ZIP root")
            key = unicodedata.normalize("NFD", name).casefold()
            require(key not in seen, "Duplicate or filesystem-colliding ZIP path")
            seen.add(key)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR), "ZIP links or special files are forbidden")
            require(kind != stat.S_IFDIR or entry.is_dir(), "ZIP directory metadata contradicts its path")
            require(not entry.flag_bits & 1, "Encrypted ZIP is not a release artifact")
            total += entry.file_size
            require(total <= MAX_ZIP_BYTES, "ZIP expands beyond the release verification limit")
            if not entry.is_dir():
                actual = 0
                with source.open(entry) as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        actual += len(chunk)
                        require(actual <= entry.file_size, "ZIP entry exceeds its declared size")
                require(actual == entry.file_size, "ZIP entry size mismatch")
        require("tokenbar.app/contents/info.plist" in seen, "ZIP contains no TokenBar application")


def tree_manifest(root):
    result = {}
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "Unexpected symlink in release application")
        info = path.stat()
        require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode), "Unexpected special file in application")
        result[str(path.relative_to(root))] = ("directory" if path.is_dir() else sha256(path), stat.S_IMODE(info.st_mode))
    return result


def verify_artifacts(args, metadata):
    app, archive, image, checksums = map(Path, (args.app, args.zip, args.dmg, args.checksums))
    expected_name = "TokenBar-" + metadata["version"] + "-universal-widget"
    require(archive.name == expected_name + ".zip" and image.name == expected_name + ".dmg", "Final artifact filenames do not match the widget release version")
    for path in (archive, image):
        require(path.is_file() and not path.is_symlink(), "Missing or symlinked release artifact")
    verify_checksums(checksums, archive, image)
    validate_zip(archive)
    signing_details(image, args.team_id)
    verify_signature(image)
    verify_ticket(app)
    verify_ticket(image)
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], "Application Gatekeeper assessment")
    run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(image)], "DMG Gatekeeper assessment")
    require(shutil.which("syspolicy_check") is not None, "syspolicy_check is required for final distribution verification")
    run(["syspolicy_check", "distribution", str(app)], "Modern macOS distribution assessment")
    expected_tree = tree_manifest(app)
    scratch = Path(tempfile.mkdtemp(prefix="tokenbar-release-verify-"))
    mount = scratch / "mount"
    try:
        extracted = scratch / "zip"
        extracted.mkdir()
        run(["ditto", "-x", "-k", str(archive), str(extracted)], "Safe release ZIP extraction")
        zipped_app = extracted / "TokenBar.app"
        require(tree_manifest(zipped_app) == expected_tree, "ZIP application differs from the verified application")
        require(verify_app(zipped_app, args.team_id) == metadata, "ZIP application metadata differs")
        verify_ticket(zipped_app)
        run(["hdiutil", "verify", str(image)], "Disk image integrity", timeout=120)
        mount.mkdir()
        run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(image)], "Read-only DMG mount")
        mounted_app = mount / "TokenBar.app"
        require(tree_manifest(mounted_app) == expected_tree, "DMG application differs from the verified application")
        require(verify_app(mounted_app, args.team_id) == metadata, "DMG application metadata differs")
        verify_ticket(mounted_app)
    finally:
        if os.path.ismount(str(mount)):
            run(["hdiutil", "detach", str(mount)], "Read-only DMG detach")
        # Do not attempt recursive cleanup if detaching failed.
        shutil.rmtree(scratch)
    # Verification did not change either deliverable; also catch concurrent edits.
    verify_checksums(checksums, archive, image)


def main():
    parser = argparse.ArgumentParser(description="Verify a Developer ID-signed TokenBar widget release without signing or submitting anything.")
    parser.add_argument("--app", required=True)
    parser.add_argument("--team-id", required=True, help="Expected 10-character Developer Team ID")
    parser.add_argument("--pre-notary", action="store_true", help="Only verify application readiness before notarization")
    parser.add_argument("--dmg")
    parser.add_argument("--zip")
    parser.add_argument("--checksums")
    args = parser.parse_args()
    try:
        require(sys.platform == "darwin", "Verification requires macOS")
        require(re.fullmatch(r"[A-Z0-9]{10}", args.team_id), "Invalid expected Team ID")
        if args.pre_notary:
            require(not any((args.dmg, args.zip, args.checksums)), "--pre-notary only accepts --app and --team-id")
        else:
            require(all((args.dmg, args.zip, args.checksums)), "Final verification requires --dmg, --zip, and --checksums")
        metadata = verify_app(Path(args.app).absolute(), args.team_id)
        if args.pre_notary:
            policy_status = pre_notary_policy(Path(args.app).absolute())
        else:
            verify_artifacts(args, metadata)
            policy_status = "notarization-verified"
        print(json.dumps(dict(metadata, verification="pre-notary" if args.pre_notary else "final-distribution",
                              policyStatus=policy_status, passed=True)))
        return 0
    except (VerificationError, OSError, ValueError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print("ERROR: " + (str(error) if isinstance(error, VerificationError) else type(error).__name__), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
PY
