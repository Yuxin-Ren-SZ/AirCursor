#!/usr/bin/env bash
# Builds build/AirCursor.app (universal: Apple silicon + Intel) and signs it.
#
#   scripts/build-app.sh                       # auto-picks a signing identity
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#   ARCHS=arm64 scripts/build-app.sh           # faster, single-arch
#
# Signing matters: macOS ties the Accessibility permission to the app's signature.
# With ad-hoc signing ("-"), every rebuild looks like a new app and you must
# re-grant Accessibility. An Apple Development or Developer ID identity avoids that.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AirCursor"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/${APP_NAME}.app"

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

echo "▸ Building ($CONFIG; $ARCHS)"
swift build -c "$CONFIG" "${arch_flags[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${arch_flags[@]}" --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Generating icon"
  swift scripts/make-icon.swift "$PWD"
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development)' | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▸ Signing with: $SIGN_IDENTITY"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --entitlements Resources/AirCursor.entitlements "$APP"
  echo "  (ad-hoc: you'll need to re-grant Accessibility after each rebuild)"
else
  codesign --force --options runtime --timestamp \
    --entitlements Resources/AirCursor.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "✓ Built $APP"
