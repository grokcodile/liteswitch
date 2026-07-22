#!/bin/bash
# Regenerates AppIcon.icns from AppIcon.svg. Requires librsvg (brew install librsvg).
#
# Size choices, for a menu-bar-less background agent:
#   • No 1024px (512x512@2x) slice. That one rendering is ~half the icns and is
#     only shown by the App Store and Finder's max "Get Info" zoom — never by an
#     agent with no Dock icon. Dropping it halves the file with no visible loss.
#   • If pngquant is installed, a lossy palette pass shrinks the gradient-heavy
#     PNGs by another ~40% with no perceptible banding. Skipped (with a note) if
#     pngquant is absent, so the build still works everywhere — just larger.
set -e

cd "$(dirname "$0")"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

render() { rsvg-convert -w "$1" -h "$1" AppIcon.svg -o "$ICONSET/$2.png"; }

render 16   icon_16x16
render 32   icon_16x16@2x
render 32   icon_32x32
render 64   icon_32x32@2x
render 128  icon_128x128
render 256  icon_128x128@2x
render 256  icon_256x256
render 512  icon_256x256@2x
render 512  icon_512x512

if command -v pngquant >/dev/null 2>&1; then
    for f in "$ICONSET"/*.png; do
        pngquant --quality=70-92 --force --output "$f" "$f" || true
    done
else
    echo "note: pngquant not found — skipping lossy optimization (icns will be larger)."
fi

iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote icon/AppIcon.icns ($(( $(stat -f%z AppIcon.icns) / 1024 )) KB)"
