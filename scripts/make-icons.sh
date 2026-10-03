#!/bin/bash
# Regenerates the icon assets from the SVG sources in assets/:
#   assets/icon.svg -> assets/icon.png (1024 px) and assets/AppIcon.icns (16-512 pt at @1x and @2x)
#   assets/mark.svg -> assets/mark@2x.png (36 px) and assets/mark-1x.svg -> assets/mark.png (18 px): the menu bar
#   template image at 18 pt. The @1x version is drawn on the pixel grid, since the full mark blurs at 18 px
# Every size is rendered straight from the SVG (no downscaling). Requires rsvg-convert (`brew install librsvg`)
# and iconutil (part of macOS). The generated files are committed, so `make app` doesn't need either tool.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert > /dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

render assets/icon.svg 1024 assets/icon.png
render assets/mark-1x.svg 18 assets/mark.png
render assets/mark.svg 36 assets/mark@2x.png

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  render assets/icon.svg "$SIZE" "$ICONSET/icon_${SIZE}x${SIZE}.png"
  render assets/icon.svg "$((SIZE * 2))" "$ICONSET/icon_${SIZE}x${SIZE}@2x.png"
done
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"

echo "generated: assets/icon.png assets/AppIcon.icns assets/mark.png assets/mark@2x.png"
