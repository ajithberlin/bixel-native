#!/usr/bin/env python3
"""Extract sprites from IRREGULAR / scattered-layout sheets and pack them
into ONE transparent PNG atlas + ONE JSON descriptor.

Use this instead of chroma_key_pack.py when the sheet is NOT a strict grid:
poses scattered at arbitrary positions, mixed sizes, multi-part sprites
(character + held prop + effect cloud), overlapping bounding boxes,
white or any other flat background (not just chroma green).

How it fixes the three classic irregular-sheet failures:

  1. "not cropped based on the image"
     Grid slicers cut fixed cells / row bands. This script crops every
     sprite to the exact bounding box of ITS OWN pixels (content crop),
     then normalizes into uniform cells — so the crop always follows the
     artwork, never a guessed grid.

  2. "some other image gets cropped in"
     Sprites are found as PIXEL-PROXIMITY CLUSTERS of connected
     components, not as rectangles. When two sprites' bounding boxes
     overlap (flying poses, long weapons), the crop keeps only the
     pixels of the components that belong to THIS sprite and erases
     foreign pixels inside the box — neighbors can never bleed in.

  3. "not centered on the intended object -> animation glitches"
     Every sprite is pasted into its uniform cell by a chosen pivot:
     --pivot centroid (default, alpha-weighted center of mass -> the
     object itself stays rock-steady across frames), bottom (feet on
     cell bottom, for standing characters), or center (bbox center).

Usage:
    # one scattered sheet, all sprites -> one action in reading order:
    python3 freeform_pack.py sheet.png --actions auto \
        --out-image atlas.png --out-json atlas.json

    # named rows (one name per detected cluster-row, ';' between sheets):
    python3 freeform_pack.py fly.png --actions "fly" \
        --out-image atlas.png --out-json atlas.json

    # tuning the cluster bridge when parts get split/merged:
    python3 freeform_pack.py sheet.png --actions auto --merge 48 \
        --out-image atlas.png --out-json atlas.json

Background: sampled automatically from the image border (works for white,
chroma green, or any near-flat color). Override with --key R,G,B.

JSON shape matches chroma_key_pack.py (cell, padding, pivot, per-action
frame rects) plus a "layout": "freeform" marker and per-frame source rect.
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


# ---------------------------------------------------------------- background

def detect_bg(a: np.ndarray) -> np.ndarray:
    """Median color of the outer border strip -> the background color.
    Robust for white, chroma green, or any near-flat backdrop."""
    h, w = a.shape[:2]
    s = max(4, min(h, w) // 50)
    border = np.concatenate([
        a[:s, :].reshape(-1, 3), a[-s:, :].reshape(-1, 3),
        a[:, :s].reshape(-1, 3), a[:, -s:].reshape(-1, 3),
    ])
    return np.median(border, axis=0)


def keyout(a: np.ndarray, key: np.ndarray, tol: int) -> np.ndarray:
    """RGBA array; background-colored pixels -> alpha 0.
    Green-dominant keys additionally get edge despill (protects green
    clothing); light keys get nothing here (halo handled by edge trim)."""
    dist = np.abs(a.astype(int) - key.astype(int)).sum(axis=2)
    alpha = np.where(dist > tol, 255, 0).astype(np.uint8)
    rgba = np.dstack([a, alpha])
    if key[1] > key[0] + 40 and key[1] > key[2] + 40:  # green backdrop only
        edge = (alpha > 0) & (ndimage.binary_erosion(alpha > 0, iterations=2) == 0)
        r, g, b = (a[..., 0].astype(int), a[..., 1].astype(int),
                   a[..., 2].astype(int))
        spill = edge & (g > r) & (g > b)
        rgba[..., 1] = np.where(spill, np.maximum(r, b), g).astype(np.uint8)
    return rgba


# ------------------------------------------------------------- segmentation

def strip_grid_lines(fg: np.ndarray, min_len: int) -> np.ndarray:
    """Remove grid/cell divider lines from the foreground mask.

    Divider lines differ from the background color, so they key out as
    foreground and — spanning the sheet — fuse every sprite into one
    giant cluster. A directional morphological opening with a long 1-px
    kernel keeps ONLY axis-aligned runs of >= min_len px: grid lines
    survive it, blob artwork does not. Removing those pixels costs art at
    most a 1-px seam (healed by the merge bridge during detection); thin
    artwork like weapons or speed streaks is far shorter than min_len
    and passes through untouched. 0 = off.
    """
    if min_len <= 0:
        return fg
    hh, ww = fg.shape
    lh = min_len if min_len > 1 else max(8, round(0.08 * ww))
    lv = min_len if min_len > 1 else max(8, round(0.08 * hh))
    max_thick = max(8, round(0.007 * min(hh, ww)))
    lines = np.zeros_like(fg)
    # A line must be LONG and THIN: opening with a long 1-px kernel finds
    # pixels on long axis-aligned runs; the width check then rejects tall
    # artwork (a big sprite has long vertical runs too, but hundreds of
    # px wide — a grid line is only a few px wide).
    for struct, axis in ((np.ones((1, lh)), 0), (np.ones((lv, 1)), 1)):
        opened = ndimage.binary_opening(fg, structure=struct)
        lab, n = ndimage.label(opened)
        for sl in ndimage.find_objects(lab):
            if sl is None:
                continue
            thick = (sl[axis].stop - sl[axis].start)
            if thick <= max_thick:
                lines[sl] |= opened[sl]
    lines = ndimage.binary_dilation(lines, iterations=1)
    return fg & ~lines


def clean_line_crumbs(mask: np.ndarray, run: int = 60, thick: int = 2):
    """Remove short divider-line CRUMBS: axis-aligned runs >= run px that
    vanish under a small erosion (i.e. <= ~2*thick px thick). These are
    grid-line fragments too short for strip_grid_lines; they otherwise
    bridge clusters or end up as thin line artifacts inside crops.
    Real artwork is either thicker (survives the erosion) or not
    axis-aligned (diagonal wisps have no long straight runs)."""
    if run <= 0:
        return mask
    h = ndimage.binary_opening(mask, structure=np.ones((1, run)))
    v = ndimage.binary_opening(mask, structure=np.ones((run, 1)))
    thin = ~ndimage.binary_erosion(mask, iterations=thick)
    return mask & ~((h | v) & thin)


def drop_line_stubs(fg: np.ndarray, lab: np.ndarray, thick: int):
    """Zero out leftover line stubs in the label map: components that are
    extremely thin and extremely straight (one bbox side <= thick and an
    aspect ratio > 6) — residual divider fragments. Diagonal/curved thin
    art (wisps, streaks) has a thicker bbox and is kept."""
    for k, sl in enumerate(ndimage.find_objects(lab), 1):
        if sl is None:
            continue
        bh = sl[0].stop - sl[0].start
        bw = sl[1].stop - sl[1].start
        if min(bh, bw) <= thick and max(bh, bw) > 6 * min(bh, bw):
            lab[sl][lab[sl] == k] = 0
    return lab


def find_sprites(fg: np.ndarray, merge: int, min_area: int,
                 stub_thick: int = 0):
    """Cluster connected components into sprites by pixel proximity.

    `merge` is the bridge radius (px): parts of ONE sprite separated by
    less than ~2*merge px (character + floating staff + effect cloud)
    fuse into one cluster; distinct sprites — which sit much farther
    apart — stay separate. Components smaller than min_area are dropped
    BEFORE clustering so noise never bridges two sprites together.

    Returns a list of dicts: bbox = (x1,y1,x2,y2) of the sprite's own
    pixels, labels = boolean image mask of exactly those pixels.
    """
    lab, n = ndimage.label(fg)
    keep = np.zeros(n + 1, dtype=bool)
    for k, sl in enumerate(ndimage.find_objects(lab), 1):
        if sl is not None and (lab[sl] == k).sum() >= min_area:
            keep[k] = True
    lab = np.where(keep[lab], lab, 0)
    if stub_thick > 0:
        lab = drop_line_stubs(fg, lab, stub_thick)

    bridge = ndimage.binary_dilation(lab > 0, iterations=merge)
    clab, cn = ndimage.label(bridge)
    sprites = []
    for c in range(1, cn + 1):
        ids = np.unique(lab[clab == c])
        ids = ids[ids > 0]
        if len(ids) == 0:
            continue
        mask = np.isin(lab, ids)
        ys, xs = np.where(mask)
        sprites.append({
            'bbox': (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())),
            'labels': mask,
        })
    return sprites


def split_cluster(mask: np.ndarray, dist: np.ndarray, tol: int, merge: int,
                  min_area: int, cap: int = 200, step: int = 45):
    """Try to split ONE fused cluster into its constituent sprites.

    Two sprites that genuinely touch in the artwork are usually joined by
    a weak, semi-transparent blend (anti-aliased overlap), while a real
    sprite is solid all the way through. Re-keying the cluster at a
    HIGHER tolerance cuts the weak junction but leaves solid sprites
    whole. The split is then grown back to full edge quality by assigning
    every original cluster pixel to its nearest high-tolerance part.

    Returns a list of full-image masks (length 1 = could not split).
    """
    ys, xs = np.where(mask)
    x1, y1, x2, y2 = xs.min(), ys.min(), xs.max(), ys.max()
    sub_mask = mask[y1:y2 + 1, x1:x2 + 1]
    sub_dist = dist[y1:y2 + 1, x1:x2 + 1]
    total = sub_mask.sum()
    t = tol + step
    parts = None
    while t <= cap:
        hot = sub_mask & (sub_dist > t)
        lab, n = ndimage.label(ndimage.binary_dilation(hot, iterations=merge))
        cand = []
        for c in range(1, n + 1):
            m = lab == c
            if (m & hot).sum() >= min_area:
                cand.append(m)
        if len(cand) >= 2 and max(p.sum() for p in cand) < 0.75 * total:
            parts = cand
            break
        t += step
    if not parts:
        return [mask]

    # grow the high-tolerance parts back over the full cluster pixels
    seed_lab = np.zeros(sub_mask.shape, np.int32)
    for i, p in enumerate(parts, 1):
        seed_lab[p] = i
    ind = ndimage.distance_transform_edt(seed_lab == 0, return_distances=False,
                                         return_indices=True)
    assign = seed_lab[tuple(ind)]
    kept, leftover = [], sub_mask.copy()
    for i in range(1, len(parts) + 1):
        m = sub_mask & (assign == i)
        if m.sum() >= min_area:
            kept.append(m)
            leftover &= ~m
    if len(kept) < 2:
        return [mask]
    if leftover.any():  # absorb crumbs into the nearest kept part
        seed_lab = np.zeros(sub_mask.shape, np.int32)
        for i, m in enumerate(kept, 1):
            seed_lab[m] = i
        ind = ndimage.distance_transform_edt(seed_lab == 0,
                                             return_distances=False,
                                             return_indices=True)
        near = seed_lab[tuple(ind)]
        for i, m in enumerate(kept, 1):
            kept[i - 1] = m | (leftover & (near == i))
    out = []
    for m in kept:
        full = np.zeros(mask.shape, bool)
        full[y1:y2 + 1, x1:x2 + 1] = m
        out.append(full)
    return out


def split_cluster_neck(mask: np.ndarray, min_area: int, max_erode: int = 16):
    """Split a fused cluster at its weakest NECK by progressive erosion.

    Sprites that merely TOUCH (a cape tip against a hair strand) share a
    neck far thinner than any sprite body, so some erosion depth cuts the
    contact while every sprite still has a solid core. Seeds smaller than
    3% of the cluster are ignored (fragments), then every cluster pixel
    is grown back to its nearest seed — no artwork is lost. Sprites that
    OVERLAP over wide regions (drawn on top of each other) have no thin
    neck and correctly fail to split.

    Returns (list of full masks, erode depth used); ([mask], 0) if no
    split was found.
    """
    total = mask.sum()
    for er in range(2, max_erode + 1, 2):
        cores = ndimage.binary_erosion(mask, iterations=er)
        lab, n = ndimage.label(cores)
        seeds = []
        for c in range(1, n + 1):
            m = lab == c
            if m.sum() >= max(min_area, 0.03 * total):
                seeds.append(m)
        if len(seeds) >= 2 and max(s.sum() for s in seeds) < 0.75 * total:
            seed_lab = np.zeros(mask.shape, np.int32)
            for i, s in enumerate(seeds, 1):
                seed_lab[s] = i
            ind = ndimage.distance_transform_edt(seed_lab == 0,
                                                 return_distances=False,
                                                 return_indices=True)
            assign = seed_lab[tuple(ind)]
            return [mask & (assign == i) for i in range(1, len(seeds) + 1)], er
    return [mask], 0


def split_oversized(sprites: list, dist: np.ndarray, tol: int, merge: int,
                    min_area: int, factor: float):
    """Split clusters whose bbox dwarfs the median sprite (fused
    neighbors): first by tolerance escalation (weak blended junctions),
    then by neck-cut erosion (thin contact points). Legit big sprites
    survive both — they have neither weak junctions nor thin necks.
    Clusters that still resist are sprites OVERLAPPING in the artwork
    itself; they pass through fused and are reported by the caller.
    factor <= 0 disables. Returns (sprites, n_split, n_unsplittable)."""
    if factor <= 0 or len(sprites) < 3:
        return sprites, 0, 0
    areas = sorted((s['bbox'][2] - s['bbox'][0] + 1) *
                   (s['bbox'][3] - s['bbox'][1] + 1) for s in sprites)
    med = areas[len(areas) // 2]
    out, n_split, n_bad = [], 0, 0
    for s in sprites:
        ar = ((s['bbox'][2] - s['bbox'][0] + 1) *
              (s['bbox'][3] - s['bbox'][1] + 1))
        if ar > factor * med:
            masks = split_cluster(s['labels'], dist, tol, merge, min_area)
            if len(masks) == 1:
                masks, _ = split_cluster_neck(s['labels'], min_area)
            if len(masks) > 1:
                n_split += 1
                for m in masks:
                    ys, xs = np.where(m)
                    out.append({
                        'bbox': (int(xs.min()), int(ys.min()),
                                 int(xs.max()), int(ys.max())),
                        'labels': m,
                    })
                continue
            n_bad += 1
        out.append(s)
    return out, n_split, n_bad


def reading_order(sprites: list) -> list:
    """Sort sprites row-wise (top-to-bottom, left-to-right) without
    assuming a grid: group by y-center proximity, then sort by x.
    Also sets s['_row'] = visual row index for action naming."""
    if not sprites:
        return sprites
    heights = sorted(s['bbox'][3] - s['bbox'][1] + 1 for s in sprites)
    tol = max(8, heights[len(heights) // 2] // 2)
    for s in sprites:
        s['_yc'] = (s['bbox'][1] + s['bbox'][3]) / 2
    rows = []
    for s in sorted(sprites, key=lambda s: s['_yc']):
        for ri, row in enumerate(rows):
            if abs(s['_yc'] - row[0]['_yc']) <= tol:
                row.append(s)
                s['_row'] = ri
                break
        else:
            s['_row'] = len(rows)
            rows.append([s])
    out = []
    for row in rows:
        out.extend(sorted(row, key=lambda s: s['bbox'][0]))
    return out


# ------------------------------------------------------------------- packing

def paste_pivot(atlas, sprite_rgba, cell_xy, cell_wh, pivot):
    """Paste a content-cropped sprite into its cell by the chosen pivot."""
    fh, fw = sprite_rgba.shape[:2]
    cw, ch = cell_wh
    cx, cy = cell_xy
    if pivot == 'bottom':
        ox, oy = cx + (cw - fw) // 2, cy + (ch - fh)
    elif pivot == 'center':
        ox, oy = cx + (cw - fw) // 2, cy + (ch - fh) // 2
    else:  # centroid: alpha-weighted center of mass -> cell center
        a = sprite_rgba[..., 3].astype(float)
        if a.sum() > 0:
            ys, xs = np.where(a > 0)
            w = a[ys, xs]
            mx, my = (xs * w).sum() / w.sum(), (ys * w).sum() / w.sum()
        else:
            mx, my = fw / 2, fh / 2
        ox = int(round(cx + cw / 2 - mx))
        oy = int(round(cy + ch / 2 - my))
    ox = max(cx, min(ox, cx + cw - fw))
    oy = max(cy, min(oy, cy + ch - fh))
    atlas[oy:oy + fh, ox:ox + fw] = sprite_rgba
    return ox, oy


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('sheets', nargs='+')
    ap.add_argument('--actions', required=True,
                    help='"auto" = one action named "frames" holding every '
                         'sprite in reading order; otherwise one name per '
                         'detected visual row, "," between names, ";" '
                         'between sheets (repeat a name to merge rows)')
    ap.add_argument('--out-image', required=True)
    ap.add_argument('--out-json', required=True)
    ap.add_argument('--tol', type=int, default=45,
                    help='background key tolerance (per-channel L1 distance)')
    ap.add_argument('--key', default=None,
                    help='R,G,B background color; default: sampled from border')
    ap.add_argument('--merge', type=int, default=0,
                    help='bridge radius (px) fusing parts of ONE sprite '
                         '(character+prop+effect); 0 = auto (0.8%% of the '
                         'short side). Raise if sprites split, lower if '
                         'neighbors fuse')
    ap.add_argument('--strip-lines', type=int, default=-1,
                    help='remove grid/divider lines (axis-aligned runs '
                         'longer than N px) BEFORE clustering — they '
                         'otherwise fuse all sprites into one cluster; '
                         'thin artwork is far shorter and untouched; '
                         '-1 = auto (30%% of the image dimension), 0 = off')
    ap.add_argument('--split-factor', type=float, default=3.0,
                    help='clusters with a bbox larger than this x the '
                         'median sprite bbox are re-keyed at escalating '
                         'tolerance to split sprites that TOUCH in the '
                         'artwork (weak blended junctions); 0 = off')
    ap.add_argument('--min-area', type=int, default=0,
                    help='drop components smaller than this (px); '
                         '0 = auto (0.01%% of image area)')
    ap.add_argument('--pivot', choices=['centroid', 'bottom', 'center'],
                    default='centroid',
                    help='how sprites sit in their cells; centroid keeps the '
                         'object itself steady across frames (default), '
                         'bottom aligns feet for standing characters')
    ap.add_argument('--cell', default=None,
                    help='WxH force cell size (e.g. 256x256); default: auto '
                         '(max sprite size across all sheets)')
    ap.add_argument('--snap', type=int, default=1,
                    help='round auto cell size UP to a multiple (e.g. 32)')
    ap.add_argument('--padding', type=int, default=0,
                    help='uniform transparent padding around each cell (px)')
    ap.add_argument('--edge-trim', type=int, default=1,
                    help='erode each sprite edge by N px to remove backdrop '
                         'halo (white fringe on light backgrounds); 0 = off')
    args = ap.parse_args()

    # per-sheet groups; the token "auto" auto-names that sheet's rows
    sheet_actions = [('auto' if s.strip().lower() == 'auto' else s.split(','))
                     for s in args.actions.split(';')]
    if len(sheet_actions) != len(args.sheets):
        print(f'ERROR: --actions has {len(sheet_actions)} sheet group(s) but '
              f'{len(args.sheets)} sheet(s) given. Use ";" between sheets.')
        return 1

    # 1) keyout + freeform sprite detection per sheet
    all_rows, all_names, crops = [], [], []  # crops[si] = per-sprite list
    for si, path in enumerate(args.sheets):
        a = np.asarray(Image.open(path).convert('RGB'))
        key = (np.array([int(x) for x in args.key.split(',')])
               if args.key else detect_bg(a))
        rgba = keyout(a, key, args.tol)
        fg = rgba[..., 3] > 0
        strip = 1 if args.strip_lines < 0 else args.strip_lines
        fg = strip_grid_lines(fg, strip)
        fg = clean_line_crumbs(fg, run=max(40, round(max(a.shape[:2]) * 0.02)))
        merge = args.merge or max(4, round(min(a.shape[:2]) * 0.008))
        min_area = args.min_area or max(16, round(a.shape[0] * a.shape[1] * 1e-4))
        sprites = find_sprites(fg, merge, min_area,
                               stub_thick=max(8, round(min(a.shape[:2]) * 0.01)))
        dist = np.abs(a.astype(int) - key.astype(int)).sum(axis=2)
        sprites, n_split, n_bad = split_oversized(sprites, dist, args.tol,
                                                  merge, min_area,
                                                  args.split_factor)
        if n_split:
            print(f'{path}: split {n_split} fused cluster(s) '
                  '(tolerance escalation / neck-cut)')
        if n_bad:
            print(f'WARN: {path}: {n_bad} cluster(s) could NOT be split — '
                  'the sprites OVERLAP in the artwork itself (drawn on top '
                  'of each other); no pixel method can separate them. '
                  'Split them manually or regenerate with gaps.')
        sprites = reading_order(sprites)
        if not sprites:
            print(f'ERROR: {path}: no sprites detected '
                  f'(key={key.astype(int).tolist()} tol={args.tol}).')
            return 1

        n_visual_rows = max(s['_row'] for s in sprites) + 1
        group = sheet_actions[si]
        names = ['frames'] * n_visual_rows if group == 'auto' else group
        if n_visual_rows != len(names):
            print(f'ERROR: {path}: detected {n_visual_rows} visual row(s) but '
                  f'{len(names)} action name(s) given: {names}. '
                  'Use --actions auto to skip naming.')
            return 1

        # content-crop each sprite, erasing foreign pixels inside its box
        sheet_crops = []
        for s in sprites:
            x1, y1, x2, y2 = s['bbox']
            crop = rgba[y1:y2 + 1, x1:x2 + 1].copy()
            own = s['labels'][y1:y2 + 1, x1:x2 + 1]
            if args.edge_trim > 0:
                own = ndimage.binary_erosion(own, iterations=args.edge_trim)
            crop[..., 3] = np.where(own, crop[..., 3], 0).astype(np.uint8)
            sheet_crops.append({'img': crop, 'src': s['bbox'],
                                'row': s['_row']})
        crops.append(sheet_crops)

        # group sprite indices by visual row (same action name merges later)
        by_row = {}
        for i, c in enumerate(sheet_crops):
            by_row.setdefault(c['row'], []).append(i)
        for ri in sorted(by_row):
            all_rows.append((si, by_row[ri]))
            all_names.append(names[ri])
        print(f'{path}: key={key.astype(int).tolist()} tol={args.tol} '
              f'strip={strip} merge={merge} min_area={min_area} '
              f'sprites={len(sprites)} '
              f'rows={n_visual_rows} '
              f'per-row={[len(by_row[r]) for r in sorted(by_row)]}')

        # outlier warning: one cluster far bigger than the rest usually
        # means two neighbors fused -> lower --merge
        areas = sorted((s['bbox'][2] - s['bbox'][0] + 1) *
                       (s['bbox'][3] - s['bbox'][1] + 1) for s in sprites)
        med = areas[len(areas) // 2]
        for s in sprites:
            ar = ((s['bbox'][2] - s['bbox'][0] + 1) *
                  (s['bbox'][3] - s['bbox'][1] + 1))
            if ar > 4 * med:
                print(f'WARN: {path}: sprite at {s["bbox"]} is {ar / med:.1f}x '
                      'the median area — neighbors may have fused; '
                      'lower --merge and re-run.')

    # 2) uniform cell across EVERYTHING (Core Basics #1)
    flat = [c for sc in crops for c in sc]
    if args.cell:
        cw, ch = (int(v) for v in args.cell.lower().split('x'))
    else:
        cw = max(c['img'].shape[1] for c in flat)
        ch = max(c['img'].shape[0] for c in flat)
    cw = -(-cw // args.snap) * args.snap
    ch = -(-ch // args.snap) * args.snap
    too_big = [c for c in flat
               if c['img'].shape[1] > cw or c['img'].shape[0] > ch]
    if too_big:
        print(f'ERROR: {len(too_big)} sprite(s) exceed cell {cw}x{ch}; '
              'use a larger --cell.')
        return 1

    # 3) pack rows (same action name merges, in order) into ONE atlas
    pad = args.padding
    order, strips = [], {}
    for name, row_ref in zip(all_names, all_rows):
        if name not in strips:
            order.append(name)
            strips[name] = []
        strips[name].append(row_ref)
    counts = {n: sum(len(r[1]) for r in rs) for n, rs in strips.items()}
    cols = max(counts.values())
    nrows = len(order)
    W = cols * cw + (cols + 1) * pad
    H = nrows * ch + (nrows + 1) * pad
    atlas = np.zeros((H, W, 4), dtype=np.uint8)
    pivot_xy = {'centroid': (0.5, 0.5), 'bottom': (0.5, 1.0),
                'center': (0.5, 0.5)}[args.pivot]
    actions = {}
    for ri_out, name in enumerate(order):
        frames, ci = [], 0
        cy = pad + ri_out * (ch + pad)
        for si, idxs in strips[name]:
            for i in idxs:
                c = crops[si][i]
                img = c['img']
                fh, fw = img.shape[:2]
                cx = pad + ci * (cw + pad)
                ox, oy = paste_pivot(atlas, img, (cx, cy), (cw, ch), args.pivot)
                frames.append({
                    'x': cx, 'y': cy, 'w': cw, 'h': ch,
                    'sprite': {'x': ox, 'y': oy, 'w': fw, 'h': fh},
                    'source': {'sheet': args.sheets[si].split('/')[-1],
                               'x': c['src'][0], 'y': c['src'][1],
                               'w': c['src'][2] - c['src'][0] + 1,
                               'h': c['src'][3] - c['src'][1] + 1},
                })
                ci += 1
        actions[name] = {'row': ri_out, 'frames': frames}

    Image.fromarray(atlas, 'RGBA').save(args.out_image)
    meta = {
        'image': args.out_image.split('/')[-1],
        'layout': 'freeform',
        'size': {'w': W, 'h': H},
        'cell': {'w': cw, 'h': ch},
        'padding': pad,
        'pivot': {'x': pivot_xy[0], 'y': pivot_xy[1], 'mode': args.pivot,
                  'note': 'centroid = alpha-weighted center of mass; '
                          'bottom = feet on cell bottom'},
        'actions': actions,
    }
    with open(args.out_json, 'w') as f:
        json.dump(meta, f, indent=2)
    total = sum(len(v['frames']) for v in actions.values())
    print(f'atlas: {args.out_image}  {W}x{H}  cell={cw}x{ch} pad={pad} '
          f'rows={nrows} frames={total} pivot={args.pivot}')
    print(f'json : {args.out_json}  actions={list(actions)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
