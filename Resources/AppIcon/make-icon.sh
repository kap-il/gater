#!/bin/sh
# Renders AppIcon.svg to PNGs with headless Chrome, builds the .iconset,
# and packs AppIcon.icns with iconutil. Run from anywhere.
set -eu
dir="$(cd "$(dirname "$0")" && pwd)"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
work="${TMPDIR:-/tmp}/g8r-icon.$$"
mkdir -p "$work/AppIcon.iconset"
"$chrome" --headless=new --disable-gpu --hide-scrollbars \
  --screenshot="$work/icon-1024.png" --window-size=1024,1024 \
  --default-background-color=00000000 "file://$dir/AppIcon.svg" >/dev/null 2>&1
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z $s $s "$work/icon-1024.png" --out "$work/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $d $d "$work/icon-1024.png" --out "$work/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$dir/AppIcon.icns"
mkdir -p "$dir/png"
cp "$work/icon-1024.png" "$dir/png/icon-1024.png"
cp "$work/AppIcon.iconset/icon_32x32.png" "$dir/png/icon-32.png"
rm -rf "$work"
echo "Wrote $dir/AppIcon.icns"
