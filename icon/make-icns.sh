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

# No 512x512@2x slice, same as Key54. That one rendering is ~940KB — most of the
# .icns on its own — and only the App Store and Finder's maximum Get Info zoom
# ever ask for it. A background agent with no Dock icon renders neither, so it is
# weight with nothing on the other side of the scale. mac1024.png stays in the set
# because it is part of the artwork; it just isn't packed.
#
# appstore1024.png is unused here for a different reason: it is the opaque,
# full-bleed square the App Store wants, which is the wrong shape for a .icns.

iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote icon/AppIcon.icns ($(( $(stat -f%z AppIcon.icns) / 1024 )) KB)"
