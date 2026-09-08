---
name: pixel-file-compressor
description: Reduce game-asset image file sizes significantly — palette quantization of AI-generated PNGs (typically 60-90% smaller), pixel-art-safe downscaling, WebP conversion, and batch folder compression with per-file and total savings reports. Use when the user says "reduce file size", "compress these assets", "PNGs are too big", "optimize images", "make the files smaller", "shrink the spritesheet", or AI-generated art produces multi-megabyte PNGs that must fit an engine build, web bundle, or upload limit.
---

# Asset File-Size Reducer & Compressor

Deterministic compression via `scripts/compress_asset.py`. Alpha always preserved; never grows a file (falls back to the original when re-encoding doesn't help).

## Quick start

```bash
python3 scripts/compress_asset.py hero.png                    # safe default
python3 scripts/compress_asset.py --dir ./assets --out ./small   # batch
```

## Why AI files are huge — and the fix, in order of impact

1. **Thousands of hidden colors.** AI "pixel art" is 32-bit RGBA with anti-aliasing noise (60k+ colors is normal). The default mode quantizes to ≤256 colors (PNG palette mode): **typically 60–80% smaller, visually identical**. Verify by eye at 100% zoom; if banding appears on a gradient, use `--lossless` instead (bit-exact, but only ~3–10% savings).
2. **Pixel-art palettes.** If the asset went through pixel-reduce-colors, pass the same count (`--colors 16/32`): **~90% smaller**.
3. **Resolution.** `--scale 0.5 --pixel-art` (NEAREST — never smooth-resample pixel art): quarters the pixels, **~97% combined** with palette.
4. **WebP.** `--format webp --quality 85` beats PNG further, but check the pipeline first — Tiled/Flame default flows expect PNG; WebP is fine for web builds and most modern engines.

## Workflow

1. Run on one representative file first; read the printed `before -> after (-%)`.
2. Eyeball the output at 100% zoom (quantization banding on gradients is the only real risk).
3. Batch the folder; report the TOTAL line to the user.
4. Files that report `-0%` were already optimal — say so, don't re-run.

## Rules

- Never use `--scale` without `--pixel-art` for sprites (smooth resampling destroys crisp pixels and re-adds hundreds of colors).
- After compression, re-verify downstream assumptions: palette-mode PNGs report `mode: P` — some engines' editors show this as "8-bit indexed", which is fine.
- For sprite SHEETS, compress the final packed sheet, not the frames (packing after compression re-expands files and can misalign).
