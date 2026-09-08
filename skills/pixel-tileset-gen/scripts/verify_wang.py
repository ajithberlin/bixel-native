#!/usr/bin/env python3
"""Verify + slice a Wang autotile blob (the 'white blob' master image).

A Wang blob must tile seamlessly: for every pair of horizontally adjacent
cells the right edge of the left cell must match the left edge of the right
cell (same for vertical pairs). AI-generated blobs often fail this - this
script measures it, marks bad seams on an annotated copy, and optionally
slices the blob into individual tile PNGs.

Usage:
  python3 verify_wang.py blob.png --tile 32
  python3 verify_wang.py blob.png --tile 32 --cols 8 --rows 6 \
      --report seams.json --annotated seams.png --tiles ./tiles
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw


def main() -> int:
    p = argparse.ArgumentParser(description="Verify seamlessness of a Wang tileset blob.")
    p.add_argument("input")
    p.add_argument("--tile", type=int, required=True, help="tile size in px (square)")
    p.add_argument("--cols", type=int, default=0, help="grid columns (0 = auto)")
    p.add_argument("--rows", type=int, default=0, help="grid rows (0 = auto)")
    p.add_argument("--tolerance", type=float, default=24.0,
                   help="max mean RGB distance along a shared edge")
    p.add_argument("--annotated", default=None, help="save PNG marking bad seams")
    p.add_argument("--report", default=None, help="save JSON report")
    p.add_argument("--tiles", default=None, help="folder to export sliced tiles")
    args = p.parse_args()

    im = Image.open(args.input).convert("RGBA")
    a = np.asarray(im).astype(np.float32)
    W, H = im.size
    t = args.tile
    cols = args.cols or W // t
    rows = args.rows or H // t
    if cols * t > W or rows * t > H:
        print(f"grid {cols}x{rows} of {t}px exceeds image {W}x{H}", file=sys.stderr)
        return 1

    def cell(c, r):
        return a[r * t:(r + 1) * t, c * t:(c + 1) * t, :3]

    bad = []
    total = 0
    for r in range(rows):
        for c in range(cols):
            if c + 1 < cols:  # horizontal seam
                d = np.abs(cell(c, r)[:, -1] - cell(c + 1, r)[:, 0]).mean()
                total += 1
                if d > args.tolerance:
                    bad.append({"type": "h", "col": c, "row": r, "diff": round(float(d), 1)})
            if r + 1 < rows:  # vertical seam
                d = np.abs(cell(c, r)[-1, :] - cell(c, r + 1)[0, :]).mean()
                total += 1
                if d > args.tolerance:
                    bad.append({"type": "v", "col": c, "row": r, "diff": round(float(d), 1)})

    ok = total - len(bad)
    print(f"grid {cols}x{rows} tiles of {t}px | seams ok {ok}/{total} "
          f"({100.0 * ok / max(total, 1):.0f}%) | bad: {len(bad)}")
    for b in bad[:20]:
        print(f"  {'H' if b['type']=='h' else 'V'} seam after col {b['col']} row {b['row']}: diff {b['diff']}")

    if args.annotated:
        out = im.copy()
        dr = ImageDraw.Draw(out)
        for b in bad:
            if b["type"] == "h":
                x = (b["col"] + 1) * t
                dr.line([(x, b["row"] * t), (x, (b["row"] + 1) * t)], fill=(255, 0, 80, 255), width=2)
            else:
                y = (b["row"] + 1) * t
                dr.line([(b["col"] * t, y), ((b["col"] + 1) * t, y)], fill=(255, 0, 80, 255), width=2)
        out.save(args.annotated)

    if args.tiles:
        os.makedirs(args.tiles, exist_ok=True)
        for r in range(rows):
            for c in range(cols):
                im.crop((c * t, r * t, (c + 1) * t, (r + 1) * t)).save(
                    os.path.join(args.tiles, f"tile_{r:02d}_{c:02d}.png"))

    if args.report:
        with open(args.report, "w") as f:
            json.dump({"cols": cols, "rows": rows, "tile": t,
                       "seams_total": total, "seams_bad": len(bad),
                       "bad_seams": bad}, f, indent=2)
    return 2 if bad else 0  # exit 2 = seams found (script itself worked)


if __name__ == "__main__":
    sys.exit(main())
