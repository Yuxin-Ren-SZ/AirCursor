#!/usr/bin/env bash
# Produces a notarized, stapled build/AirCursor-<version>.dmg for distribution.
#
# One-time setup:
#   xcrun notarytool store-credentials AirCursorNotary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Then:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=AirCursorNotary scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
[[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]] || { echo "Release builds need a Developer ID Application identity."; exit 1; }

swift test
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/AirCursor-${VERSION}.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/AirCursor.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AirCursor" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "▸ Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "✓ $DMG is ready to ship"
