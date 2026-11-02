# BrandMarks

Product icons for seat and lane rows (Claude, ChatGPT, Cursor, Antigravity,
Devin). They are the trademarks of their owners, so this repository ships none.

To show them in a local build, copy them from the apps installed on your Mac:

```bash
scripts/extract-brand-marks.sh
scripts/build-app.sh
```

The script runs `iconutil` on each installed app's `.icns`, keeps the 128 px
rep as `<name>@2x.png` and a 64 px copy as `<name>.png`. Extracted files are
git-ignored. Release builds use `TOWER_BRAND_MARKS=off` and never include them.
Without them every row shows a two-letter tile.
