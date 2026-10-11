#!/bin/bash
# Produce reviewable artifacts; this script does not publish or notarize them.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${TOKENBAR_DIST_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${TOKENBAR_SIGN_IDENTITY:--}"
SKIP_BUILD=false
CREATE_DMG=true
WITH_WIDGET=false
BUILD_ARGS=()
usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [--universal | --arch ARCH | --skip-build] [--with-widget] [--no-dmg]

Builds TokenBar.app, packages ZIP and DMG, and writes SHA-256 checksums.
--skip-build packages the existing app (also useful after stapling its ticket).
--no-dmg produces a ZIP only. Build environment variables match build-app.sh.
--with-widget requires a real signing identity when building, or checks that an
existing --skip-build app contains a consistently signed WidgetKit extension.
Widget packages have a -widget suffix; Apple Development adds -development.

These artifacts are not automatically notarized or published. See RELEASE.md.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal) BUILD_ARGS+=(--universal); shift ;;
    --arch) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; BUILD_ARGS+=(--arch "$2"); shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --with-widget) WITH_WIDGET=true; shift ;;
    --no-dmg) CREATE_DMG=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo "Packaging requires macOS." >&2; exit 1; }
case "$SIGN_IDENTITY" in
  -|"Developer ID Application"|"Developer ID Application: "*|"Apple Development"|"Apple Development: "*) ;;
  *) echo "Use Apple Development, Developer ID Application, or - for a local ad-hoc build." >&2; exit 2 ;;
esac
if "$SKIP_BUILD"; then
  [[ ${#BUILD_ARGS[@]} -eq 0 ]] || { echo "--skip-build cannot be combined with architecture flags." >&2; exit 2; }
else
  if "$WITH_WIDGET"; then BUILD_ARGS+=(--with-widget); fi
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
APP_SIGNING="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
APP_AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$APP_SIGNING" | head -n 1)"
APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<< "$APP_SIGNING")"
if "$SKIP_BUILD" && [[ "$SIGN_IDENTITY" != - ]]; then
  case "$SIGN_IDENTITY" in
    "Apple Development"|"Developer ID Application")
      [[ "$APP_AUTHORITY" == "$SIGN_IDENTITY: "* ]] || { echo "The existing app has a different signing identity type." >&2; exit 1; } ;;
    *) [[ "$APP_AUTHORITY" == "$SIGN_IDENTITY" ]] || { echo "The existing app must use the requested signing identity before packaging." >&2; exit 1; } ;;
  esac
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid bundle version." >&2; exit 2; }
ARCHITECTURES="$(lipo -archs "$APP_PATH/Contents/MacOS/TokenBar")"
case "$ARCHITECTURES" in
  "arm64 x86_64"|"x86_64 arm64") ARCH_LABEL=universal ;;
  arm64|x86_64) ARCH_LABEL="$ARCHITECTURES" ;;
  *) echo "Unexpected binary architectures: $ARCHITECTURES" >&2; exit 1 ;;
esac
STAGE_DIR="$(mktemp -d "$DIST_DIR/.tokenbar-package.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
WIDGET_PATH="$APP_PATH/Contents/PlugIns/TokenBarWidget.appex"
WIDGET_SUFFIX=""
if [[ -d "$WIDGET_PATH" ]]; then
  case "$APP_AUTHORITY" in
    "Apple Development: "*|"Developer ID Application: "*) ;;
    *) echo "An embedded widget requires a real Apple Development or Developer ID signature." >&2; exit 1 ;;
  esac
  [[ "$APP_TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "The widget host has no valid signing Team ID." >&2; exit 1; }
  codesign --verify --strict --verbose=2 "$WIDGET_PATH"
  WIDGET_SIGNING="$(codesign --display --verbose=4 "$WIDGET_PATH" 2>&1)"
  WIDGET_AUTHORITY="$(sed -n 's/^Authority=//p' <<< "$WIDGET_SIGNING" | head -n 1)"
  WIDGET_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<< "$WIDGET_SIGNING")"
  [[ "$WIDGET_AUTHORITY" == "$APP_AUTHORITY" && "$WIDGET_TEAM" == "$APP_TEAM" ]] || { echo "Host and widget must have the same signing identity and Team ID." >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET_PATH/Contents/Info.plist")" == wang.robby.tokenbar.widget ]] || { echo "Unexpected widget bundle identifier." >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$WIDGET_PATH/Contents/Info.plist")" == com.apple.widgetkit-extension ]] || { echo "The extension is not a WidgetKit extension." >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WIDGET_PATH/Contents/Info.plist")" == "$VERSION" ]] || { echo "Host and widget versions differ." >&2; exit 1; }
  APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WIDGET_PATH/Contents/Info.plist")" == "$APP_BUILD" ]] || { echo "Host and widget build numbers differ." >&2; exit 1; }
  [[ "$(lipo -archs "$WIDGET_PATH/Contents/MacOS/TokenBarWidget")" == "$ARCHITECTURES" ]] || { echo "Host and widget architectures differ." >&2; exit 1; }
  APP_GROUP="$APP_TEAM.wang.robby.tokenbar"
  for bundle in "$APP_PATH" "$WIDGET_PATH"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :TokenBarAppGroup' "$bundle/Contents/Info.plist")" == "$APP_GROUP" ]] || { echo "Host and widget App Group metadata is inconsistent." >&2; exit 1; }
    codesign --display --entitlements :- "$bundle" > "$STAGE_DIR/entitlements.plist" 2>/dev/null
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$STAGE_DIR/entitlements.plist")" == "$APP_GROUP" ]] || { echo "Missing shared App Group entitlement." >&2; exit 1; }
  done
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$STAGE_DIR/entitlements.plist")" == true ]] || { echo "Widget sandbox entitlement is required." >&2; exit 1; }
  WIDGET_SUFFIX="-widget"
elif "$WITH_WIDGET"; then
  echo "--with-widget was requested, but the existing app contains no widget extension." >&2
  exit 1
fi
DEVELOPMENT_SUFFIX=""
if [[ "$APP_AUTHORITY" == "Apple Development: "* ]]; then DEVELOPMENT_SUFFIX="-development"; fi
ARTIFACT_NAME="TokenBar-$VERSION-$ARCH_LABEL$WIDGET_SUFFIX$DEVELOPMENT_SUFFIX"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAGE_DIR/$ARTIFACT_NAME.zip"
ARTIFACTS=("$ARTIFACT_NAME.zip")
if "$CREATE_DMG"; then
  mkdir -p "$STAGE_DIR/dmg"
  ditto "$APP_PATH" "$STAGE_DIR/dmg/TokenBar.app"
  ln -s /Applications "$STAGE_DIR/dmg/Applications"
  hdiutil create -volname TokenBar -srcfolder "$STAGE_DIR/dmg" -format UDZO "$STAGE_DIR/$ARTIFACT_NAME.dmg"
  if [[ "$SIGN_IDENTITY" != - ]]; then
    # Only Developer ID signs a distribution image. Apple Development artifacts
    # remain explicitly labeled local testing packages.
    if [[ "$APP_AUTHORITY" == "Developer ID Application: "* ]]; then
      codesign --timestamp --sign "$SIGN_IDENTITY" "$STAGE_DIR/$ARTIFACT_NAME.dmg"
    fi
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
if [[ -n "$DEVELOPMENT_SUFFIX" ]]; then echo "Development package: local testing only; do not publish as a general-use signed installer."; fi
