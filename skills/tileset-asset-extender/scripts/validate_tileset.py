#!/usr/bin/env python3
"""Validate a tileset after edits and produce a report + grid-overlay preview.

Checks:
  1. Image dimensions are whole multiples of the tile size.
  2. Alpha channel present (objects sit on transparency).
  3. Sprite-to-sprite contacts: pairs of objects that touch (1 px dilation).
     Packed sheets naturally contain some; with --baseline ORIGINAL.png the
     check fails only when the edited sheet has MORE contact pairs than the
     original (i.e. the edit made sprites touch/merge). Without a baseline
     the count is informational.
  4. Percentage of component edges aligned to the grid (informational).
  5. Writes an overlay preview PNG with the grid and numbered objects.

Usage:
    python3 validate_tileset.py TILESET --tile 48 [--baseline ORIGINAL.png] \
        [--overlay overlay.png]

Exit code 0 when checks pass, 1 otherwise. Prints JSON.
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage


def contact_pairs(mask):
    """Set of component-id pairs that touch after 1 px dilation."""
    lab, n = ndimage.label(mask)
    pairs = set()
    for i in range(1, n + 1):
        comp = lab == i
        grown = ndimage.binary_dilation(comp, iterations=1)
        other = grown & (lab != i) & (lab != 0)
        if other.any():
            pairs.add(tuple(sorted((i, int(lab[other][0])))))
    return pairs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tileset")
    ap.add_argument("--tile", type=int, required=True)
    ap.add_argument("--baseline", default=None,
                    help="original tileset; fail if contact pairs increased")
    ap.add_argument("--overlay", default=None)
    ap.add_argument("--min-area", type=int, default=256)
    args = ap.parse_args()

    img = Image.open(args.tileset).convert("RGBA")
    a = np.array(img)
    w, h = img.size
    t = args.tile
    mask = a[..., 3] > 8

    checks = {}
    checks["size_multiple_of_tile"] = (w % t == 0 and h % t == 0)
    checks["has_transparency"] = bool((a[..., 3] < 255).any())

    lab, n = ndimage.label(mask)
    boxes = []
    for sl in ndimage.find_objects(lab):
        ys, xs = sl
        if (xs.stop - xs.start) * (ys.stop - ys.start) >= args.min_area:
            boxes.append((int(xs.start), int(ys.start), int(xs.stop), int(ys.stop)))

    # sprite-contact check (baseline-aware: packed sheets have contacts already)
    pairs = contact_pairs(mask)
    if args.baseline:
        bm = np.array(Image.open(args.baseline).convert("RGBA"))[..., 3] > 8
        base_pairs = contact_pairs(bm)
        checks["no_new_sprite_contacts"] = len(pairs) <= len(base_pairs)
        baseline_count = len(base_pairs)
    else:
        checks["no_new_sprite_contacts"] = None  # informational without baseline
        baseline_count = None

    # grid alignment of component edges (informational)
    edges = []
    for x0, y0, x1, y1 in boxes:
        edges += [x0, x1, y0, y1]
    if edges:
        rem = np.array(edges) % t
        align = float(np.mean(np.minimum(rem, t - rem) <= 2)) * 100
    else:
        align = 0.0

    passed = all(v for v in checks.values() if v is not None)

    overlay_path = None
    if args.overlay:
        ov = img.copy()
        d = ImageDraw.Draw(ov)
        for x in range(0, w + 1, t):
            d.line([(x, 0), (x, h)], fill=(255, 0, 0, 128))
        for y in range(0, h + 1, t):
            d.line([(0, y), (w, y)], fill=(255, 0, 0, 128))
        for i, (x0, y0, x1, y1) in enumerate(boxes):
            d.rectangle([x0, y0, x1 - 1, y1 - 1], outline=(0, 128, 255, 200))
            d.text((x0 + 2, y0 + 2), str(i), fill=(0, 128, 255, 255))
        ov.save(args.overlay)
        overlay_path = args.overlay

    report = {
        "file": args.tileset, "width": w, "height": h, "tile_size": t,
        "grid": {"cols": w // t, "rows": h // t},
        "checks": checks,
        "sprite_contact_pairs": len(pairs),
        "baseline_contact_pairs": baseline_count,
        "object_count": len(boxes),
        "grid_edge_alignment_pct": round(align, 1),
        "overlay": overlay_path,
        "passed": passed,
    }
    json.dump(report, sys.stdout, indent=2)
    print()
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
