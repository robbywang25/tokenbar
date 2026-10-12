#!/bin/bash
# Build a standalone menu-bar app without Xcode project generation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${TOKENBAR_DIST_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${TOKENBAR_SIGN_IDENTITY:--}"
VERSION="${TOKENBAR_VERSION:-0.2.4}"
BUILD_NUMBER="${TOKENBAR_BUILD_NUMBER:-14}"
ARCHS=()
WITH_WIDGET=false

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--universal | --arch arm64 | --arch x86_64] [--with-widget]

The default builds for this Mac and signs ad hoc for local use.
--universal builds a binary for Apple silicon and Intel Macs.
--with-widget embeds WidgetKit and requires a real Apple Development or
Developer ID Application signing identity. Ad-hoc builds stay menu-bar-only.

Optional environment variables:
  TOKENBAR_VERSION          Marketing version (default: 0.2.4)
  TOKENBAR_BUILD_NUMBER     Bundle build number (default: 14)
  TOKENBAR_DIST_DIR         Output directory (default: ./dist)
  TOKENBAR_SIGN_IDENTITY    Apple Development / Developer ID Application; default: -

A Developer ID signature alone does not notarize the app. See RELEASE.md.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      [[ ${#ARCHS[@]} -eq 0 ]] || { usage >&2; exit 2; }
      ARCHS=(arm64 x86_64); shift ;;
    --arch)
      [[ $# -ge 2 && ${#ARCHS[@]} -eq 0 ]] || { usage >&2; exit 2; }
      case "$2" in arm64|x86_64) ARCHS=("$2") ;; *) usage >&2; exit 2 ;; esac
      shift 2 ;;
    --with-widget) WITH_WIDGET=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ ${#ARCHS[@]} -gt 0 ]] || ARCHS=("$(uname -m)")

[[ "$(uname -s)" == Darwin ]] || { echo "TokenBar requires macOS to build." >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use a numeric version such as 0.1.0." >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Use a numeric bundle build number." >&2; exit 2; }
case "$SIGN_IDENTITY" in
  -|"Developer ID Application"|"Developer ID Application: "*|"Apple Development"|"Apple Development: "*) ;;
  *) echo "Use Apple Development, Developer ID Application, or - for a local ad-hoc build." >&2; exit 2 ;;
esac
if "$WITH_WIDGET" && [[ "$SIGN_IDENTITY" == - ]]; then
  echo "--with-widget requires TOKENBAR_SIGN_IDENTITY. Ad-hoc signing cannot authorize the shared App Group." >&2
  exit 2
