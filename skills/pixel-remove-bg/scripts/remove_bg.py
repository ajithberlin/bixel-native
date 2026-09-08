#!/usr/bin/env python3
"""Remove the background from a pixel-art / game-asset image.

Modes:
  auto  - sample the dominant border color, flood-remove everything connected
          to the image edge within --tolerance (best for flat/near-flat AI
          backgrounds; keeps interior details that happen to share the bg
          color, as long as they are enclosed by the subject).
  key   - classic chroma-key: remove ALL pixels within --tolerance of a given
          hex color (default pure magenta #FF00FF), wherever they are.
  white - auto mode tuned for white/near-white studio backgrounds.

Usage:
  python3 remove_bg.py in.png out.png                      # auto
  python3 remove_bg.py in.png out.png --mode key --color FF00FF
  python3 remove_bg.py in.png out.png --tolerance 40 --despill
"""
import argparse
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def hex_to_rgb(s: str):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def border_color(rgb: np.ndarray) -> np.ndarray:
    """Dominant color along the image border (median of border pixels)."""
    top, bottom = rgb[0], rgb[-1]
    left, right = rgb[:, 0], rgb[:, -1]
    border = np.concatenate([top, bottom, left, right], axis=0)
    # median is robust against subjects touching one edge
    return np.median(border, axis=0)


def main() -> int:
    p = argparse.ArgumentParser(description="Remove background from a game-asset image.")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--mode", choices=["auto", "key", "white"], default="auto")
    p.add_argument("--color", default="FF00FF", help="hex color for --mode key")
    p.add_argument("--tolerance", type=float, default=32.0,
                   help="RGB distance threshold (0-441). 32 works for most AI flats.")
    p.add_argument("--despill", action="store_true",
                   help="desaturate leftover fringe pixels toward grey")
    p.add_argument("--feather", type=int, default=0,
                   help="erode the kept mask by N px before output (kills halo)")
    args = p.parse_args()

    im = Image.open(args.input).convert("RGBA")
    a = np.asarray(im).astype(np.float32)
    rgb, alpha = a[..., :3], a[..., 3]

    if args.mode == "key":
        bg = np.array(hex_to_rgb(args.color), dtype=np.float32)
    elif args.mode == "white":
        bg = np.array([255, 255, 255], dtype=np.float32)
    else:
        bg = border_color(rgb)

    dist = np.sqrt(((rgb - bg) ** 2).sum(axis=-1))
    near_bg = dist <= args.tolerance

    if args.mode == "key":
        bg_mask = near_bg
    else:
        # keep only background regions CONNECTED to the image border
        labels, _ = ndimage.label(near_bg)
        border_labels = np.unique(np.concatenate([
            labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
        border_labels = border_labels[border_labels != 0]
        bg_mask = np.isin(labels, border_labels)

    keep = ~bg_mask & (alpha > 0)
    if args.feather > 0:
        keep = ndimage.binary_erosion(keep, iterations=args.feather)

    out = a.copy()
    if args.despill:
        fringe = keep & (dist <= args.tolerance * 2)
        grey = rgb.mean(axis=-1, keepdims=True)
        out[..., :3] = np.where(fringe[..., None], grey * 0.7 + rgb * 0.3, rgb)

    out[..., 3] = np.where(keep, alpha, 0)
    Image.fromarray(out.astype(np.uint8), "RGBA").save(args.output)
    pct = 100.0 * bg_mask.mean()
    print(f"bg={tuple(bg.astype(int))} removed={pct:.1f}% of pixels -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
