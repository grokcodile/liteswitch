#!/bin/bash
# Builds Liteswitch.app into ./build, signed with your Developer ID when there is
# one. That matters for more than distribution: macOS ties Accessibility and
# Screen Recording to the signing identity, so an ad-hoc build — which gets a new
# identity every time — has to be re-granted after every rebuild. A stable
# Developer ID signature means the permissions are granted once and stay.
set -e

cd "$(dirname "$0")"

APP_NAME="Liteswitch"
BUILD_DIR="./build/${APP_NAME}.app"

# Use SIGN_IDENTITY if set, otherwise pick up a Developer ID from the keychain.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}"

echo "Building ${APP_NAME}..."

rm -rf ./build
mkdir -p "${BUILD_DIR}/Contents/MacOS"
mkdir -p "${BUILD_DIR}/Contents/Resources"

# Spotlight's four-panel UI is macOS 26+, so unlike Key54 there is no reason
# to target anything older.
swiftc -O main.swift \
    -target "$(uname -m)-apple-macos26.0" \
    -framework Cocoa \
    -framework Carbon \
    -framework ServiceManagement \
    -framework Vision \
    -framework IOKit \
    -framework FoundationModels \
    -o "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${BUILD_DIR}/Contents/Info.plist"
cp icon/AppIcon.icns "${BUILD_DIR}/Contents/Resources/AppIcon.icns"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing: ${SIGN_IDENTITY}"
    # --options runtime is the hardened runtime, which notarization requires.
    # --timestamp gets a trusted timestamp, so the signature outlives the cert.
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
    codesign --verify --strict --verbose=1 "${BUILD_DIR}"
else
    echo "No Developer ID found — signing ad-hoc."
    echo "  (macOS will forget this app's permissions on every rebuild.)"
    codesign --force --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
