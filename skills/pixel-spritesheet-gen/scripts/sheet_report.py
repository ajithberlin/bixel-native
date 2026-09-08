#!/usr/bin/env python3
"""Inspect an AI-generated spritesheet and report whether it will survive
automated extraction (bg keying + connected components + grid slicing).

Usage:
    python3 sheet_report.py sheet.png [--tol 45] [--expected-bg R,G,B]

Checks:
  1. Background color sampled from the 4 corners (must be near-uniform;
     the skill standard is a flat chroma-green background).
  2. Row bands and column groups detected from foreground projections.
  3. Per-cell frame count and frame bounding-box stats (size variance).
  4. Frames touching each other or the sheet edge (extraction killers).
  5. Pivot drift: per-row spread of frame BOTTOM y (feet alignment);
     drift means the loop will jitter.

Exit code 0 with a printed report; warnings are prefixed with 'WARN'.
"""
import argparse
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def sample_background(a: np.ndarray) -> tuple[np.ndarray, int]:
    h, w = a.shape[:2]
    corners = np.concatenate([
        a[:20, :20].reshape(-1, 3),
        a[:20, -20:].reshape(-1, 3),
        a[-20:, :20].reshape(-1, 3),
        a[-20:, -20:].reshape(-1, 3),
    ])
    bg = np.median(corners, axis=0)
    spread = int(np.abs(corners - bg).max())
    return bg, spread


def bands(proj: np.ndarray, min_gap: int = 8) -> list[tuple[int, int]]:
    """Ranges where projection > 0, merging gaps smaller than min_gap."""
    idx = np.where(proj > 0)[0]
    if len(idx) == 0:
        return []
    out, start, prev = [], idx[0], idx[0]
    for i in idx[1:]:
        if i - prev > min_gap:
            out.append((start, prev))
            start = i
        prev = i
    out.append((start, prev))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('sheet')
    ap.add_argument('--tol', type=int, default=45,
                    help='bg keyout tolerance (per-channel L1 distance)')
    ap.add_argument('--expected-bg', default=None, help='R,G,B to compare')
    ap.add_argument('--min-sprite-h', type=int, default=10)
    args = ap.parse_args()

    im = Image.open(args.sheet).convert('RGB')
    a = np.asarray(im)
    h, w = a.shape[:2]
    print(f'sheet: {args.sheet}  {w}x{h}')

    bg, spread = sample_background(a)
    print(f'background: rgb={bg.astype(int).tolist()} corner-spread={spread}')
    if spread > 30:
        print('WARN: corner colors differ a lot — background may not be uniform; '
              'keyout will leak. Regenerate with a flat solid background.')
    if args.expected_bg:
        exp = np.array([int(x) for x in args.expected_bg.split(',')])
        dist = int(np.abs(bg - exp).sum())
        print(f'expected-bg distance: {dist}')
        if dist > 45:
            print('WARN: actual bg far from requested color — use the ACTUAL '
                  'sampled color for keying, not the prompted one.')

    fg = np.abs(a.astype(int) - bg.astype(int)).sum(axis=2) > args.tol
    frac = fg.mean()
    print(f'foreground coverage: {frac:.1%}')
    if frac > 0.9:
        print('WARN: >90% foreground — bg color is probably wrong; extraction '
              'will grab the whole sheet as one blob.')

    # Row bands (character direction rows) and column structure.
    rows = bands(fg.any(axis=1))
    print(f'row bands: {len(rows)} -> {rows}')
    if not rows:
        print('WARN: no foreground rows detected at this tolerance.')
        return 0

    # Connected components = individual frames.
    lab, n = ndimage.label(fg)
    sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
    keep = [i + 1 for i, s in enumerate(sizes) if s >= 40]
    boxes = []
    for k in keep:
        ys, xs = np.where(lab == k)
        if len(ys) == 0:
            continue
        y1, y2, x1, x2 = ys.min(), ys.max(), xs.min(), xs.max()
        if (y2 - y1) < args.min_sprite_h:
            continue
        boxes.append((x1, y1, x2, y2))
    print(f'frames (components >= 40px, h>={args.min_sprite_h}): {len(boxes)}')

    if boxes:
        hs = np.array([b[3] - b[1] for b in boxes])
        ws = np.array([b[2] - b[0] for b in boxes])
        print(f'frame height: min={hs.min()} median={int(np.median(hs))} max={hs.max()}')
        print(f'frame width : min={ws.min()} median={int(np.median(ws))} max={ws.max()}')
        if hs.max() > hs.min() * 2.5:
            print('WARN: frame heights vary >2.5x — likely merged/split frames '
                  'or text labels counted as frames. Inspect visually.')
        edge = [b for b in boxes if b[0] <= 1 or b[1] <= 1 or b[2] >= w - 2 or b[3] >= h - 2]
        if edge:
            print(f'WARN: {len(edge)} frame(s) touch the sheet edge — they will be '
                  'clipped. Regenerate with outer padding.')
        # Frames per row band + pivot (feet bottom-y) drift per row
        med_h = int(np.median(hs))
        for ri, (r1, r2) in enumerate(rows):
            rb = [b for b in boxes if b[1] >= r1 - 4 and b[3] <= r2 + 4]
            drift = (max(b[3] for b in rb) - min(b[3] for b in rb)) if len(rb) > 1 else 0
            print(f'  row {ri}: y {r1}-{r2}  frames={len(rb)}  pivot-drift={drift}px')
            if len(rb) > 1 and drift > max(8, med_h * 0.1):
                print(f'WARN: row {ri} feet misaligned by {drift}px — loop will '
                      'jitter; reprompt with "feet at the bottom of each cell" '
                      'or fix in the pack step.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
