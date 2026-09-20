#!/usr/bin/env python3
"""Insert a transparent-background asset into a tileset, snapped to the grid.

- Trims transparent borders of the asset.
- Scales it to fit a footprint of TILES_W x TILES_H grid cells (aspect preserved).
- Places it bottom-anchored in a free grid slot (auto-search from the bottom,
  or an explicit --cell C,R). If no slot fits, extends the canvas downward by
  whole tile rows.
- Never overlaps existing opaque pixels.

Usage:
    python3 insert_asset.py TILESET ASSET --tile 48 \
        --tiles-w 6 --tiles-h 4 [--cell C,R] [--out OUT.png]

Prints JSON placement: position, footprint, whether the canvas was extended.
"""
import argparse
import json

import numpy as np
from PIL import Image
from scipy import ndimage


def despeckle(im, min_px=64):
    """Drop tiny disconnected alpha specks (common in AI-generated assets)."""
    a = np.array(im)
    mask = a[..., 3] > 8
    lab, n = ndimage.label(mask)
    if n <= 1:
        return im
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    keep = np.zeros(n + 1, dtype=bool)
    keep[0] = False
    for i, s in enumerate(sizes, start=1):
        if s >= min_px:
            keep[i] = True
    a[..., 3] = np.where(keep[lab], a[..., 3], 0)
    return Image.fromarray(a)


def trim(im):
    a = np.array(im)
    ys, xs = np.where(a[..., 3] > 8)
    if len(xs) == 0:
        raise SystemExit("asset is fully transparent")
    return im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def occupancy(mask, tile, cols, rows):
    occ = np.zeros((rows, cols), dtype=bool)
    for r in range(rows):
        for c in range(cols):
            occ[r, c] = mask[r * tile:(r + 1) * tile, c * tile:(c + 1) * tile].mean() > 0.02
    return occ


def find_slot(occ, need_c, need_r):
    """Bottom-most, then left-most free rectangle of need_c x need_r cells."""
    rows, cols = occ.shape
    for r in range(rows - need_r, -1, -1):
        for c in range(0, cols - need_c + 1):
            if not occ[r:r + need_r, c:c + need_c].any():
                return c, r
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tileset")
    ap.add_argument("asset")
    ap.add_argument("--tile", type=int, required=True)
    ap.add_argument("--tiles-w", type=int, required=True, help="footprint width in cells")
    ap.add_argument("--tiles-h", type=int, required=True, help="footprint height in cells")
    ap.add_argument("--cell", default=None, help="explicit top-left cell 'C,R'")
    ap.add_argument("--margin", type=int, default=1,
                    help="px inset inside the footprint so the sprite never "
                         "touches neighbouring sprites (default 1)")
    ap.add_argument("--out", default=None, help="output path (default: <tileset>_extended.png)")
    args = ap.parse_args()

    base = Image.open(args.tileset).convert("RGBA")
    asset = trim(despeckle(Image.open(args.asset).convert("RGBA")))
    tile = args.tile
    W, H = base.size
    cols, rows = W // tile, H // tile

    # scale asset to fit footprint (minus margin), preserve aspect
    fw, fh = args.tiles_w * tile - 2 * args.margin, args.tiles_h * tile - 2 * args.margin
    scale = min(fw / asset.width, fh / asset.height)
    if scale < 1.0 or asset.width > fw or asset.height > fh:
        new = (max(1, round(asset.width * scale)), max(1, round(asset.height * scale)))
        asset = asset.resize(new, Image.LANCZOS)

    mask = np.array(base)[..., 3] > 8
    occ = occupancy(mask, tile, cols, rows)

    extended = False
    if args.cell:
        c, r = map(int, args.cell.split(","))
        if c < 0 or r < 0 or c + args.tiles_w > cols or r + args.tiles_h > rows:
            raise SystemExit(
                f"cell {c},{r} with footprint {args.tiles_w}x{args.tiles_h} "
                f"is outside the {cols}x{rows} grid"
            )
        if occ[r:r + args.tiles_h, c:c + args.tiles_w].any():
            raise SystemExit(f"cell {c},{r} footprint overlaps existing content")
    else:
        slot = find_slot(occ, args.tiles_w, args.tiles_h)
        if slot is None:
            # extend canvas by whole tile rows
            add_rows = args.tiles_h
            new_img = Image.new("RGBA", (W, H + add_rows * tile), (0, 0, 0, 0))
            new_img.paste(base, (0, 0))
            base = new_img
            H += add_rows * tile
            rows += add_rows
            extended = True
            c, r = 0, rows - add_rows
        else:
            c, r = slot

    # bottom-anchor inside the footprint rectangle (respecting the margin)
    fx, fy = c * tile + args.margin, r * tile + args.margin
    px = fx + (fw - asset.width) // 2
    py = fy + fh - asset.height

    # safety: never paint over — or even touch — existing opaque pixels
    region = np.array(base.crop((px, py, px + asset.width, py + asset.height)))
    am = ndimage.binary_dilation(np.array(asset)[..., 3] > 8, iterations=1)
    if (region[..., 3][am] > 8).any():
        raise SystemExit("refusing to paste: asset would overlap or touch existing pixels")

    base.paste(asset, (px, py), asset)
    out = args.out or args.tileset.rsplit(".", 1)[0] + "_extended.png"
    base.save(out)

    print(json.dumps({
        "out": out,
        "canvas": {"width": base.width, "height": base.height},
        "canvas_extended": extended,
        "cell": {"col": c, "row": r},
        "footprint_px": {"x": fx, "y": fy, "w": fw, "h": fh},
        "pasted_px": {"x": px, "y": py, "w": asset.width, "h": asset.height},
        "grid_rows": rows,
    }, indent=2))


if __name__ == "__main__":
    main()
