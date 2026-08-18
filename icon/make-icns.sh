#!/bin/bash
# Assembles AppIcon.icns from AppIcon.appiconset.
#
# The slices are copied, never resampled. Each size in the set was exported for
# that size, and downscaling one master to all of them is measurably worse at 16
# and 32 — a 3D render loses its silhouette long before the pixels run out. No
# pngquant pass either: these are final art, and a lossy requantise is not this
# script's decision to make.
#
# Nothing to install: iconutil ships with macOS.
set -e

cd "$(dirname "$0")"
SET="AppIcon.appiconset"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# iconset slot <- the file in the set exported at that pixel size
slot() { cp "$SET/$2" "$ICONSET/$1.png"; }

slot icon_16x16        mac16.png
slot icon_16x16@2x     mac32.png
slot icon_32x32        mac32.png
slot icon_32x32@2x     mac64.png
slot icon_128x128      mac128.png
slot icon_128x128@2x   mac256.png
slot icon_256x256      mac256.png
slot icon_256x256@2x   mac512.png
slot icon_512x512      mac512.png
slot icon_512x512@2x   mac1024.png

# appstore1024.png is deliberately unused here: it is the opaque, full-bleed
# square the App Store wants, which is the wrong shape for a .icns.

iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote icon/AppIcon.icns ($(( $(stat -f%z AppIcon.icns) / 1024 )) KB)"
