---
name: pixel-reduce-colors
description: Reduce the color count of pixel-art / game-asset images to a fixed palette — palette quantization with alpha preservation, fixed custom palettes for project-wide consistency, and palette reporting. Use when the user says "reduce colors", "limit to 16 colors", "quantize this sprite", "make it Game Boy / NES palette", "apply our game palette", "how many colors does this use", or AI-generated pixel art has hundreds of anti-aliased colors that must collapse to a crisp retro palette.
---

# Reduce Colors

Deterministic palette reduction via `scripts/reduce_colors.py`. Alpha is fully preserved; dithering is OFF by default (correct for pixel art).

## Quick start

```bash
# auto palette of 16 colors
python3 scripts/reduce_colors.py in.png out.png --colors 16

# project palette (keeps every asset consistent)
python3 scripts/reduce_colors.py in.png out.png --palette "#1a1c2c,#5d275d,#b13e53,#ef7d57,#ffcd75"

# palette from an existing sprite / palette strip image
python3 scripts/reduce_colors.py in.png out.png --palette hero.png --report palette.json
```

## Choosing the color count

| Target feel | Colors |
|---|---|
| Game Boy | 4 |
| NES-ish sprite | 8 (per sprite) |
| SNES / GBA | 16 |
| Modern "HD pixel art" | 24–32 |

Check the current count first (the script prints it) — AI "pixel art" often has 200–2000 colors from anti-aliasing; reducing to 16–32 restores the crisp look.

## Rules

- **Dither**: keep `--dither none`. Floyd–Steinberg dithering adds noise patterns that read as dirt on sprites; use it only for gradients in backgrounds, never on characters.
- **Fixed palette for a project**: extract once from the best asset (`--report palette.json`), then apply with `--palette` to everything else. This is the only way separate AI generations match.
- **Transparent pixels** stay transparent and are normalized to RGBA (0,0,0,0) — safe to run after background removal.
- Resizing must happen BEFORE reduction if needed, always nearest-neighbor — never reduce colors after a smooth resample, that just re-creates the anti-aliasing.

## Verify

Re-run the script on the output (or open `palette.json`): printed count ≤ target. If the count is still high, the input had an alpha-gradient or JPEG noise — flatten/clean it first (see pixel-remove-bg).
