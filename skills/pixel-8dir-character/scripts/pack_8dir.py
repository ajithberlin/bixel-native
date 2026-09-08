#!/usr/bin/env python3
"""Pack 8 direction frames into one labeled spritesheet + JSON.

Accepts frames named by direction (any of: N, NE, E, SE, S, SW, W, NW or
'down', 'down-left', ...) and packs them in canonical engine order. Cells are
uniform, bottom-anchored, so the character never jumps between directions.

Usage:
  python3 pack_8dir.py --dir ./rotations --out hero_8dir.png
  python3 pack_8dir.py --frames S.png SW.png W.png NW.png N.png NE.png E.png SE.png \
      --out hero_8dir.png --layout 4x2 --gif preview.gif
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image

ORDER = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
ALIASES = {
    "s": "S", "south": "S", "down": "S", "front": "S",
    "sw": "SW", "southwest": "SW", "south-west": "SW", "down-left": "SW", "downleft": "SW",
    "w": "W", "west": "W", "left": "W",
    "nw": "NW", "northwest": "NW", "north-west": "NW", "up-left": "NW", "upleft": "NW",
    "n": "N", "north": "N", "up": "N", "back": "N",
    "ne": "NE", "northeast": "NE", "north-east": "NE", "up-right": "NE", "upright": "NE",
    "e": "E", "east": "E", "right": "E",
    "se": "SE", "southeast": "SE", "south-east": "SE", "down-right": "SE", "downright": "SE",
}


def detect_direction(fname: str):
    stem = os.path.splitext(os.path.basename(fname))[0].lower()
    for token in stem.replace("_", "-").split("-"):
        if token in ALIASES:
            return ALIASES[token]
    for k in sorted(ALIASES, key=len, reverse=True):
        if k in stem:
            return ALIASES[k]
    return None


def main() -> int:
    p = argparse.ArgumentParser(description="Pack 8-direction frames into a spritesheet.")
    p.add_argument("--dir", help="folder of direction PNGs")
    p.add_argument("--pattern", default="*.png")
    p.add_argument("--frames", nargs="*", help="explicit files (direction read from name)")
    p.add_argument("--out", required=True)
    p.add_argument("--layout", choices=["8x1", "4x2", "2x4"], default="8x1")
    p.add_argument("--json", default=None)
    p.add_argument("--gif", default=None)
    p.add_argument("--fps", type=float, default=4)
    p.add_argument("--pad", type=int, default=0)
    args = p.parse_args()

    files = args.frames or sorted(glob.glob(os.path.join(args.dir or ".", args.pattern)))
    by_dir = {}
    for f in files:
        d = detect_direction(f)
        if d and d not in by_dir:
            by_dir[d] = f
    ordered = [d for d in ORDER if d in by_dir]
    missing = [d for d in ORDER if d not in by_dir]
    if missing:
        print(f"warning: missing directions: {', '.join(missing)}", file=sys.stderr)
    if not ordered:
        print("no direction-named frames found", file=sys.stderr)
        return 1

    crops = {}
    for d in ordered:
        im = Image.open(by_dir[d]).convert("RGBA")
        a = np.asarray(im)[..., 3]
        ys, xs = np.where(a > 0)
        if len(xs):
            im = im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
        crops[d] = im

    cw = max(i.width for i in crops.values()) + 2 * args.pad
    ch = max(i.height for i in crops.values()) + 2 * args.pad
    cols, rows = {"8x1": (8, 1), "4x2": (4, 2), "2x4": (2, 4)}[args.layout]

    sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
    cells = {}
    for i, d in enumerate(ordered):
        im = crops[d]
        cell_x, cell_y = (i % cols) * cw, (i // cols) * ch
        x = cell_x + (cw - im.width) // 2
        y = cell_y + ch - args.pad - im.height  # bottom anchor: feet aligned
        sheet.paste(im, (x, y), im)
        cells[d] = {"x": cell_x, "y": cell_y, "w": cw, "h": ch}

    sheet.save(args.out)
    meta = {"image": os.path.basename(args.out), "frameWidth": cw, "frameHeight": ch,
            "order": ordered, "cells": cells}
    with open(args.json or (args.out + ".json"), "w") as f:
        json.dump(meta, f, indent=2)

    if args.gif:
        frames = [sheet.crop((cells[d]["x"], cells[d]["y"],
                              cells[d]["x"] + cw, cells[d]["y"] + ch)) for d in ordered]
        frames[0].save(args.gif, save_all=True, append_images=frames[1:],
                       duration=int(1000 / args.fps), loop=0, disposal=2, transparency=0)
    print(f"packed {len(ordered)} directions -> {args.out} ({args.layout}, cell {cw}x{ch})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
