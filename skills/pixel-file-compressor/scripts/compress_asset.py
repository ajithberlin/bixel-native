#!/usr/bin/env python3
"""Shrink AI-generated game-asset files significantly, pixel-art safe.

Biggest wins, in order:
  1. Palette quantization  - AI PNGs are 24/32-bit with thousands of colors;
     mapping to <=256 colors (P mode) alone cuts 60-80% with no visible change.
  2. Downscale             - --scale 0.5 with NEAREST keeps pixel art crisp.
  3. WebP                  - for engines/platforms that allow it (not Tiled/Flame
     default pipelines); lossless WebP still beats PNG, lossy beats everything.
  4. Re-encode             - optimize=True + stripped metadata (always on).

Alpha is always preserved; fully transparent pixels are normalized so they
never waste palette entries.

Usage:
  python3 compress_asset.py hero.png                       # safe default: quantize+optimize
  python3 compress_asset.py ui.png --colors 32             # pixel-art palette
  python3 compress_asset.py bg.png --scale 0.5
  python3 compress_asset.py big.png --format webp --quality 85
  python3 compress_asset.py --dir ./assets --out ./small   # batch, keeps names
"""
import argparse
import glob
import os
import shutil
import sys

import numpy as np
from PIL import Image


def unique_colors(im):
    return len(im.convert("RGB").getcolors(im.width * im.height) or [None]) or 257


def quantize(im, colors):
    rgb = im.convert("RGB")
    alpha = np.asarray(im)[..., 3]
    q = rgb.quantize(colors=min(colors, 256), method=Image.FASTOCTREE,
                     dither=Image.NONE)
    out = np.array(q.convert("RGBA"))
    out[..., 3] = alpha
    out[alpha == 0] = (0, 0, 0, 0)
    return Image.fromarray(out, "RGBA")


def process(src, dst, args):
    before = os.path.getsize(src)
    im = Image.open(src).convert("RGBA")

    if args.scale != 1.0:
        w, h = max(1, int(im.width * args.scale)), max(1, int(im.height * args.scale))
        im = im.resize((w, h), Image.NEAREST if args.pixel_art else Image.LANCZOS)

    n_colors = unique_colors(im)
    if args.colors:
        im = quantize(im, args.colors)
    elif not args.lossless and n_colors > 256:
        im = quantize(im, 256)  # default: AI art -> palette mode, visually identical

    fmt = args.format.lower()
    if fmt == "webp":
        if args.quality >= 100 or args.lossless:
            im.save(dst, "WEBP", lossless=True, quality=100, method=6)
        else:
            im.save(dst, "WEBP", quality=args.quality, method=6)
    else:
        alpha = np.asarray(im)[..., 3]
        semi = ((alpha > 0) & (alpha < 255)).mean()  # fraction of soft-edge pixels
        # P mode (palette) compresses ~4x better than RGBA; safe when alpha is binary
        if im.mode == "RGBA" and unique_colors(im) <= 256 and semi < 0.001:
            q = im.convert("RGB").quantize(colors=255, method=Image.FASTOCTREE,
                                           dither=Image.NONE)
            idx = np.where(alpha > 0, np.array(q), 255).astype(np.uint8)
            pim = Image.fromarray(idx, "P")
            pim.putpalette(q.getpalette()[: 255 * 3] + [0, 0, 0])  # idx 255 = transparent
            pim.save(dst, "PNG", optimize=True, transparency=255)
        else:
            im.save(dst, "PNG", optimize=True)

    # guard: never grow a file — keep the original when re-encoding didn't help
    if fmt == "png" and dst.lower().endswith(".png") and os.path.getsize(dst) >= before:
        shutil.copy2(src, dst)

    after = os.path.getsize(dst)
    saved = 100.0 * (1 - after / max(before, 1))
    print(f"  {os.path.basename(src)}: {before/1024:.0f}K -> {after/1024:.0f}K "
          f"(-{saved:.0f}%) [{n_colors} colors]")
    return before, after


def main():
    p = argparse.ArgumentParser(description="Compress game-asset images significantly.")
    p.add_argument("files", nargs="*")
    p.add_argument("--dir", help="batch: folder of images")
    p.add_argument("--pattern", default="*.png")
    p.add_argument("--out", help="output folder (batch) or file (single)")
    p.add_argument("--colors", type=int, default=0, help="force palette size (e.g. 16/32)")
    p.add_argument("--scale", type=float, default=1.0, help="resize factor")
    p.add_argument("--pixel-art", action="store_true", help="NEAREST when scaling")
    p.add_argument("--format", choices=["png", "webp"], default="png")
    p.add_argument("--quality", type=int, default=85, help="webp quality (100=lossless)")
    p.add_argument("--lossless", action="store_true", help="never quantize; re-encode only")
    args = p.parse_args()

    files = list(args.files)
    if args.dir:
        files += sorted(glob.glob(os.path.join(args.dir, args.pattern)))
    if not files:
        p.error("give files or --dir")

    batch = len(files) > 1 or args.dir
    if batch:
        out_dir = args.out or "./compressed"
        os.makedirs(out_dir, exist_ok=True)

    tb = ta = 0
    for f in files:
        if batch:
            stem = os.path.splitext(os.path.basename(f))[0]
            dst = os.path.join(out_dir, f"{stem}.{args.format}")
        else:
            dst = args.out or os.path.splitext(f)[0] + f".min.{args.format}"
        b, a = process(f, dst, args)
        tb += b; ta += a
    print(f"TOTAL: {tb/1024:.0f}K -> {ta/1024:.0f}K (-{100*(1-ta/max(tb,1)):.0f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
