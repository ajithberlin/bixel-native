#!/usr/bin/env python3
"""Crop an AI-generated top-down map image to its playable content.

AI map generators frequently add a black border carrying coordinate labels
(column numbers / row numbers) and sometimes a watermark in a corner
(e.g. 'AI-generated' text). Both must be removed before the image is used as
a game map, or the labels become part of the world and shift every collision
coordinate.

  1. Threshold near-black pixels.
  2. Content bounding box = rows/cols where >50% of pixels are non-black
     (the map rectangle dominates; label text does not).
  3. Optional extra edge crops for corner watermarks (--crop-left etc.).

Usage:
  python3 crop_map.py INPUT.png OUTPUT.png [--dark 45] [--crop-left N] [--crop-bottom N]
"""
import argparse

import numpy as np
from PIL import Image


def main():
    p = argparse.ArgumentParser()
    p.add_argument('input')
    p.add_argument('output')
    p.add_argument('--dark', type=int, default=45, help='sum-of-RGB below this counts as border black')
    p.add_argument('--crop-left', type=int, default=0)
    p.add_argument('--crop-right', type=int, default=0)
    p.add_argument('--crop-top', type=int, default=0)
    p.add_argument('--crop-bottom', type=int, default=0)
    args = p.parse_args()

    im = Image.open(args.input).convert('RGB')
    a = np.array(im)
    nonblack = a.sum(axis=2) > args.dark
    ys = np.where(nonblack.mean(axis=1) > 0.5)[0]
    xs = np.where(nonblack.mean(axis=0) > 0.5)[0]
    if len(xs) == 0 or len(ys) == 0:
        raise SystemExit('ERROR: no content found; lower --dark')
    box = (xs.min() + args.crop_left, ys.min() + args.crop_top,
           xs.max() + 1 - args.crop_right, ys.max() + 1 - args.crop_bottom)
    out = im.crop(box)
    out.save(args.output)
    print(f'[done] {im.size} -> crop box {box} -> {out.size} saved to {args.output}')
    print('[next] record the final pixel size; collision rects must be defined against it')


if __name__ == '__main__':
    main()
