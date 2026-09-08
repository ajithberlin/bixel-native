#!/usr/bin/env python3
"""Batch-verify normalized pixel-art UI assets against the kit contract.

Checks per image:
  FAIL  not a readable image
  FAIL  transparent pixels (assets must be opaque)
  FAIL  width/height not multiples of 32
  FAIL  a corner pixel is not the EXACT background color
  FAIL  filename is not snake_case
  FAIL  no foreground detected
  FAIL  foreground touches the image edge (padding < --pad-min)
  WARN  border ring has non-background bleed (> 2%)
  WARN  foreground is scattered fragments (largest blob < 60% of fg area)
  WARN  component is off-center by more than 1/8 of the canvas
  WARN  more than --max-colors unique colors (palette noise)

Exit code 1 if any FAIL. Every FAIL prints a reprompt hint.

Example:
  python3 verify_set.py assets/ --pad-min 1
"""
import argparse
import os
import re
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

SNAKE = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*$")


def hex2rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def verify(path, bg, tol, pad_min, max_colors):
    fails, warns = [], []
    name = os.path.splitext(os.path.basename(path))[0]
    if not SNAKE.match(name):
        fails.append(f"filename {name!r} is not snake_case — rename like 'button_primary_hover'")

    try:
        im = Image.open(path)
    except Exception as e:
        return [f"unreadable image: {e}"], warns
    rgba = np.asarray(im.convert("RGBA"))
    if rgba[..., 3].min() < 255:
        fails.append("transparent pixels found — assets must be fully opaque "
                     "(re-run normalize_component.py, it flattens alpha)")
    arr = rgba[..., :3].astype(np.int16)
    H, W = arr.shape[:2]

    if W % 32 or H % 32:
        fails.append(f"dimensions {W}x{H} are not multiples of 32 — "
                     f"re-normalize with a valid --size")
    bgvec = np.array(bg, dtype=np.int16)
    for cx, cy in ((0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)):
        px = tuple(int(v) for v in arr[cy, cx])
        if px != bg:
            fails.append(f"corner pixel #{px[0]:02X}{px[1]:02X}{px[2]:02X} is not exact "
                         f"#{''.join(f'{v:02X}' for v in bg)} — re-normalize to snap the background")
            break

    diff = np.abs(arr - bgvec).max(axis=2)
    mask = diff > tol
    total = int(mask.sum())
    if total == 0:
        fails.append("no foreground detected (image is all background)")
        return fails, warns

    ys, xs = np.where(mask)
    x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1
    pads = (x0, y0, W - x1, H - y1)
    if min(pads) < pad_min:
        fails.append(f"foreground touches the edge (padding {pads}, need >= {pad_min}) — "
                     "outline/shadow may be cropped; reprompt with 'generous empty margin' or "
                     "re-normalize with a larger canvas")

    ring = np.concatenate([diff[0, :], diff[-1, :], diff[:, 0], diff[:, -1]])
    bleed = float((ring > tol).mean())
    if bleed > 0.02:
        warns.append(f"border ring has {bleed:.0%} non-background pixels (bg bleed/gradient)")

    lab, n = ndimage.label(mask)
    if n > 1:
        sizes = ndimage.sum(mask, lab, range(1, n + 1))
        if sizes.max() / total < 0.6 and n > 4:
            warns.append(f"foreground scattered into {n} fragments (largest {sizes.max() / total:.0%}) "
                         "— check for stray pixels or detached decals")

    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if abs(cx - W / 2) > W / 8 or abs(cy - H / 2) > H / 8:
        warns.append(f"off-center by ({cx - W / 2:+.0f},{cy - H / 2:+.0f})px")

    ncolors = len(np.unique(arr.reshape(-1, 3), axis=0))
    if ncolors > max_colors:
        warns.append(f"{ncolors} unique colors (palette noise) — consider --colors quantization "
                     "or reprompt with 'limited 8-color palette'")
    return fails, warns


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("assets_dir")
    p.add_argument("--bg", default="FF00FF")
    p.add_argument("--tol", type=int, default=60)
    p.add_argument("--pad-min", type=int, default=1)
    p.add_argument("--max-colors", type=int, default=64)
    args = p.parse_args()

    bg = hex2rgb(args.bg)
    files = []
    for root, _, names in os.walk(args.assets_dir):
        files += [os.path.join(root, f) for f in names if f.lower().endswith(".png")]
    files.sort()
    if not files:
        sys.exit(f"error: no PNG files under {args.assets_dir}")

    n_pass = n_warn = n_fail = 0
    for path in files:
        fails, warns = verify(path, bg, args.tol, args.pad_min, args.max_colors)
        rel = os.path.relpath(path, args.assets_dir)
        if fails:
            n_fail += 1
            print(f"FAIL  {rel}")
            for f in fails:
                print(f"      - {f}")
        elif warns:
            n_warn += 1
            print(f"WARN  {rel}")
            for w in warns:
                print(f"      - {w}")
        else:
            n_pass += 1
            print(f"pass  {rel}")
    print(f"\nsummary: {n_pass} pass, {n_warn} warn, {n_fail} fail  ({len(files)} files)")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
