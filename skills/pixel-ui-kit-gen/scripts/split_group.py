#!/usr/bin/env python3
"""Split one batch sheet into separate raw component/state images.

Batch sheets are the DEFAULT generation unit of this skill: one AI image holds
a whole row of states of one component, or a grid of same-size items, and this
script cuts it into separate raw crops (projection-band detection over the
non-background pixels). Every gap BETWEEN items must exceed --bridge.

Naming (pick one):
  --names "a,b,c"                     one name per item, reading order
                                      (left-to-right, then top-to-bottom)
  --rows "btn_primary,btn_secondary" --states "default,hover,pressed"
                                      grid naming: outputs {row}_{state}.png

Layouts auto-detected: single row, single column, or rows x cols grid.
--grid CxR optionally asserts the detected layout before cutting.

Each output is a raw crop ready for normalize_component.py.

Examples:
  python3 split_group.py raw/btn_states.png raw/split \
      --names "button_primary_default,button_primary_hover,button_primary_pressed"
  python3 split_group.py raw/button_families.png raw/split --grid 3x3 \
      --rows "button_primary,button_secondary,button_toggle" \
      --states "default,hover,pressed"
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image


def hex2rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def load_flat(path, bg):
    im = Image.open(path)
    if im.mode in ("RGBA", "LA", "PA") or "transparency" in im.info:
        im = im.convert("RGBA")
        base = Image.new("RGBA", im.size, bg + (255,))
        base.alpha_composite(im)
        return base.convert("RGB")
    return im.convert("RGB")


def bands(profile, bridge, min_w):
    """Runs of profile>0, merging runs separated by gaps <= bridge."""
    idx = np.where(profile > 0)[0]
    if len(idx) == 0:
        return []
    runs, start, prev = [], idx[0], idx[0]
    for i in idx[1:]:
        if i - prev > bridge + 1:
            runs.append((start, prev + 1))
            start = i
        prev = i
    runs.append((start, prev + 1))
    return [r for r in runs if r[1] - r[0] >= min_w]


def die_bands(row_bands, col_bands, expected):
    print(f"error: detected {len(row_bands)} row band(s) x {len(col_bands)} column band(s), "
          f"expected {expected}", file=sys.stderr)
    print("hint: items are touching or the gaps are too small — reprompt with 'generous even "
          "gaps between all items, aligned rows and columns', or tune --bridge/--min-w. "
          "Do not hand-cut a broken sheet.", file=sys.stderr)
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input")
    p.add_argument("out_dir")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--names", help="comma-separated output names, reading order")
    g.add_argument("--rows", help="comma-separated row names (one component per row); "
                                  "requires --states")
    p.add_argument("--states", help="comma-separated column/state names (with --rows)")
    p.add_argument("--grid", help="assert detected layout is CxR, e.g. 3x3")
    p.add_argument("--bg", default="FF00FF")
    p.add_argument("--tol", type=int, default=60, help="background key tolerance (default 60)")
    p.add_argument("--bridge", type=int, default=24,
                   help="max empty-pixel gap bridged INSIDE one item (default 24); "
                        "gaps between items must be larger than this")
    p.add_argument("--min-w", type=int, default=16, help="ignore bands narrower than this (default 16)")
    p.add_argument("--margin", type=int, default=8, help="pixels of background kept around each crop (default 8)")
    args = p.parse_args()

    bg = hex2rgb(args.bg)
    im = load_flat(args.input, bg)
    arr = np.asarray(im).astype(np.int16)
    mask = np.abs(arr - np.array(bg, dtype=np.int16)).max(axis=2) > args.tol
    H, W = mask.shape

    row_bands = bands(mask.sum(axis=1), args.bridge, args.min_w)
    col_bands = bands(mask.sum(axis=0), args.bridge, args.min_w)

    if args.grid:
        try:
            C, R = (int(v) for v in args.grid.lower().split("x"))
        except ValueError:
            sys.exit(f"error: --grid must look like 3x3, got {args.grid!r}")
        if len(col_bands) != C or len(row_bands) != R:
            die_bands(row_bands, col_bands, f"grid {C}x{R} (--grid)")

    if args.rows:
        if not args.states:
            sys.exit("error: --rows requires --states")
        row_names = [n.strip() for n in args.rows.split(",") if n.strip()]
        state_names = [n.strip() for n in args.states.split(",") if n.strip()]
        R, C = len(row_names), len(state_names)
        if len(row_bands) != R or len(col_bands) != C:
            die_bands(row_bands, col_bands, f"{R} row(s) x {C} column(s) from --rows/--states")
        cells = [(r0, r1, c0, c1) for r0, r1 in row_bands for c0, c1 in col_bands]
        names = [f"{rn}_{sn}" for rn in row_names for sn in state_names]
    else:
        names = [n.strip() for n in args.names.split(",") if n.strip()]
        n = len(names)
        if len(row_bands) == 1 and len(col_bands) == n:          # single row
            r0, r1 = row_bands[0]
            cells = [(r0, r1, c0, c1) for c0, c1 in col_bands]
        elif len(col_bands) == 1 and len(row_bands) == n:        # single column
            c0, c1 = col_bands[0]
            cells = [(r0, r1, c0, c1) for r0, r1 in row_bands]
        elif len(row_bands) * len(col_bands) == n:               # grid, row-major
            cells = [(r0, r1, c0, c1) for r0, r1 in row_bands for c0, c1 in col_bands]
        else:
            die_bands(row_bands, col_bands, f"{n} item(s) from --names")

    os.makedirs(args.out_dir, exist_ok=True)
    for name, (r0, r1, c0, c1) in zip(names, cells):
        sub = mask[r0:r1, c0:c1]
        ys, xs = np.where(sub)
        if len(xs) == 0:
            sys.exit(f"error: empty cell for {name!r}")
        y0, y1 = r0 + ys.min(), r0 + ys.max() + 1
        x0, x1 = c0 + xs.min(), c0 + xs.max() + 1
        y0, x0 = max(0, y0 - args.margin), max(0, x0 - args.margin)
        y1, x1 = min(H, y1 + args.margin), min(W, x1 + args.margin)
        out = im.crop((x0, y0, x1, y1))
        path = os.path.join(args.out_dir, f"{name}.png")
        out.save(path)
        print(f"{name}: {out.size[0]}x{out.size[1]} -> {path}")
    print(f"split {args.input} -> {len(names)} crops")


if __name__ == "__main__":
    main()
