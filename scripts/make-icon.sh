#!/bin/bash
# Regenerates Tower's own app icon and menu-bar glyph from the SVG sources:
#   Resources/AppIcon/AppIcon.svg       -> Resources/AppIcon/AppIcon.icns (via an .iconset)
#   Resources/StatusGlyph/TowerGlyph.svg -> Resources/StatusGlyph/TowerGlyph.png, TowerGlyph@2x.png
# Needs Google Chrome (headless, throwaway profile; it never opens your own browser),
# plus sips and iconutil, which ship with macOS. Run it after changing either SVG and
# commit the outputs: build-app.sh copies them and does not render anything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="${TOWER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tower-make-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$CHROME" ]; then
  echo "Chrome not found at $CHROME (set TOWER_CHROME)" >&2
  exit 1
fi

# One SVG to one transparent PNG at 1024 px. A fresh --user-data-dir keeps it off any
# real profile; the PNG is then scaled down with sips, which keeps the alpha channel.
render_1024() {
  local svg="$1" out="$2"
  printf '%s\n' \
    '<!doctype html><html><head><style>' \
    'html,body{margin:0;padding:0;background:transparent;width:1024px;height:1024px;overflow:hidden}' \
    'img{display:block;width:1024px;height:1024px}' \
    "</style></head><body><img src=\"file://$svg\"></body></html>" > "$WORK/page.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$WORK/profile" --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$out" "file://$WORK/page.html" > "$WORK/chrome.log" 2>&1
  if [ ! -s "$out" ]; then
    echo "render failed for $svg:" >&2
    cat "$WORK/chrome.log" >&2
    exit 1
  fi
}

scale() {
  local src="$1" px="$2" out="$3"
  sips -z "$px" "$px" "$src" --out "$out" > "$WORK/sips.log" 2>&1 || { cat "$WORK/sips.log" >&2; exit 1; }
}

echo "==> app icon"
render_1024 "$ROOT/Resources/AppIcon/AppIcon.svg" "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  scale "$WORK/icon-1024.png" "$size" "$ICONSET/icon_${size}x${size}.png"
  scale "$WORK/icon-1024.png" "$((size * 2))" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$ROOT/Resources/AppIcon/AppIcon.icns" "$ICONSET"
echo "   wrote Resources/AppIcon/AppIcon.icns"

echo "==> menu-bar glyph (template: black on transparent, 18 pt)"
render_1024 "$ROOT/Resources/StatusGlyph/TowerGlyph.svg" "$WORK/glyph-1024.png"
scale "$WORK/glyph-1024.png" 18 "$ROOT/Resources/StatusGlyph/TowerGlyph.png"
scale "$WORK/glyph-1024.png" 36 "$ROOT/Resources/StatusGlyph/TowerGlyph@2x.png"
echo "   wrote Resources/StatusGlyph/TowerGlyph.png and TowerGlyph@2x.png"
