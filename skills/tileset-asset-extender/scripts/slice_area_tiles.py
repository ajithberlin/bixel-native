#!/usr/bin/env python3
"""Slice a large area texture (road/grass/river/beach...) into tile-size pieces
and check seam continuity between neighbours.

Usage:
    python3 slice_area_tiles.py BIG_IMAGE --tile 48 --outdir OUT_DIR [--names PREFIX]

- The image is centre-cropped to a whole number of tiles.
- Tiles are written as <prefix>_c{col}_r{row}.png.
- For every pair of horizontally/vertically adjacent tiles, the mean absolute
  difference along the shared edge is reported; seams above --seam-threshold
  are flagged so the texture can be regenerated or fixed.
- If the area must be a single wrap-around (torus) tile, use --wrap to check
  that left/right and top/bottom outer edges match instead.

Prints JSON report.
"""
import argparse
import json
import os

import numpy as np
from PIL import Image


def edge_diff(a, b, axis):
    """Mean abs diff between touching edges of two RGBA arrays."""
    if axis == "h":  # a right edge vs b left edge
        ea, eb = a[:, -1, :3].astype(int), b[:, 0, :3].astype(int)
    else:            # a bottom edge vs b top edge
        ea, eb = a[-1, :, :3].astype(int), b[0, :, :3].astype(int)
    return float(np.abs(ea - eb).mean())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("big_image")
    ap.add_argument("--tile", type=int, required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--names", default="tile")
    ap.add_argument("--wrap", action="store_true",
                    help="check wrap-around seamlessness of the whole image")
    ap.add_argument("--seam-threshold", type=float, default=12.0,
                    help="mean abs edge diff above which a seam is flagged")
    args = ap.parse_args()

    im = Image.open(args.big_image).convert("RGBA")
    t = args.tile
    cols, rows = im.width // t, im.height // t
    if cols < 1 or rows < 1:
        raise SystemExit("image smaller than one tile")
    crop = im.crop((0, 0, cols * t, rows * t))
    os.makedirs(args.outdir, exist_ok=True)

    tiles = {}
    files = []
    for r in range(rows):
        for c in range(cols):
            cell = crop.crop((c * t, r * t, (c + 1) * t, (r + 1) * t))
            name = f"{args.names}_c{c}_r{r}.png"
            cell.save(os.path.join(args.outdir, name))
            tiles[(c, r)] = np.array(cell)
            files.append(name)

    seams, flagged = [], []
    if args.wrap:
        a = np.array(crop)
        # Wrap seamlessness: the right edge must match the left edge, and the
        # bottom edge must match the top edge (so the texture tiles as a torus).
        checks = [("left_right_wrap", edge_diff(a, a, "h")),
                  ("top_bottom_wrap", edge_diff(a, a, "v"))]
        for name, d in checks:
            seams.append({"seam": name, "mean_abs_diff": round(d, 2)})
            if d > args.seam_threshold:
                flagged.append(name)
    else:
        for r in range(rows):
            for c in range(cols):
                if c + 1 < cols:
                    d = edge_diff(tiles[(c, r)], tiles[(c + 1, r)], "h")
                    s = f"{c},{r}|{c+1},{r}"
                    seams.append({"seam": s, "mean_abs_diff": round(d, 2)})
                    if d > args.seam_threshold:
                        flagged.append(s)
                if r + 1 < rows:
                    d = edge_diff(tiles[(c, r)], tiles[(c, r + 1)], "v")
                    s = f"{c},{r}|{c},{r+1}"
                    seams.append({"seam": s, "mean_abs_diff": round(d, 2)})
                    if d > args.seam_threshold:
                        flagged.append(s)

    print(json.dumps({
        "tile_size": t, "cols": cols, "rows": rows,
        "tile_count": len(files), "outdir": args.outdir,
        "flagged_seams": flagged,
        "ok": not flagged,
        "seams": seams,
    }, indent=2))


if __name__ == "__main__":
    main()
