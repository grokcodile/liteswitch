#!/bin/bash
# Builds, notarizes and staples Liteswitch, then leaves a distributable disk
# image in ./dist. Notarization is what stops Gatekeeper showing the
# "unidentified developer" warning on someone else's Mac — the Developer ID
# signature alone isn't enough.
#
# This mirrors what .github/workflows/release.yml does on a tag; it exists for
# building a release by hand when CI isn't an option.
#
# One-time setup (this stores an app-specific password in your keychain, so it
# has to be run by you rather than by a script):
#
#   xcrun notarytool store-credentials liteswitch \
#       --apple-id "you@example.com" \
#       --team-id 8UP5SFXY56
#
# It asks for an app-specific password — make one at appleid.apple.com under
# Sign-In and Security. Not your Apple ID password.
set -e

cd "$(dirname "$0")"

APP_NAME="Liteswitch"
APP="./build/${APP_NAME}.app"
PROFILE="${NOTARY_PROFILE:-liteswitch}"
DIST="./dist"
ZIP="${DIST}/${APP_NAME}-submit.zip"
DMG="${DIST}/${APP_NAME}.dmg"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials found for profile '${PROFILE}'."
    echo "Run this once, then try again:"
    echo
    echo "  xcrun notarytool store-credentials ${PROFILE} \\"
    echo "      --apple-id \"you@example.com\" --team-id 8UP5SFXY56"
    echo
    exit 1
fi

./build.sh

# Signing must be a real Developer ID, not ad-hoc, or notarization refuses it.
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "TeamIdentifier=8UP5SFXY56"; then
    echo "Not signed with a Developer ID — nothing to notarize." >&2
    exit 1
fi

mkdir -p "$DIST"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and metadata. This archive
# is only a carrier for the notary service — the DMG is what ships.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting the app to Apple (this usually takes a minute or two)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
# Staple the ticket into the bundle so it validates offline. Has to happen
# before the DMG is built, so the image carries an already-stapled app.
xcrun stapler staple "$APP"
rm -f "$ZIP"

# A disk image with an Applications symlink, so opening it gives the
# drag-across window rather than a loose app in Downloads.
rm -rf "${DIST}/dmgroot" "$DMG"
mkdir -p "${DIST}/dmgroot"
cp -R "$APP" "${DIST}/dmgroot/"
ln -s /Applications "${DIST}/dmgroot/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DIST}/dmgroot" \
    -ov -format UDZO "$DMG"
rm -rf "${DIST}/dmgroot"

# The image is notarized in its own right: stapling the app stops Gatekeeper
# complaining about the app, stapling the image stops it complaining about the
# image someone just downloaded.
echo "Submitting the disk image..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo
echo "=== verification ==="
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl -a -vv "$APP"
shasum -a 256 "$DMG"
echo
echo "Notarized: ${DMG}"
