#!/usr/bin/env python3
"""Extract sprites from an AI-generated spritesheet and repack them into a
clean, uniform, transparent game-ready sheet + JSON manifest.

Why this exists: AI image models do NOT place frames on a strict pixel grid.
Frame positions drift, sizes vary, header labels ('IDLE', 'WALK'...) and row
labels ('DOWN'...) sit in the sheet, and the background is near-uniform but
not exactly one color. Never assume a fixed grid — SEGMENT, don't slice.

Pipeline:
  1. Sample the background color from the image corners.
  2. Build a foreground mask (color distance > tolerance).
  3. Detect content ROW bands via horizontal projection (labels are filtered
     out: header/label bands are much shorter than sprite rows).
  4. Detect column GROUP bands the same way on the vertical projection.
  5. Inside each (group x row) cell, find sprites with connected components,
     sort left-to-right, trim to bbox, key out the background -> RGBA.
  6. Repack all frames bottom-anchored (feet aligned!) into a uniform grid.
  7. Emit a manifest JSON the game engine can consume.

Usage:
  python3 extract_spritesheet.py INPUT.png --out-sheet out.png --out-manifest out.json \
      [--row-names down,left,right,up] [--group-names idle,walk,run,talk] \
      [--frames-per-group 3] [--tol 60] [--pad 4]

Requires: pillow, numpy, scipy.
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def bands(profile, thresh):
    """Contiguous index ranges where profile > thresh."""
    out, start = [], None
    for i, v in enumerate(profile):
        if v > thresh and start is None:
            start = i
        elif v <= thresh and start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(profile)))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('input')
    p.add_argument('--out-sheet', required=True)
    p.add_argument('--out-manifest', required=True)
    p.add_argument('--row-names', default='', help='comma list, top->bottom (e.g. down,left,right,up)')
    p.add_argument('--group-names', default='', help='comma list, left->right (e.g. idle,walk,run,talk)')
    p.add_argument('--frames-per-group', type=int, default=0, help='expected frames per cell (0 = take all found)')
    p.add_argument('--tol', type=float, default=60, help='bg color distance threshold (sum of RGB abs diff)')
    p.add_argument('--pad', type=int, default=4, help='transparent padding around each frame in output cell')
    p.add_argument('--min-sprite-h', type=int, default=40, help='min pixel height for a component to count as a sprite')
    args = p.parse_args()

    im = Image.open(args.input).convert('RGB')
    a = np.array(im).astype(int)

    # 1. background color = median of the four 8x8 corner patches
    corners = np.concatenate([a[:8, :8].reshape(-1, 3), a[:8, -8:].reshape(-1, 3),
                              a[-8:, :8].reshape(-1, 3), a[-8:, -8:].reshape(-1, 3)])
    bg = np.median(corners, axis=0)
    print(f'[bg] sampled background color: {bg.astype(int).tolist()}')

    # 2. foreground mask
    mask = np.abs(a - bg).sum(axis=2) > args.tol

    # 3. row bands (filter label bands: keep bands whose height >= 40% of the tallest)
    rows_raw = bands(mask.sum(axis=1), max(10, im.width // 100))
    if not rows_raw:
        sys.exit('ERROR: no content rows found; raise --tol or check the image')
    tallest = max(b[1] - b[0] for b in rows_raw)
    row_bands = [b for b in rows_raw if (b[1] - b[0]) >= 0.4 * tallest]
    print(f'[rows] {len(rows_raw)} bands found, kept {len(row_bands)} sprite rows: {row_bands}')

    # 4. column groups. Analyze the FIRST sprite row only: full-image x-projection
    # mixes in label text and merges everything. Frame bands within a group sit
    # close together; groups are separated by wider gaps.
    ry0, ry1 = row_bands[0]
    strip = mask[ry0:ry1, :]
    frame_bands = [b for b in bands(strip.sum(axis=0), max(5, (ry1 - ry0) // 20))
                   if b[1] - b[0] >= 20]
    # merge bands closer than 15px (stray fragments of one frame)
    merged = []
    for b in frame_bands:
        if merged and b[0] - merged[-1][1] < 15:
            merged[-1] = (merged[-1][0], b[1])
        else:
            merged.append(b)
    frame_bands = merged
    if args.frames_per_group:
        fpg = args.frames_per_group
        if len(frame_bands) % fpg != 0:
            print(f'[warn] {len(frame_bands)} frame bands in row 0 not divisible by '
                  f'--frames-per-group {fpg}; check detection')
        cols_raw = []
        for i in range(0, len(frame_bands) - fpg + 1, fpg):
            chunk = frame_bands[i:i + fpg]
            cols_raw.append((chunk[0][0], chunk[-1][1]))
    else:
        # gap-based fallback: split where gap > 2x median gap
        gaps = [frame_bands[i + 1][0] - frame_bands[i][1] for i in range(len(frame_bands) - 1)]
        med = sorted(gaps)[len(gaps) // 2] if gaps else 0
        cols_raw, cur_start = [], 0
        for i, g in enumerate(gaps):
            if g > max(2 * med, 30):
                cols_raw.append((frame_bands[cur_start][0], frame_bands[i][1]))
                cur_start = i + 1
        cols_raw.append((frame_bands[cur_start][0], frame_bands[-1][1]))
    groups = cols_raw
    # keep only groups tall enough to hold sprites
    group_bands = []
    for g in groups:
        x0, x1 = g
        sub = mask[:, x0:x1]
        h = bands(sub.sum(axis=1), max(10, (x1 - x0) // 20))
        if h and max(e - s for s, e in h) >= args.min_sprite_h:
            group_bands.append(g)
    print(f'[groups] kept {len(group_bands)} column groups: {group_bands}')

    row_names = args.row_names.split(',') if args.row_names else [f'row{i}' for i in range(len(row_bands))]
    group_names = args.group_names.split(',') if args.group_names else [f'col{i}' for i in range(len(group_bands))]
    if len(row_names) != len(row_bands):
        sys.exit(f'ERROR: {len(row_names)} row names vs {len(row_bands)} detected rows. Fix --row-names.')
    if len(group_names) != len(group_bands):
        sys.exit(f'ERROR: {len(group_names)} group names vs {len(group_bands)} detected groups. Fix --group-names.')

    # 5. extract per-cell sprites
    sprites = {}  # (group, row) -> list[(rgba array, src bbox)]
    for gi, (x0, x1) in enumerate(group_bands):
        for ri, (y0, y1) in enumerate(row_bands):
            cell = mask[y0:y1, x0:x1]
            lab, _ = ndimage.label(cell)
            found = []
            for sl in ndimage.find_objects(lab):
                if sl is None:
                    continue
                h, w = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
                if h >= args.min_sprite_h and w >= 20:
                    found.append(sl)
            found.sort(key=lambda sl: sl[1].start)
            if args.frames_per_group:
                if len(found) != args.frames_per_group:
                    print(f'[warn] cell ({group_names[gi]},{row_names[ri]}): expected '
                          f'{args.frames_per_group} frames, found {len(found)}')
                found = found[:args.frames_per_group]
            frames = []
            for sl in found:
                sub = a[y0 + sl[0].start:y0 + sl[0].stop, x0 + sl[1].start:x0 + sl[1].stop]
                submask = cell[sl[0].start:sl[0].stop, sl[1].start:sl[1].stop]
                rgba = np.dstack([sub, (submask * 255).astype(np.uint8)]).astype(np.uint8)
                frames.append((rgba, [x0 + sl[1].start, y0 + sl[0].start, w, h]))
            sprites[(gi, ri)] = frames
            print(f'[cell] {group_names[gi]:>8} / {row_names[ri]:<6}: {len(frames)} frames')

    # 6. repack bottom-anchored into uniform grid
    max_w = max(f[0].shape[1] for frames in sprites.values() for f in frames)
    max_h = max(f[0].shape[0] for frames in sprites.values() for f in frames)
    cell_w, cell_h = max_w + 2 * args.pad, max_h + 2 * args.pad
    n_cols = max(len(v) for v in sprites.values()) * len(group_names)
    sheet = Image.new('RGBA', (cell_w * n_cols, cell_h * len(row_bands)), (0, 0, 0, 0))
    import os
    manifest = {
        'image': os.path.basename(args.out_sheet),
        'frameWidth': cell_w, 'frameHeight': cell_h,
        'columns': n_cols, 'rows': len(row_bands),
        'frameCount': sum(len(v) for v in sprites.values()),
        'anchor': {'x': 0.5, 'y': 1.0, 'note': 'bottomCenter; frames bottom-anchored (feet aligned)'},
        'directions': {name: i for i, name in enumerate(row_names)},
        'actions': {},
        'animations': {},
    }
    for gi, gname in enumerate(group_names):
        first_col = gi * len(sprites[(gi, 0)])
        manifest['actions'][gname] = {'firstColumn': first_col, 'frames': len(sprites[(gi, 0)])}
        for ri, rname in enumerate(row_names):
            for fi, (rgba, bbox) in enumerate(sprites[(gi, ri)]):
                img = Image.fromarray(rgba, 'RGBA')
                x = (gi * len(sprites[(gi, ri)]) + fi) * cell_w + (cell_w - img.width) // 2
                y = ri * cell_h + (cell_h - img.height)  # bottom anchor = feet aligned
                sheet.paste(img, (x, y), img)
        for rname in row_names:
            manifest['animations'][f'{gname}_{rname}'] = {
                'row': row_names.index(rname), 'firstColumn': first_col,
                'frames': len(sprites[(gi, 0)]),
                'texturePosition': [first_col * cell_w, row_names.index(rname) * cell_h],
            }
    sheet.save(args.out_sheet)
    with open(args.out_manifest, 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f'[done] sheet {sheet.size} -> {args.out_sheet}')
    print(f'[done] manifest -> {args.out_manifest}')
    print('[next] wire into engine: texturePosition = Vector2(col*cellW, row*cellH), '
          'textureSize = Vector2(cellW, cellH)')


if __name__ == '__main__':
    main()
