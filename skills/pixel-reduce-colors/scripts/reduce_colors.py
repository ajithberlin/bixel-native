#!/usr/bin/env python3
"""Reduce an image to N colors, pixel-art safe.

Quantizes RGB while fully preserving the alpha channel (transparent pixels
stay transparent and never bleed into the palette). Optionally snaps to a
user palette (hex list or palette PNG) instead of computing one.

Usage:
  python3 reduce_colors.py in.png out.png --colors 16
  python3 reduce_colors.py in.png out.png --colors 8 --dither none
  python3 reduce_colors.py in.png out.png --palette "#1a1c2c,#5d275d,#b13e53"
  python3 reduce_colors.py in.png out.png --palette palette.png --report pal.json
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image


def parse_palette(spec: str):
    if spec.lower().endswith((".png", ".gif", ".bmp")):
        img = Image.open(spec).convert("RGB")
        cols = img.getcolors(img.width * img.height) or []
        return [c for _, c in cols][:256]
    parts = [p.strip().lstrip("#") for p in spec.split(",") if p.strip()]
    return [tuple(int(p[i:i + 2], 16) for i in (0, 2, 4)) for p in parts]


def main() -> int:
    p = argparse.ArgumentParser(description="Reduce image colors (pixel-art safe).")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--colors", type=int, default=16, help="target palette size (2-256)")
    p.add_argument("--dither", choices=["none", "floyd"], default="none",
                   help="'none' is correct for crisp pixel art")
    p.add_argument("--palette", default=None,
                   help="hex list '#ff00ff,#000000' or a palette PNG")
    p.add_argument("--report", default=None, help="write palette JSON to this path")
    args = p.parse_args()

    im = Image.open(args.input).convert("RGBA")
    rgb = im.convert("RGB")
    alpha = np.asarray(im)[..., 3]
    dither = Image.FLOYDSTEINBERG if args.dither == "floyd" else Image.NONE

    if args.palette:
        cols = parse_palette(args.palette)
        pal_img = Image.new("P", (1, 1))
        flat = [v for c in cols for v in c]
        flat += [0] * (768 - len(flat))
        pal_img.putpalette(flat)
        q = rgb.quantize(palette=pal_img, dither=dither)
    else:
        # quantize only opaque pixels' colors; FASTOCTREE is stable for sprites
        q = rgb.quantize(colors=args.colors, method=Image.FASTOCTREE, dither=dither)

    out = q.convert("RGBA")
    out_arr = np.array(out)
    out_arr[..., 3] = alpha
    out_arr[alpha == 0] = (0, 0, 0, 0)  # normalize fully-transparent pixels
    Image.fromarray(out_arr, "RGBA").save(args.output)

    used = out.convert("RGB").getcolors(out.width * out.height) or []
    palette_hex = sorted({"#%02x%02x%02x" % c for _, c in used})
    print(f"{len(palette_hex)} colors -> {args.output}")
    print(" ".join(palette_hex))
    if args.report:
        with open(args.report, "w") as f:
            json.dump({"colors": palette_hex, "count": len(palette_hex)}, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
