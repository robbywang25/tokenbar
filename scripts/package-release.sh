#!/bin/bash
# Produce reviewable artifacts; this script does not publish or notarize them.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${TOKENBAR_DIST_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${TOKENBAR_SIGN_IDENTITY:--}"
SKIP_BUILD=false
CREATE_DMG=true
BUILD_ARGS=()
usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [--universal | --arch ARCH | --skip-build] [--no-dmg]

Builds TokenBar.app, packages ZIP and DMG, and writes SHA-256 checksums.
--skip-build packages the existing app (also useful after stapling its ticket).
--no-dmg produces a ZIP only. Build environment variables match build-app.sh.

These artifacts are not automatically notarized or published. See RELEASE.md.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) BUILD_ARGS+=(--universal); shift ;;
    --arch) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; BUILD_ARGS+=(--arch "$2"); shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --no-dmg) CREATE_DMG=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo "Packaging requires macOS." >&2; exit 1; }
case "$SIGN_IDENTITY" in
  -|"Developer ID Application: "*) ;;
  *) echo "Use a Developer ID Application identity, or - for a local ad-hoc build." >&2; exit 2 ;;
esac
if "$SKIP_BUILD"; then
  [[ ${#BUILD_ARGS[@]} -eq 0 ]] || { echo "--skip-build cannot be combined with architecture flags." >&2; exit 2; }
else
  if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
    "$ROOT_DIR/scripts/build-app.sh" "${BUILD_ARGS[@]}"
  else
    "$ROOT_DIR/scripts/build-app.sh"
  fi
fi

APP_PATH="$DIST_DIR/TokenBar.app"
[[ -d "$APP_PATH" ]] || { echo "Build TokenBar.app first." >&2; exit 1; }
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
[[ "$APP_ID" == wang.robby.tokenbar ]] || { echo "Unexpected app bundle identifier." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if "$SKIP_BUILD" && [[ "$SIGN_IDENTITY" != - ]]; then
  APP_AUTHORITY="$(codesign --display --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
  [[ "$APP_AUTHORITY" == "$SIGN_IDENTITY" ]] || { echo "The existing app must be signed with the requested Developer ID identity before release packaging." >&2; exit 1; }
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid bundle version." >&2; exit 2; }
ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/TokenBar")"
case "$ARCHITECTURES" in
  "arm64 x86_64"|"x86_64 arm64") ARCH_LABEL=universal ;;
  arm64|x86_64) ARCH_LABEL="$ARCHITECTURES" ;;
  *) echo "Unexpected binary architectures: $ARCHITECTURES" >&2; exit 1 ;;
esac
ARTIFACT_NAME="TokenBar-$VERSION-$ARCH_LABEL"
STAGE_DIR="$(mktemp -d "$DIST_DIR/.tokenbar-package.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAGE_DIR/$ARTIFACT_NAME.zip"
ARTIFACTS=("$ARTIFACT_NAME.zip")
if "$CREATE_DMG"; then
  mkdir -p "$STAGE_DIR/dmg"
  ditto "$APP_PATH" "$STAGE_DIR/dmg/TokenBar.app"
  ln -s /Applications "$STAGE_DIR/dmg/Applications"
  hdiutil create -volname TokenBar -srcfolder "$STAGE_DIR/dmg" -format UDZO "$STAGE_DIR/$ARTIFACT_NAME.dmg"
  if [[ "$SIGN_IDENTITY" != - ]]; then
    case "$SIGN_IDENTITY" in
      "Developer ID Application: "*) codesign --timestamp --sign "$SIGN_IDENTITY" "$STAGE_DIR/$ARTIFACT_NAME.dmg" ;;
      *) echo "Use a Developer ID Application identity to sign a release DMG." >&2; exit 2 ;;
    esac
  fi
  ARTIFACTS+=("$ARTIFACT_NAME.dmg")
fi
(
  cd "$STAGE_DIR"
  shasum -a 256 "${ARTIFACTS[@]}" > "$ARTIFACT_NAME-SHA256SUMS.txt"
)
for artifact in "${ARTIFACTS[@]}" "$ARTIFACT_NAME-SHA256SUMS.txt"; do
  mv -f "$STAGE_DIR/$artifact" "$DIST_DIR/$artifact"
  echo "Created $DIST_DIR/$artifact"
done
echo "Packaging complete. Public release still requires Developer ID signing, notarization, and release verification."
