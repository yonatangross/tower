#!/bin/bash
# Checks a built Tower.app carries Tower's own icon: Info.plist names AppIcon, the
# .icns and the menu-bar glyph are in Contents/Resources, and no vendor BrandMarks ship.
# Usage: scripts/test-bundle-icon.sh [path/to/Tower.app]   (default: dist/Tower.app)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Tower.app}"
PLIST="$APP/Contents/Info.plist"
RES="$APP/Contents/Resources"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tower-icon-check.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
failures=0

pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1${2:+ ($2)}"; failures=$((failures + 1)); }

# The value of one Info.plist key, or empty with plutil's own error kept for the report.
plist_value() {
  local out
  if out="$(plutil -extract "$1" raw "$PLIST" 2>&1)"; then
    printf '%s' "$out"
  else
    printf 'plutil %s: %s\n' "$1" "$out" >> "$SCRATCH/plutil.log"
  fi
}

if [ ! -f "$PLIST" ]; then
  echo "no bundle at $APP (run scripts/build-app.sh first)" >&2
  exit 2
fi

for key in CFBundleIconFile CFBundleIconName; do
  value="$(plist_value "$key")"
  if [ "$value" = "AppIcon" ]; then pass "Info.plist $key is AppIcon"; else fail "Info.plist $key is AppIcon" "got '${value}'"; fi
done

if [ -s "$RES/AppIcon.icns" ] && [ "$(head -c 4 "$RES/AppIcon.icns")" = "icns" ]; then
  pass "Contents/Resources/AppIcon.icns exists and is an icns file"
else
  fail "Contents/Resources/AppIcon.icns exists and is an icns file"
fi

if iconutil -c iconset -o "$SCRATCH/AppIcon.iconset" "$RES/AppIcon.icns" > "$SCRATCH/iconutil.log" 2>&1 \
  && [ -f "$SCRATCH/AppIcon.iconset/icon_512x512@2x.png" ]; then
  pass "AppIcon.icns carries a 1024 px (512@2x) image"
else
  fail "AppIcon.icns carries a 1024 px (512@2x) image" "$(tr '\n' ' ' < "$SCRATCH/iconutil.log")"
fi

if [ -s "$RES/TowerGlyph.png" ] && [ -s "$RES/TowerGlyph@2x.png" ]; then
  pass "the menu-bar glyph ships at 1x and 2x"
else
  fail "the menu-bar glyph ships at 1x and 2x"
fi

if [ ! -e "$RES/BrandMarks/AppIcon.icns" ]; then
  pass "the icon is Tower's own, not under BrandMarks"
else
  fail "the icon is Tower's own, not under BrandMarks"
fi

if [ -s "$SCRATCH/plutil.log" ]; then sed 's/^/  /' "$SCRATCH/plutil.log"; fi
if [ "$failures" -eq 0 ]; then
  echo "bundle icon: all passed"
else
  echo "bundle icon: $failures failed"
  exit 1
fi
