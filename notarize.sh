#!/bin/bash
# Builds, notarizes and staples Liteswitch, then leaves a distributable zip in
# ./dist. Notarization is what stops Gatekeeper showing the "unidentified
# developer" warning on someone else's Mac — the Developer ID signature alone
# isn't enough.
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
ZIP="${DIST}/${APP_NAME}.zip"

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
# ditto, not zip: it preserves the bundle's symlinks and metadata.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple (this usually takes a minute or two)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Staple the ticket into the bundle so it validates offline, then re-zip so the
# distributed archive contains the stapled app.
xcrun stapler staple "$APP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "=== verification ==="
xcrun stapler validate "$APP"
spctl -a -vv "$APP"
echo
echo "Notarized: ${ZIP}"
