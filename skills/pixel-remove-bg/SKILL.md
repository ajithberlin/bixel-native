---
name: pixel-remove-bg
description: Remove the background from pixel-art and game-asset images to get transparent PNGs — flat AI backgrounds, white studio backgrounds, or chroma-key colors like pure magenta #FF00FF / green screen. Use when the user says "remove background", "make it transparent", "cut out this sprite", "delete the white/green/magenta background", "transparent PNG", or an image generation came back opaque and needs keying before use in an engine. Handles edge-connected flood removal (keeps enclosed holes), chroma-key removal, halo/fringe cleanup, and batch processing of whole folders.
---

# Remove Background

Deterministic background removal via `scripts/remove_bg.py`. Image-generation
skills must request real alpha first; use this skill when the provider returns
an opaque fallback or when an existing image needs a cutout.

## Quick start

```bash
# flat AI background (any color, auto-detected from the border)
python3 scripts/remove_bg.py in.png out.png

# chroma key (magenta / green screen / any hex)
python3 scripts/remove_bg.py in.png out.png --mode key --color FF00FF

# white studio background
python3 scripts/remove_bg.py in.png out.png --mode white

# generated chroma fallback (keys every matching pixel, including enclosed ones)
python3 scripts/remove_bg.py in.png out.png --mode key --color 00FF00 --despill
```

## Mode selection

| Situation | Mode |
|---|---|
| Flat/near-flat bg, subject does NOT touch the image edge | `auto` (default) |
| Known key color, or bg color also appears INSIDE the subject | `key --color HEX` |
| White/light studio bg | `white` (or `auto`) |
| Busy gradient/photo bg | This script won't work — re-generate the asset on a flat bg |

`auto` only removes background **connected to the image border** — an enclosed hole that matches the bg color (e.g. inside a ring) is correctly KEPT. `key` removes the color everywhere, including interior holes.

## Tuning

- `--tolerance 32` default. Raise (40–60) when the AI bg has subtle noise/vignette; lower (16–24) when the subject edge color is close to the bg.
- Leftover colored halo around the subject → add `--despill`, or `--feather 1` to bite 1px into the edge.
- Subject accidentally touches the border → that region leaks into the subject; switch to `key` mode with the sampled bg color instead.

For AI-generated no-background assets, use `key --color 00FF00` for the
requested green fallback or `key --color FF00FF` for the magenta fallback.
Do not deliver the opaque keyed source as the final sprite; verify that the
clean output has background pixels with alpha=0.

## Batch

```bash
for f in ./raw/*.png; do
  python3 scripts/remove_bg.py "$f" "./clean/$(basename "$f")" --tolerance 40
done
```

## After removal

- Verify: load the output, check alpha coverage (`np.asarray(im)[...,3]`) — expected subject % matches, no alpha holes inside the silhouette.
- For pixel-art pipelines, follow with the pixel-reduce-colors skill to normalize the palette (transparent pixels are normalized to RGBA 0,0,0,0 by reduce_colors).