fi
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
SIGNING_AUTHORITY=""
SIGNING_TEAM=""
if [[ "$SIGN_IDENTITY" != - ]]; then
  # Ask codesign which certificate actually signs a harmless temporary copy.
  # The parenthesized identity suffix is not necessarily the Developer Team ID.
  cp /usr/bin/true "$STAGE_DIR/signing-probe"
  codesign --force --sign "$SIGN_IDENTITY" "$STAGE_DIR/signing-probe"
  SIGNING_DETAILS="$(codesign --display --verbose=4 "$STAGE_DIR/signing-probe" 2>&1)"
  SIGNING_AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$SIGNING_DETAILS" | head -n 1)"
  SIGNING_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<< "$SIGNING_DETAILS")"
  case "$SIGNING_AUTHORITY" in
    "Apple Development: "*|"Developer ID Application: "*) ;;
    *) echo "The selected certificate is not an Apple Development or Developer ID Application identity." >&2; exit 1 ;;
  esac
  [[ "$SIGNING_TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "Signing identity has no valid Developer Team ID." >&2; exit 1; }
fi

if "$WITH_WIDGET"; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
  [[ -d "$SDK_PATH/System/Library/Frameworks/WidgetKit.framework" ]] || { echo "The selected macOS SDK does not contain WidgetKit." >&2; exit 1; }
  shopt -s nullglob
  SHARED_SOURCES=("$ROOT_DIR"/Shared/*.swift)
  WIDGET_SOURCES=("$ROOT_DIR"/WidgetExtension/*.swift)
  shopt -u nullglob
  [[ ${#SHARED_SOURCES[@]} -gt 0 && ${#WIDGET_SOURCES[@]} -gt 0 ]] || { echo "Widget and shared Swift sources are required." >&2; exit 1; }
fi
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
/usr/libexec/PlistBuddy -c "Add :DTSDKName string macosx$(xcrun --sdk macosx --show-sdk-version)" "$STAGED_APP/Contents/Info.plist"
plutil -lint "$STAGED_APP/Contents/Info.plist"

if "$WITH_WIDGET"; then
  APP_GROUP="$SIGNING_TEAM.wang.robby.tokenbar"
  WIDGET_PATH="$STAGED_APP/Contents/PlugIns/TokenBarWidget.appex"
  mkdir -p "$WIDGET_PATH/Contents/MacOS" "$WIDGET_PATH/Contents/Resources"
  cp "$ROOT_DIR/Resources/WidgetInfo.plist" "$WIDGET_PATH/Contents/Info.plist"
  cp "$STAGED_APP/Contents/Resources/TokenBar.icns" "$WIDGET_PATH/Contents/Resources/TokenBar.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$WIDGET_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$WIDGET_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :DTSDKName string macosx$(xcrun --sdk macosx --show-sdk-version)" "$WIDGET_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TokenBarAppGroup string $APP_GROUP" "$STAGED_APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TokenBarAppGroup string $APP_GROUP" "$WIDGET_PATH/Contents/Info.plist"
  cp "$ROOT_DIR/Resources/TokenBar.entitlements" "$STAGE_DIR/TokenBar.entitlements"
  cp "$ROOT_DIR/Resources/Widget.entitlements" "$STAGE_DIR/Widget.entitlements"
  for name in TokenBar Widget; do
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $APP_GROUP" "$STAGE_DIR/$name.entitlements"
  done

  WIDGET_BINARIES=()
  for arch in "${ARCHS[@]}"; do
    WIDGET_BINARY="$STAGE_DIR/TokenBarWidget-$arch"
    # Match Xcode's app-extension entry point. The default Swift executable
    # entry point can register successfully yet fail to provide widget descriptors.
    xcrun swiftc -sdk "$SDK_PATH" -target "$arch-apple-macos14.0" \
      -parse-as-library -application-extension -O -module-name TokenBarWidget \
      -Xlinker -e -Xlinker _NSExtensionMain \
      -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
      -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
      "${SHARED_SOURCES[@]}" "${WIDGET_SOURCES[@]}" -o "$WIDGET_BINARY"
    WIDGET_BINARIES+=("$WIDGET_BINARY")
  done
  if [[ ${#WIDGET_BINARIES[@]} -gt 1 ]]; then
    lipo -create "${WIDGET_BINARIES[@]}" -output "$WIDGET_PATH/Contents/MacOS/TokenBarWidget"
  else
    cp "${WIDGET_BINARIES[0]}" "$WIDGET_PATH/Contents/MacOS/TokenBarWidget"
  fi
  chmod 755 "$WIDGET_PATH/Contents/MacOS/TokenBarWidget"
  plutil -lint "$WIDGET_PATH/Contents/Info.plist"
  WIDGET_SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY" --entitlements "$STAGE_DIR/Widget.entitlements")
  if [[ "$SIGNING_AUTHORITY" == "Developer ID Application: "* ]]; then WIDGET_SIGN_ARGS+=(--timestamp); fi
  codesign "${WIDGET_SIGN_ARGS[@]}" "$WIDGET_PATH"
  codesign --verify --strict --verbose=2 "$WIDGET_PATH"
fi

if [[ "$SIGN_IDENTITY" == - ]]; then
  codesign --force --sign - "$STAGED_APP"
else
  APP_SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
  if [[ "$SIGNING_AUTHORITY" == "Developer ID Application: "* ]]; then APP_SIGN_ARGS+=(--timestamp); fi
  if "$WITH_WIDGET"; then APP_SIGN_ARGS+=(--entitlements "$STAGE_DIR/TokenBar.entitlements"); fi
  codesign "${APP_SIGN_ARGS[@]}" "$STAGED_APP"
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
elif [[ "$SIGNING_AUTHORITY" == "Apple Development: "* ]]; then
  echo "Apple Development signed: local development/testing only, not a notarized public release."
else
  echo "Developer ID signed. Complete notarization and Gatekeeper verification before release."
fi
if "$WITH_WIDGET"; then
  echo "Includes WidgetKit extension; install and open the containing app before checking the system widget gallery."
else
  echo "Menu-bar-only build; no desktop widget extension is embedded."
fi
