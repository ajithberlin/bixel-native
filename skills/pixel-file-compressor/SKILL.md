---
name: pixel-file-compressor
description: Crop the blank/whitespace/transparent margins off an image, then downscale it to a small target resolution (e.g. from 1600x1600 down to 32x32) using high-quality Lanczos resampling, and save it with optimized compression. Use this whenever the user wants to shrink an image down to a small icon, thumbnail, favicon, or avatar size; wants to "compress an image," "reduce the pixels/resolution," "trim the white space," "crop the edges," or "make a small high-quality version" of an image; or is preparing app icons, sprite assets, or profile thumbnails from a larger source image. Trigger even if they only give a target size like "32x32" or "64x64" without saying "crop" explicitly — cropping to content first is what keeps a tiny output looking sharp instead of shrinking the subject into a speck.
---

# Image Thumbnail Compressor

## Why crop before downscaling

When someone shrinks a 1600x1600 image straight down to 32x32, whatever
blank canvas surrounds the subject — white background, transparent padding,
a solid color border — gets crushed down along with everything else. That
wastes pixels the output desperately needs: at 32x32 you only have ~1,000
pixels total, and if a third of the source canvas was empty margin, a third
of your tiny output is empty too, and the actual subject is smaller and
blurrier than it needs to be.

Finding the real content first, cropping to *just* that, and then
downscaling means every pixel of the small output is spent on the subject.
This is the standard trick behind favicon/app-icon generators, and it's the
approach `scripts/compress_image.py` automates.

## Workflow

1. **Look at the source image first** (via the `view` tool or by opening it)
   before running anything. Confirm there actually *is* a blank margin to
   crop — a full-bleed photograph with no border shouldn't be auto-cropped,
   since there's no "blank" to find and the detector could clip real
   content if the edges happen to be a near-uniform color (sky, a wall,
   skin tone, etc).

2. **Run the script**:
   ```bash
   python3 scripts/compress_image.py INPUT OUTPUT --size 32x32
   ```
   This crops to content, downscales with Lanczos resampling (the
   highest-quality standard downsampling filter — it band-limits the image
   before reducing it, avoiding the aliasing/moiré you get from naive
   nearest-neighbor shrinking), and saves with format-appropriate maximum
   compression (PNG: `optimize=True` + max compress level, lossless; JPEG/WebP:
   `optimize=True` + quality 90 by default).

3. **Check the result** with `view` on the output file — at 32x32 it's easy
   to eyeball whether the crop caught the right region and the subject
   still reads clearly. If the crop looks wrong (too tight, too loose, or
   it cropped into real content), adjust `--tolerance` (see below) and
   rerun rather than accepting a bad result.

4. Only present/deliver the final output file — don't leave intermediate
   crops lying around as separate deliverables.

## Key options

| Flag | Default | When to change it |
|---|---|---|
| `--size WxH` | `32x32` | Any target resolution, e.g. `--size 64x64`, `--size 256x256` |
| `--tolerance N` | `12` | Raise (e.g. `25-40`) if the background isn't perfectly flat — JPEG noise, a subtle gradient, or a scanned page — and the crop is coming out too tight or too loose. Lower it if the crop is eating into the actual subject because the subject shares a color with the background. |
| `--fit pad\|stretch` | `pad` | `pad` preserves the subject's aspect ratio and centers it on a transparent (or solid) canvas of exactly the requested size — use this almost always. `stretch` forces the exact size by distorting aspect ratio; only use this if the user explicitly wants that (e.g. filling a fixed non-square UI slot and distortion is acceptable). |
| `--canvas-color` | transparent (if alpha) else white | Set a specific pad color, e.g. `--canvas-color 255,255,255` or `--canvas-color 0,0,0`, if the user wants a specific background instead of transparency. |
| `--no-crop` | off | The image has no blank margin at all (full-bleed photo) and should just be resized as-is. |
| `--format` | inferred from output extension | Force `png` (lossless, best for icons/logos/flat art with transparency or sharp edges), `jpeg` (smaller for photographic content, no transparency), or `webp` (good compression with optional transparency). |
| `--quality N` | `90` | Lossy quality for jpeg/webp. Lower only if the user explicitly wants a smaller file over top quality. |

## Format guidance

- **Logos, icons, flat-color art, screenshots, anything with transparency or
  sharp edges/text** → PNG. Lossless, and at icon sizes the file is tiny
  anyway.
- **Photographs with no transparency need** → JPEG or WebP at quality ~85-90
  is usually smaller with no visible quality loss at these dimensions.
- If the user just says "compress it as much as possible," PNG is still
  usually right for icon-sized output (the file is already only a few KB);
  don't sacrifice visible quality chasing bytes that don't matter at this
  size. If they want a specific format, honor that instead.

## Edge cases

- **No background could be detected** (e.g. the corners aren't a
  consistent color, or the whole image is one texture): the script prints
  `Cropped to content box: (skipped — ...)` and resizes the full canvas
  instead of guessing wrong. Don't force a crop in this case — ask the user
  or just resize as-is.
- **Multiple distinct blobs of content** (e.g. a few icons scattered on one
  canvas): the bounding box will span all of them, which is usually the
  right call for a "trim the margins" request. If the user actually wants
  just one specific subject isolated, that's object-level cropping, which
  is a different task than margin-trimming — clarify with the user rather
  than guessing which blob they mean.
- **Non-square source cropped to a square target** (or vice versa): with
  the default `--fit pad`, the aspect ratio is preserved and the leftover
  space is padded, so nothing gets stretched.
