#!/usr/bin/env python3
"""Score AI-generated spritesheet(s) 0-100 and emit a measurement-driven
retry hint — the closed loop from references/lessons-learned.md:

  generate -> score -> inject retry hint -> regenerate (up to 3x)
  -> keep the BEST candidate (never an empty hand)

Score formula (ScoreFrames-style, largest penalty first):
  start at 100
  - (35 + 10*|Found-Expected|)   frame-count accuracy, when --frames given
  - 13*errors - 3*warnings       extraction-contract violations
  - 12        any row effectively static (motion < 0.01, 2+ frames)
  - 10        identity collapse (dHash similarity < 0.55)
Grades: excellent >= 85 / good >= 70 / fair >= 50 / poor < 50.

Identity uses two orthogonal axes (per row, consecutive frames, then the
worst row): 64-bin RGB histogram intersection (color drift) and dHash
9x8 perceptual hash (structure/silhouette drift, color-invariant).

Usage:
    python3 sheet_score.py sheet.png --rows 4 --frames 4
    python3 sheet_score.py try1.png try2.png try3.png --rows 4 --frames 4 \
        --json   # scores all, prints the best candidate last

Exit code 0; read the printed score, penalties and `retry hint:` line —
paste the hint verbatim into the next generation prompt.
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image
from scipy import ndimage


def sample_background(a: np.ndarray) -> tuple[np.ndarray, int]:
    corners = np.concatenate([
        a[:20, :20].reshape(-1, 3), a[:20, -20:].reshape(-1, 3),
        a[-20:, :20].reshape(-1, 3), a[-20:, -20:].reshape(-1, 3),
    ])
    bg = np.median(corners, axis=0)
    return bg, int(np.abs(corners - bg).max())


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
                bridge: int = 5) -> list[list[tuple[int, int, int, int]]]:
    """Rows of frame boxes (x1,y1,x2,y2), sorted by x. Same detection as
    chroma_key_pack.py so the score predicts what the packer will see."""
    det = ndimage.binary_closing(fg, iterations=bridge)
    lab, _ = ndimage.label(det)
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
        rows.append(sorted([b for b in boxes if b[1] >= r1 - 4 and b[3] <= r2 + 4],
                           key=lambda b: b[0]))
    return rows


def hist64(crop: np.ndarray) -> np.ndarray:
    """64-bin RGB histogram (4 bins/channel), normalized."""
    q = crop.astype(int) >> 6
    idx = q[..., 0] * 16 + q[..., 1] * 4 + q[..., 2]
    h = np.bincount(idx.ravel(), minlength=64).astype(float)
    return h / max(h.sum(), 1.0)


def dhash(crop: np.ndarray) -> np.ndarray:
    """9x8 grayscale dHash — structure-sensitive, color-invariant."""
    g = np.asarray(Image.fromarray(crop).convert('L').resize((9, 8), Image.BILINEAR))
    return (g[:, :-1] > g[:, 1:]).ravel()


def dhash_sim(b1: np.ndarray, b2: np.ndarray) -> float:
    return 1.0 - float(np.count_nonzero(b1 != b2)) / b1.size


def motion_between(c1: np.ndarray, c2: np.ndarray) -> float:
    """Mean abs RGB diff after bottom-center alignment on a shared canvas."""
    H = max(c1.shape[0], c2.shape[0])
    W = max(c1.shape[1], c2.shape[1])
    def place(c):
        canvas = np.zeros((H, W, 3))
        h, w = c.shape[:2]
        canvas[H - h:, (W - w) // 2:(W - w) // 2 + w] = c / 255.0
        return canvas
    return float(np.abs(place(c1) - place(c2)).mean())


def score_sheet(path: str, args) -> dict:
    source = np.asarray(Image.open(path).convert('RGBA'))
    a = source[..., :3]
    alpha = source[..., 3]
    has_alpha = np.any(alpha < 255)
    H, W = a.shape[:2]
    if has_alpha:
        # True alpha is the source of truth. Transparent RGB padding is often
        # black, so sampling it as a matte would mis-score black artwork.
        bg, spread = np.array([0, 0, 0]), 0
        fg = alpha > 0
    else:
        bg, spread = sample_background(a)
        fg = np.abs(a.astype(int) - bg.astype(int)).sum(axis=2) > args.tol
    coverage = float(fg.mean())
    rows = detect_rows(fg)

    errors, warnings, penalties, hints = [], [], [], []

    # --- extraction-contract violations -> errors / warnings -------------
    if spread > 30 and not has_alpha:
        errors.append(f'bg corner-spread {spread} > 30 (not a flat color)')
        hints.append('render a perfectly flat solid chroma green #00FF00 '
                     'background, one uniform color, no gradient, no lighting, '
                     'no drop shadow')
    if coverage > 0.90:
        errors.append(f'foreground coverage {coverage:.0%} > 90% (bg clause ignored)')
        hints.append('leave most of the canvas as empty background; do not fill '
                     'the whole image with art')
    elif coverage < 0.05:
        warnings.append(f'foreground coverage {coverage:.0%} < 5% (tiny sprites, '
                        'wasted resolution)')
    if args.rows and len(rows) != args.rows:
        errors.append(f'row bands {len(rows)} != expected {args.rows} '
                      '(rows merged or split)')
        hints.append(f'split the canvas into exactly {args.rows} horizontal rows '
                     'separated by wide empty background gaps')

    boxes = [b for r in rows for b in r]
    if boxes:
        edge = [b for b in boxes if b[0] <= 1 or b[1] <= 1 or b[2] >= W - 2 or b[3] >= H - 2]
        if edge:
            errors.append(f'{len(edge)} frame(s) touch the sheet edge (clipped)')
            hints.append('keep a generous empty background margin around the whole '
                         'grid so no sprite touches the image edge')
        hs = np.array([b[3] - b[1] for b in boxes])
        med_h = int(np.median(hs))
        if hs.max() > max(1, hs.min()) * 2.5:
            warnings.append(f'frame height variance {hs.max() / max(1, hs.min()):.1f}x '
                            '> 2.5x (merged frames, split limbs, or text labels)')
            hints.append('every frame exactly the same character height on a strict '
                         'invisible grid; no text, no numbers, no labels anywhere')
        for ri, r in enumerate(rows):
            if len(r) > 1:
                drift = max(b[3] for b in r) - min(b[3] for b in r)
                if drift > max(8, med_h * 0.1):
                    warnings.append(f'row {ri} pivot drift {drift}px (feet misaligned)')
                    hints.append('plant the feet at the exact same bottom line in '
                                 'every frame, no vertical offset')

    # --- frame-count accuracy: the largest penalty -----------------------
    found_total = sum(len(r) for r in rows)
    if args.frames:
        diff = sum(abs(len(r) - args.frames) for r in rows)
        if args.rows and len(rows) != args.rows:
            diff += abs(len(rows) - args.rows) * args.frames
        if diff:
            penalties.append((35 + 10 * diff,
                              f'frame count off by {diff} '
                              f'(found {found_total}, expected '
                              f'{args.frames}/row)'))
            hints.append(f'the previous result read as {found_total} poses but '
                         f'exactly {args.frames} per row are required; split each '
                         f'row into {args.frames} even columns separated by clear '
                         'empty gaps, each column holding one complete pose')

    # --- identity (2 axes) + motion, per row -----------------------------
    ident_hist, ident_dhash, motions, static_rows = 1.0, 1.0, [], []
    for ri, r in enumerate(rows):
        if len(r) < 2:
            continue
        crops = [a[b[1]:b[3] + 1, b[0]:b[2] + 1] for b in r]
        hsims, dsims, ms = [], [], []
        for i in range(len(crops) - 1):
            hsims.append(float(np.minimum(hist64(crops[i]), hist64(crops[i + 1])).sum()))
            dsims.append(dhash_sim(dhash(crops[i]), dhash(crops[i + 1])))
            ms.append(motion_between(crops[i], crops[i + 1]))
        ident_hist = min(ident_hist, float(np.mean(hsims)))
        ident_dhash = min(ident_dhash, float(np.mean(dsims)))
        row_motion = float(np.mean(ms))
        motions.append(row_motion)
        if row_motion < 0.01:
            static_rows.append(ri)
    if static_rows:
        penalties.append((12, f'row(s) {static_rows} effectively static '
                              '(motion < 0.01 — frames are near-identical)'))
        hints.append('make every frame a visibly different phase of the motion; '
                     'no repeated or near-identical poses')
    if ident_dhash < 0.55:
        penalties.append((10, f'identity collapse: dHash similarity '
                              f'{ident_dhash:.2f} < 0.55 (silhouette changes '
                              'between frames)'))
        hints.append('keep the identical character — same outfit, same colors, '
                     'same proportions, same silhouette — in every frame')
    elif ident_hist < 0.5:
        warnings.append(f'color identity drift: histogram similarity '
                        f'{ident_hist:.2f} < 0.50')
        hints.append('keep the exact same color palette on the character in '
                     'every frame')

    # --- fold into 0-100 --------------------------------------------------
    err_pen = 13 * len(errors) + 3 * len(warnings)
    score = 100 - err_pen - sum(p for p, _ in penalties)
    score = max(0, min(100, score))
    grade = ('excellent' if score >= 85 else 'good' if score >= 70 else
             'fair' if score >= 50 else 'poor')
    return {
        'sheet': path, 'size': [W, H], 'score': score, 'grade': grade,
        'penalties': [{'points': p, 'reason': r} for p, r in penalties],
        'errors': errors, 'warnings': warnings,
        'metrics': {
            'bg_rgb': bg.astype(int).tolist(), 'bg_spread': spread,
            'has_alpha': bool(has_alpha),
            'fg_coverage': round(coverage, 4),
            'rows_found': len(rows), 'frames_per_row': [len(r) for r in rows],
            'identity_hist': round(ident_hist, 3),
            'identity_dhash': round(ident_dhash, 3),
            'motion_per_row': [round(m, 4) for m in motions],
        },
        'retry_hint': 'REGENERATE with these corrections: ' + '; '.join(dict.fromkeys(hints))
                      if hints else '',
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('sheets', nargs='+')
    ap.add_argument('--rows', type=int, default=None, help='expected row count')
    ap.add_argument('--frames', type=int, default=None,
                    help='expected frames per row (enables the count penalty)')
    ap.add_argument('--tol', type=int, default=45)
    ap.add_argument('--json', action='store_true', help='machine-readable output')
    args = ap.parse_args()

    results = [score_sheet(p, args) for p in args.sheets]
    best = max(results, key=lambda r: r['score'])

    if args.json:
        print(json.dumps({'results': results, 'best': best['sheet']}, indent=2))
        return 0
    for r in results:
        print(f"sheet: {r['sheet']}  {r['size'][0]}x{r['size'][1]}")
        print(f"score: {r['score']}/100 ({r['grade']})")
        for p in r['penalties']:
            print(f"  -{p['points']:>2}  {p['reason']}")
        if r['errors'] or r['warnings']:
            print(f"  -{13 * len(r['errors']) + 3 * len(r['warnings']):>2}  "
                  f"{len(r['errors'])} error(s), {len(r['warnings'])} warning(s):")
            for e in r['errors']:
                print(f'       ERROR: {e}')
            for w in r['warnings']:
                print(f'       warn : {w}')
        m = r['metrics']
        print(f"metrics: rows={m['rows_found']} frames/row={m['frames_per_row']} "
              f"bg_spread={m['bg_spread']} fg={m['fg_coverage']:.1%} "
              f"identity(hist={m['identity_hist']}, dhash={m['identity_dhash']}) "
              f"motion={m['motion_per_row']}")
        if r['retry_hint']:
            print(f"retry hint: {r['retry_hint']}")
        print()
    if len(results) > 1:
        print(f"best candidate: {best['sheet']} "
              f"(score {best['score']}/100, {best['grade']}) — pack this one")
    return 0


if __name__ == '__main__':
    sys.exit(main())
