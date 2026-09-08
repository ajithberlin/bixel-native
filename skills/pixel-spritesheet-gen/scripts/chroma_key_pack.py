#!/usr/bin/env python3
"""Remove the chroma-green background from AI-generated spritesheet(s),
detect every frame row-by-row, normalize each frame into a uniform cell
(bottom-center pivot, feet aligned), and pack ALL frames into ONE
transparent PNG atlas + ONE JSON descriptor.

This enforces the skill's Core Basics:
  - uniform grid size: every cell in the atlas is exactly the same W x H,
    even when the pose does not fill the box;
  - consistent pivot: each frame is pasted bottom-center in its cell, so
    feet stay aligned and loops do not jitter;
  - padding/bleed: zero margin by default, or a uniform transparent
    padding (--padding) around every cell to stop adjacent-pixel bleeding;
  - frame count: actions are designed for 4-8 keyframes. Generate 4 frames
    per row per image (the AI reliability ceiling); for 5-8 frames generate
    TWO strips and give the rows the SAME action name — the packer
    concatenates them, in order, into one action row.

Usage:
    python3 chroma_key_pack.py sheet.png \
        --actions "idle,walk,talk" \
        --out-image atlas.png --out-json atlas.json

    # several sheets -> ONE atlas + ONE json (';' separates sheets):
    python3 chroma_key_pack.py walk.png gestures.png \
        --actions "walk_down,walk_left,walk_right,walk_up;idle,think" \
        --out-image atlas.png --out-json atlas.json

    # strip-merge: two 4-frame strips -> one 8-frame action:
    python3 chroma_key_pack.py walk_a.png walk_b.png \
        --actions "walk_down,walk_left;walk_down,walk_left" \
        --out-image atlas.png --out-json atlas.json

Key color: sampled from the sheet corners by default (robust when the
generator's green is not exactly #00FF00). Override with --key R,G,B.

JSON shape:
{
  "image": "atlas.png", "cell": {"w": W, "h": H}, "padding": P,
  "pivot": {"x": 0.5, "y": 1.0},          # bottom-center, feet aligned
  "actions": {
    "<name>": {"row": 0,
                "frames": [{"x":..,"y":..,"w":W,"h":H,      # cell rect
                             "sprite": {"x":..,"y":..,"w":..,"h":..}}, ...]}
  }
}
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def sample_key(a: np.ndarray) -> np.ndarray:
    h, w = a.shape[:2]
    corners = np.concatenate([
        a[:20, :20].reshape(-1, 3), a[:20, -20:].reshape(-1, 3),
        a[-20:, :20].reshape(-1, 3), a[-20:, -20:].reshape(-1, 3),
    ])
    return np.median(corners, axis=0)


def keyout(a: np.ndarray, key: np.ndarray, tol: int) -> np.ndarray:
    """Return RGBA array; chroma pixels -> alpha 0, plus edge despill."""
    dist = np.abs(a.astype(int) - key.astype(int)).sum(axis=2)
    alpha = np.where(dist > tol, 255, 0).astype(np.uint8)
    rgba = np.dstack([a, alpha])
    # Despill ONLY pixels touching transparency (protects green clothing).
    edge = (alpha > 0) & (ndimage.binary_erosion(alpha > 0, iterations=2) == 0)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    spill = edge & (g > r) & (g > b)
    rgba[..., 1] = np.where(spill, np.maximum(r, b), g)
    return rgba


def bands(proj: np.ndarray, min_gap: int = 8) -> list[tuple[int, int]]:
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


def detect_rows(fg: np.ndarray, min_area: int = 40, min_h: int = 10,
                bridge: int = 5):
    """Return list of rows; each row is a list of (x1,y1,x2,y2) sorted by x.

    `bridge` closes small holes (held props disconnected from the body by
    keyed edge pixels) WITHOUT merging frames: inter-frame gaps must stay
    much larger than 2*bridge px — the prompt playbook's "generous gaps".
    Extraction still uses the raw alpha; closing only affects detection.
    """
    det = ndimage.binary_closing(fg, iterations=bridge)
    lab, n = ndimage.label(det)
    boxes = []
    for k, sl in enumerate(ndimage.find_objects(lab), 1):
        if sl is None:
            continue
        area = (lab[sl] == k).sum()
        h = sl[0].stop - sl[0].start
        if area >= min_area and h >= min_h:
            boxes.append((sl[1].start, sl[0].start, sl[1].stop - 1, sl[0].stop - 1))
    rows = []
    for r1, r2 in bands(det.any(axis=1)):
        row = [b for b in boxes if b[1] >= r1 - 4 and b[3] <= r2 + 4]
        rows.append(sorted(row, key=lambda b: b[0]))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('sheets', nargs='+')
    ap.add_argument('--actions', required=True,
                    help='row/action names: comma list per sheet, sheets '
                         'separated by ";" (must match row order)')
    ap.add_argument('--out-image', required=True)
    ap.add_argument('--out-json', required=True)
    ap.add_argument('--tol', type=int, default=45,
                    help='chroma key tolerance (per-channel L1 distance)')
    ap.add_argument('--key', default=None,
                    help='R,G,B chroma color; default: sampled from corners')
    ap.add_argument('--cell', default=None,
                    help='WxH force cell size (e.g. 64x64); default: auto '
                         '(max frame size across all sheets)')
    ap.add_argument('--snap', type=int, default=1,
                    help='round auto cell size UP to a multiple (e.g. 32)')
    ap.add_argument('--padding', type=int, default=0,
                    help='uniform transparent padding around each cell (px); '
                         '0 = zero margins, use 1-2 to stop texture bleeding')
    args = ap.parse_args()

    sheet_actions = [s.split(',') for s in args.actions.split(';')]
    if len(sheet_actions) != len(args.sheets):
        print(f'ERROR: --actions has {len(sheet_actions)} sheet group(s) but '
              f'{len(args.sheets)} sheet(s) given. Use ";" between sheets.')
        return 1

    # 1) keyout + frame detection per sheet
    all_rows, all_names, keyed = [], [], []
    for path, names in zip(args.sheets, sheet_actions):
        a = np.asarray(Image.open(path).convert('RGB'))
        key = (np.array([int(x) for x in args.key.split(',')])
               if args.key else sample_key(a))
        rgba = keyout(a, key, args.tol)
        rows = detect_rows(rgba[..., 3] > 0)
        if len(rows) != len(names):
            print(f'ERROR: {path}: detected {len(rows)} row(s) but '
                  f'{len(names)} action name(s) given: {names}')
            return 1
        counts = [len(r) for r in rows]
        if len(set(counts)) > 1:
            print(f'WARN: {path}: uneven frame counts per row {counts} — '
                  'check for merged/split frames before shipping.')
        keyed.append(rgba)
        all_rows.extend(rows)
        all_names.extend(names)
        print(f'{path}: key={key.astype(int).tolist()} tol={args.tol} '
              f'rows={len(rows)} frames/row={counts}')

    # 2) uniform cell size across EVERYTHING (Core Basics #1)
    flat = [b for row in all_rows for b in row]
    if not flat:
        print('ERROR: no frames detected.')
        return 1
    if args.cell:
        cw, ch = (int(v) for v in args.cell.lower().split('x'))
    else:
        cw = max(b[2] - b[0] + 1 for b in flat)
        ch = max(b[3] - b[1] + 1 for b in flat)
    cw = -(-cw // args.snap) * args.snap
    ch = -(-ch // args.snap) * args.snap
    too_big = [b for b in flat if b[2] - b[0] + 1 > cw or b[3] - b[1] + 1 > ch]
    if too_big:
        print(f'ERROR: {len(too_big)} frame(s) exceed cell {cw}x{ch}; '
              'use a larger --cell.')
        return 1

    # 3) pack: bottom-center pivot (Core Basics #2), uniform padding (#3)
    # Strip-merge: the SAME action name on several input rows concatenates
    # its frames in order — this is how 5-8 frame actions are built from
    # two 3-4 frame strips (Core Basics #4: generate 4, merge to 4-8).
    pad = args.padding
    order, strips, row_sheet = [], {}, {}
    ri = 0
    for si, names in enumerate(sheet_actions):
        for name in names:
            if name not in strips:
                order.append(name)
                strips[name] = []
            strips[name].append(ri)
            row_sheet[ri] = si
            ri += 1
    counts = {name: sum(len(all_rows[r]) for r in rs) for name, rs in strips.items()}
    cols = max(counts.values())
    nrows = len(order)
    W = cols * cw + (cols + 1) * pad
    H = nrows * ch + (nrows + 1) * pad
    atlas = np.zeros((H, W, 4), dtype=np.uint8)
    actions = {}
    for ri_out, name in enumerate(order):
        frames, ci = [], 0
        cy = pad + ri_out * (ch + pad)
        for r in strips[name]:
            rgba = keyed[row_sheet[r]]
            for (x1, y1, x2, y2) in all_rows[r]:
                fw, fh = x2 - x1 + 1, y2 - y1 + 1
                cx = pad + ci * (cw + pad)
                # bottom-center pivot: feet on cell bottom, horizontally centered
                ox = cx + (cw - fw) // 2
                oy = cy + (ch - fh)
                atlas[oy:oy + fh, ox:ox + fw] = rgba[y1:y2 + 1, x1:x2 + 1]
                frames.append({
                    'x': cx, 'y': cy, 'w': cw, 'h': ch,
                    'sprite': {'x': ox, 'y': oy, 'w': fw, 'h': fh},
                })
                ci += 1
        actions[name] = {'row': ri_out, 'frames': frames}

    Image.fromarray(atlas, 'RGBA').save(args.out_image)
    meta = {
        'image': args.out_image.split('/')[-1],
        'size': {'w': W, 'h': H},
        'cell': {'w': cw, 'h': ch},
        'padding': pad,
        'pivot': {'x': 0.5, 'y': 1.0,
                  'note': 'bottom-center; feet aligned on cell bottom'},
        'actions': actions,
    }
    with open(args.out_json, 'w') as f:
        json.dump(meta, f, indent=2)
    total = sum(len(v['frames']) for v in actions.values())
    print(f'atlas: {args.out_image}  {W}x{H}  cell={cw}x{ch} pad={pad} '
          f'rows={nrows} frames={total}')
    print(f'json : {args.out_json}  actions={list(actions)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
