#!/usr/bin/env python3
"""Pack animation frames into a uniform spritesheet (+ JSON + GIF preview).

Each input frame is cropped to its visible pixels, then placed on a uniform
cell grid with a fixed anchor so the animation does NOT jitter (the #1 bug
with AI-generated frames).

Usage:
  python3 pack_frames.py --dir ./walk_frames --out sheet.png --gif walk.gif
  python3 pack_frames.py --frames f1.png f2.png f3.png --out sheet.png \
      --anchor center --cols 2 --fps 8 --json sheet.json
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image


def alpha_bbox(im: Image.Image):
    a = np.asarray(im.convert("RGBA"))[..., 3]
    ys, xs = np.where(a > 0)
    if len(xs) == 0:
        return None
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def main() -> int:
    p = argparse.ArgumentParser(description="Pack animation frames into a spritesheet.")
    p.add_argument("--dir", help="folder of frame PNGs (sorted by name)")
    p.add_argument("--pattern", default="*.png")
    p.add_argument("--frames", nargs="*", help="explicit frame files, in order")
    p.add_argument("--out", required=True)
    p.add_argument("--json", default=None, help="metadata path (default: <out>.json)")
    p.add_argument("--gif", default=None, help="also write an animated GIF preview")
    p.add_argument("--fps", type=float, default=6)
    p.add_argument("--anchor", choices=["bottom", "center"], default="bottom",
                   help="bottom = feet aligned (characters); center = UI/props")
    p.add_argument("--cols", type=int, default=0, help="grid columns (0 = single strip)")
    p.add_argument("--pad", type=int, default=0, help="px padding around each cell")
    p.add_argument("--no-crop", action="store_true", help="keep frames as-is")
    args = p.parse_args()

    files = args.frames or sorted(glob.glob(os.path.join(args.dir or ".", args.pattern)))
    if not files:
        print("no frames found", file=sys.stderr)
        return 1

    crops = []
    for f in files:
        im = Image.open(f).convert("RGBA")
        if not args.no_crop:
            bb = alpha_bbox(im)
            if bb:
                im = im.crop(bb)
        crops.append(im)

    cw = max(i.width for i in crops)
    ch = max(i.height for i in crops)
    cw += 2 * args.pad
    ch += 2 * args.pad
    n = len(crops)
    cols = args.cols or n
    rows = (n + cols - 1) // cols

    sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
    meta_frames = []
    for i, im in enumerate(crops):
        cell_x, cell_y = (i % cols) * cw, (i // cols) * ch
        x = cell_x + (cw - im.width) // 2
        y = (cell_y + ch - args.pad - im.height) if args.anchor == "bottom" \
            else cell_y + (ch - im.height) // 2
        sheet.paste(im, (x, y), im)
        meta_frames.append({"file": os.path.basename(files[i]),
                            "x": cell_x, "y": cell_y, "w": cw, "h": ch})

    sheet.save(args.out)
    meta = {"image": os.path.basename(args.out), "frameWidth": cw, "frameHeight": ch,
            "cols": cols, "rows": rows, "count": n, "anchor": args.anchor,
            "frames": meta_frames}
    with open(args.json or (args.out + ".json"), "w") as f:
        json.dump(meta, f, indent=2)

    if args.gif:
        frames = [sheet.crop((fr["x"], fr["y"], fr["x"] + cw, fr["y"] + ch))
                  for fr in meta_frames]
        frames[0].save(args.gif, save_all=True, append_images=frames[1:],
                       duration=int(1000 / args.fps), loop=0,
                       disposal=2, transparency=0)
    print(f"packed {n} frames -> {args.out} ({cols}x{rows} grid, cell {cw}x{ch})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
