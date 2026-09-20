#!/usr/bin/env python3
"""Analyze a tileset/sprite sheet: detect grid, list objects, find free slots.

Usage:
    python3 analyze_tileset.py TILESET [--tile N] [--min-area PX] [--json]

Prints a JSON report:
  - image size, alpha presence
  - detected (or given) tile size and grid dimensions
  - object bounding boxes (connected components on the alpha mask)
  - free rectangular slots snapped to the grid (largest first)
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

CANDIDATE_TILES = [16, 24, 32, 48, 64, 96, 128]


def detect_tile_size(mask, w, h):
    """Score candidate tile sizes: image dims divisibility + component edge alignment."""
    lab, n = ndimage.label(mask)
    edges = []
    for sl in ndimage.find_objects(lab):
        ys, xs = sl
        if (xs.stop - xs.start) * (ys.stop - ys.start) >= 64:
            edges += [xs.start, xs.stop, ys.start, ys.stop]
    edges = np.array(edges) if edges else np.array([0])
    # Among candidates dividing both dims, pick the one whose edge alignment
    # is best with a tolerance PROPORTIONAL to the tile size — a fixed 2 px
    # tolerance unfairly favours small tiles (16 px inherits 48 px alignment),
    # and free-form sheets are only loosely snapped.
    scored = []
    for g in CANDIDATE_TILES:
        if w % g or h % g:
            continue
        tol = max(1, round(g * 0.06))
        rem = edges % g
        align = float(np.mean(np.minimum(rem, g - rem) <= tol))
        scored.append((g, align))
    if not scored:
        return 48
    best_align = max(a for _, a in scored)
    return max(g for g, a in scored if a >= best_align - 0.02)


def find_free_slots(mask, tile, cols, rows, max_slots=8):
    """Greedy largest-empty-rectangle search on the grid-cell occupancy matrix."""
    occ = np.zeros((rows, cols), dtype=bool)
    for r in range(rows):
        for c in range(cols):
            cell = mask[r * tile:(r + 1) * tile, c * tile:(c + 1) * tile]
            occ[r, c] = cell.mean() > 0.02
    free = ~occ
    slots = []
    work = free.copy()
    for _ in range(max_slots):
        # largest all-True rectangle via histogram method
        heights = np.zeros(work.shape[1], dtype=int)
        best_rect = None
        best_area = 0
        for r in range(rows):
            heights = np.where(work[r], heights + 1, 0)
            # maximal rectangle in this histogram row
            stack = []
            for c in range(cols + 1):
                cur = heights[c] if c < cols else 0
                start = c
                while stack and stack[-1][1] > cur:
                    s, hgt = stack.pop()
                    area = hgt * (c - s)
                    if area > best_area:
                        best_area = area
                        best_rect = (s, r - hgt + 1, c, r + 1)  # c0, r0, c1, r1
                    start = s
                stack.append((start, cur))
        if not best_rect or best_area < 1:
            break
        c0, r0, c1, r1 = (int(v) for v in best_rect)
        slots.append({"x": c0 * tile, "y": r0 * tile,
                      "w": (c1 - c0) * tile, "h": (r1 - r0) * tile,
                      "cols": c1 - c0, "rows": r1 - r0})
        work[r0:r1, c0:c1] = False  # consume
    return slots


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tileset")
    ap.add_argument("--tile", type=int, default=0, help="tile size in px (0 = auto-detect)")
    ap.add_argument("--min-area", type=int, default=256, help="min component area in px")
    ap.add_argument("--json", action="store_true",
                    help="emit JSON only (the default; accepted for compatibility)")
    args = ap.parse_args()

    img = Image.open(args.tileset).convert("RGBA")
    a = np.array(img)
    w, h = img.size
    mask = a[..., 3] > 8

    tile = args.tile or detect_tile_size(mask, w, h)
    cols, rows = w // tile, h // tile

    lab, n = ndimage.label(mask)
    objects = []
    for sl in ndimage.find_objects(lab):
        ys, xs = sl
        bw, bh = xs.stop - xs.start, ys.stop - ys.start
        if bw * bh >= args.min_area:
            objects.append({"x": int(xs.start), "y": int(ys.start),
                            "w": int(bw), "h": int(bh)})

    report = {
        "file": args.tileset,
        "width": w, "height": h,
        "has_alpha": bool((a[..., 3] < 255).any()),
        "tile_size": tile,
        "grid": {"cols": cols, "rows": rows},
        "size_multiple_of_tile": bool(w % tile == 0 and h % tile == 0),
        "object_count": len(objects),
        "objects": sorted(objects, key=lambda o: (o["y"], o["x"])),
        "free_slots": find_free_slots(mask, tile, cols, rows) if (w % tile == 0 and h % tile == 0) else [],
    }
    json.dump(report, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
