#!/bin/bash
# Build a standalone menu-bar app without Xcode project generation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${TOKENBAR_DIST_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${TOKENBAR_SIGN_IDENTITY:--}"
VERSION="${TOKENBAR_VERSION:-0.1.1}"
BUILD_NUMBER="${TOKENBAR_BUILD_NUMBER:-3}"
ARCHS=()

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--universal | --arch arm64 | --arch x86_64]

The default builds for this Mac and signs ad hoc for local use.
--universal builds a binary for Apple silicon and Intel Macs.

Optional environment variables:
  TOKENBAR_VERSION          Marketing version (default: 0.1.1)
  TOKENBAR_BUILD_NUMBER     Bundle build number (default: 3)
  TOKENBAR_DIST_DIR         Output directory (default: ./dist)
  TOKENBAR_SIGN_IDENTITY    Developer ID Application identity; default: -

A Developer ID signature alone does not notarize the app. See RELEASE.md.
EOF
}

case "${1:-}" in
  "") ARCHS=("$(uname -m)") ;;
  --universal) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; ARCHS=(arm64 x86_64) ;;
  --arch)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    case "$2" in arm64|x86_64) ARCHS=("$2") ;; *) usage >&2; exit 2 ;; esac
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

[[ "$(uname -s)" == Darwin ]] || { echo "TokenBar requires macOS to build." >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use a numeric version such as 0.1.0." >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Use a numeric bundle build number." >&2; exit 2; }
case "$SIGN_IDENTITY" in
  -|"Developer ID Application: "*) ;;
  *) echo "Use a Developer ID Application identity, or - for a local ad-hoc build." >&2; exit 2 ;;
esac
for tool in swift codesign plutil lipo iconutil; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool. Install Xcode Command Line Tools." >&2; exit 1; }
done

mkdir -p "$DIST_DIR"
STAGE_DIR="$(mktemp -d "$DIST_DIR/.tokenbar-build.XXXXXX")"
APP_PATH="$DIST_DIR/TokenBar.app"
cleanup() {
  if [[ -d "$STAGE_DIR/previous.app" && ! -e "$APP_PATH" ]]; then
    if ! mv "$STAGE_DIR/previous.app" "$APP_PATH"; then
      echo "Previous app retained at $STAGE_DIR/previous.app for recovery." >&2
      return
    fi
  fi
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT
STAGED_APP="$STAGE_DIR/TokenBar.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

BINARIES=()
for arch in "${ARCHS[@]}"; do
  BUILD_PATH="$ROOT_DIR/.build/bundle-$arch"
  swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_PATH" --configuration release --arch "$arch" --product TokenBar
  BIN_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_PATH" --configuration release --arch "$arch" --show-bin-path)"
  BINARIES+=("$BIN_DIR/TokenBar")
done
if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/TokenBar"
else
  cp "${BINARIES[0]}" "$STAGED_APP/Contents/MacOS/TokenBar"
fi
chmod 755 "$STAGED_APP/Contents/MacOS/TokenBar"
cp "$ROOT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
swift "$ROOT_DIR/scripts/generate-icon.swift" "$STAGE_DIR/TokenBar.iconset"
iconutil -c icns "$STAGE_DIR/TokenBar.iconset" -o "$STAGED_APP/Contents/Resources/TokenBar.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
plutil -lint "$STAGED_APP/Contents/Info.plist"

if [[ "$SIGN_IDENTITY" == - ]]; then
  codesign --force --sign - "$STAGED_APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGED_APP"
fi
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -e "$APP_PATH" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$EXISTING_ID" == wang.robby.tokenbar ]] || { echo "Refusing to replace an unrelated TokenBar.app." >&2; exit 1; }
  mv "$APP_PATH" "$STAGE_DIR/previous.app"
fi
mv "$STAGED_APP" "$APP_PATH"
echo "Built $APP_PATH"
echo "Architectures: $(lipo -archs "$APP_PATH/Contents/MacOS/TokenBar")"
if [[ "$SIGN_IDENTITY" == - ]]; then
  echo "Local preview: ad-hoc signed, not notarized for public distribution."
else
  echo "Developer ID signed. Complete notarization and Gatekeeper verification before release."
fi
