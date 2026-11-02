#!/usr/bin/env bash
# Copy product icons from the apps installed on this Mac into Resources/BrandMarks,
# so a local build shows the same marks the Dock shows.
#
# The repository ships no product icons: they are the marks of other companies
# and are not covered by Tower's license. Extracted files are git-ignored and
# only reach a bundle built with TOWER_BRAND_MARKS=local (the default for
# scripts/build-app.sh). Apps that are not installed are skipped; their rows
# fall back to a two-letter tile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/BrandMarks"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# name|icns path inside /Applications
MARKS=(
  "claude|Claude.app/Contents/Resources/electron.icns"
  "chatgpt|ChatGPT.app/Contents/Resources/app.icns"
  "cursor|Cursor.app/Contents/Resources/Cursor.icns"
  "antigravity|Antigravity.app/Contents/Resources/icon.icns"
  "devin|Devin.app/Contents/Resources/Devin.icns"
)

found=0
for entry in "${MARKS[@]}"; do
  name="${entry%%|*}"
  icns="/Applications/${entry#*|}"
  if [ ! -f "$icns" ]; then
    echo "skip  $name (not installed: $icns)"
    continue
  fi
  iconutil -c iconset "$icns" -o "$WORK/$name.iconset"
  src="$WORK/$name.iconset/icon_128x128.png"
  if [ ! -f "$src" ]; then
    echo "skip  $name (no 128 px rep in $icns)"
    continue
  fi
  cp "$src" "$OUT/$name@2x.png"
  sips -Z 64 "$src" --out "$OUT/$name.png" >/dev/null
  echo "ok    $name"
  found=$((found + 1))
done
echo "extracted $found of ${#MARKS[@]} marks into $OUT"
