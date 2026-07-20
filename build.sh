#!/bin/bash
# Builds Lightswitch.app into ./build (ad-hoc signed).
# Same construction as Key54's build.sh; no icon pipeline yet (TODO).
set -e

cd "$(dirname "$0")"

APP_NAME="Lightswitch"
BUILD_DIR="./build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

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
    -o "${BUILD_DIR}/Contents/MacOS/${APP_NAME}"

cp Info.plist "${BUILD_DIR}/Contents/Info.plist"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: ${SIGN_IDENTITY}"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "${BUILD_DIR}"
else
    codesign --force --deep --sign - "${BUILD_DIR}"
fi

echo "Built ${BUILD_DIR}"
