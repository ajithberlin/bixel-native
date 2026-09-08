#!/usr/bin/env python3
"""Slice a generated UI image (transparent background) into separate components.

Segments the image by connected alpha regions, crops each component with
padding, and writes one PNG per component plus a manifest.json with bounding
boxes (ready for Flame/Bonfire, Unity, Godot import).

Near-touching parts of one control (button + icon) often split; raise
--dilate to merge them before labeling.

Usage:
  python3 slice_ui.py ui.png --out ./components
  python3 slice_ui.py ui.png --out ./components --dilate 4 --min-area 64 \
      --names panel,button_inventory,button_map,button_quit,icon
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def main() -> int:
    p = argparse.ArgumentParser(description="Slice transparent UI image into components.")
    p.add_argument("input")
    p.add_argument("--out", required=True, help="output folder")
    p.add_argument("--dilate", type=int, default=2,
                   help="px dilation before labeling (merges touching parts)")
    p.add_argument("--min-area", type=int, default=32, help="drop specks below N px")
    p.add_argument("--pad", type=int, default=2, help="px padding on each crop")
    p.add_argument("--names", default=None,
                   help="comma list applied in reading order (top->bottom, left->right)")
    args = p.parse_args()

    im = Image.open(args.input).convert("RGBA")
    a = np.asarray(im)
    alpha = a[..., 3] > 0
    mask = ndimage.binary_dilation(alpha, iterations=args.dilate) if args.dilate else alpha
    labels, n = ndimage.label(mask)

    boxes = []
    for i in range(1, n + 1):
        ys, xs = np.where(labels == i)
        area = int(alpha[labels == i].sum())
        if area < args.min_area:
            continue
        x0 = max(0, xs.min() - args.pad); y0 = max(0, ys.min() - args.pad)
        x1 = min(im.width, xs.max() + 1 + args.pad); y1 = min(im.height, ys.max() + 1 + args.pad)
        boxes.append({"bbox": [int(x0), int(y0), int(x1), int(y1)], "area": area,
                      "key": (y0 // 32, x0)})  # rough reading order

    boxes.sort(key=lambda b: b["key"])
    names = [s.strip() for s in args.names.split(",")] if args.names else []

    os.makedirs(args.out, exist_ok=True)
    manifest = {"image": os.path.basename(args.input), "components": []}
    for i, b in enumerate(boxes):
        name = names[i] if i < len(names) else f"component_{i:02d}"
        x0, y0, x1, y1 = b["bbox"]
        crop = im.crop((x0, y0, x1, y1))
        path = os.path.join(args.out, f"{name}.png")
        crop.save(path)
        manifest["components"].append({
            "name": name, "file": f"{name}.png",
            "bbox": b["bbox"], "w": x1 - x0, "h": y1 - y0})

    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"{len(boxes)} components -> {args.out}/ (+ manifest.json)")
    for c in manifest["components"]:
        print(f"  {c['name']}: {c['w']}x{c['h']} at {c['bbox'][:2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
