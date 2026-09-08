#!/usr/bin/env python3
"""Normalize raw AI-generated UI component images into game-ready assets.

Works on a single file or a whole folder (batch mode — the default after
splitting a batch sheet). One run = one canvas size; keep batch sheets
single-size so one command normalizes the whole batch.

Pipeline per image:
  1. flatten any alpha onto the chroma background
  2. key out the background (default pure magenta #FF00FF)
  3. crop to the component bounding box
  4. resize NEAREST-neighbor (downscale only, unless --allow-upscale) to fit an
     exact multiple-of-32 canvas with uniform padding
  5. center (or bottom-anchor) the component on the canvas
  6. snap all near-background pixels to the EXACT background color, save opaque RGB

Examples:
  python3 normalize_component.py raw/button_hover.png assets/buttons/button_primary_hover.png \
      --size 96x32 --pad 2
  python3 normalize_component.py raw/split/ assets/buttons/ --size 96x32 --pad 2   # batch
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image


def hex2rgb(s):
    s = s.lstrip("#")
    if len(s) != 6:
        raise ValueError(f"bad hex color: {s}")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def load_flat(path, bg):
    im = Image.open(path)
    if im.mode in ("RGBA", "LA", "PA") or "transparency" in im.info:
        im = im.convert("RGBA")
        base = Image.new("RGBA", im.size, bg + (255,))
        base.alpha_composite(im)
        return base.convert("RGB")
    return im.convert("RGB")


def process(in_path, out_path, args, bg, W, H):
    """Normalize one image. Returns (ok, message_lines)."""
    im = load_flat(in_path, bg)
    arr = np.asarray(im)
    diff = np.abs(arr.astype(np.int16) - np.array(bg, dtype=np.int16)).max(axis=2)
    mask = diff > args.tol
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return False, [f"{os.path.basename(in_path)}: no foreground detected (all background)"]

    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    warnings = []
    if x0 == 0 or y0 == 0 or x1 == arr.shape[1] or y1 == arr.shape[0]:
        warnings.append("edge-touch — outline may be cropped; reprompt with a wider margin")

    fg = im.crop((x0, y0, x1, y1))
    fw, fh = fg.size
    iw, ih = W - 2 * args.pad, H - 2 * args.pad
    scale = min(iw / fw, ih / fh)
    if scale > 1.0 and not args.allow_upscale:
        scale = 1.0
    elif scale > 1.0:
        warnings.append(f"upscaled {scale:.2f}x — edges may soften; regenerate bigger if it matters")
    nw, nh = max(1, round(fw * scale)), max(1, round(fh * scale))
    if scale != 1.0:
        fg = fg.resize((nw, nh), Image.NEAREST)

    if args.colors > 0:
        fg = fg.quantize(colors=args.colors, method=Image.MEDIANCUT).convert("RGB")

    canvas = Image.new("RGB", (W, H), bg)
    ox = (W - nw) // 2
    oy = (H - nh) // 2 if args.anchor == "center" else H - args.pad - nh
    canvas.paste(fg, (ox, oy))

    # snap every near-background pixel to the EXACT background color (kills halos)
    out = np.asarray(canvas).astype(np.int16)
    near = np.abs(out - np.array(bg, dtype=np.int16)).max(axis=2) <= args.tol
    out[near] = np.array(bg, dtype=np.int16)
    Image.fromarray(out.astype(np.uint8), "RGB").save(out_path)

    line = (f"{os.path.basename(out_path)}: {fw}x{fh} -> {nw}x{nh} on {W}x{H} "
            f"(scale {scale:.3f}x)")
    if warnings:
        line += "  WARNING: " + "; ".join(warnings)
    return True, [line]


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="one raw image, or a folder of raw crops (batch mode)")
    p.add_argument("output", help="output .png path, or output folder in batch mode")
    p.add_argument("--size", required=True, help="target canvas WxH, each a multiple of 32 (e.g. 96x32)")
    p.add_argument("--bg", default="FF00FF", help="chroma background hex (default FF00FF)")
    p.add_argument("--tol", type=int, default=60, help="background key tolerance, max-channel diff (default 60)")
    p.add_argument("--pad", type=int, default=2, help="min empty pixels on every side of the canvas (default 2)")
    p.add_argument("--anchor", choices=["center", "bottom"], default="center",
                   help="vertical placement of the component on the canvas")
    p.add_argument("--allow-upscale", action="store_true",
                   help="permit scaling above 1.0 (softens pixels; prefer regenerating bigger)")
    p.add_argument("--colors", type=int, default=0,
                   help="quantize foreground to N colors (median-cut) for palette consistency; 0 = off")
    args = p.parse_args()

    bg = hex2rgb(args.bg)
    try:
        W, H = (int(v) for v in args.size.lower().split("x"))
    except ValueError:
        sys.exit(f"error: --size must look like 96x32, got {args.size!r}")
    if W % 32 or H % 32:
        sys.exit(f"error: canvas {W}x{H} is not a multiple of 32x32")
    if args.pad * 2 >= min(W, H):
        sys.exit(f"error: --pad {args.pad} leaves no room inside {W}x{H}")

    if os.path.isdir(args.input):                      # batch mode
        files = sorted(f for f in os.listdir(args.input) if f.lower().endswith(".png"))
        if not files:
            sys.exit(f"error: no PNG files in {args.input}")
        os.makedirs(args.output, exist_ok=True)
        n_err = 0
        for f in files:
            ok, lines = process(os.path.join(args.input, f),
                                os.path.join(args.output, f), args, bg, W, H)
            n_err += 0 if ok else 1
            for line in lines:
                print(line)
        print(f"normalized {len(files) - n_err}/{len(files)} images -> {args.output} "
              f"({W}x{H}, exact #{args.bg.upper()}, opaque)")
        sys.exit(1 if n_err else 0)

    ok, lines = process(args.input, args.output, args, bg, W, H)
    for line in lines:
        print(("error: " if not ok else "") + line)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
