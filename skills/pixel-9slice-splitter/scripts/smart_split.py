#!/usr/bin/env python3
"""Validate + split generated images: 9-slice UI panels, grid spritesheets,
scattered multi-object sheets.

Modes:
  nineslice - split a UI panel into 9 patches (corners/edges/center) with
              engine-ready insets; validates edge stretchability.
  grid      - split a spritesheet into cols x rows cells; auto-detects the
              grid from transparent gutters when --cols is omitted; validates
              per-cell content (empty cells, cut-through sprites).
  scatter   - split an irregular multi-object image via connected components.
  auto      - gutters present -> grid, otherwise -> scatter.

Every mode writes piece PNGs + manifest.json + an annotated preview of the
cut lines, and prints a validation report (exit 2 when warnings exist).

Usage:
  python3 smart_split.py panel.png --mode nineslice --out ./patches
  python3 smart_split.py sheet.png --mode grid --cols 8 --rows 2 --out ./frames
  python3 smart_split.py sheet.png --mode auto --out ./pieces --preview cuts.png
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

NINE_NAMES = ["tl", "t", "tr", "l", "c", "r", "bl", "b", "br"]
WARNINGS = []


def warn(msg):
    WARNINGS.append(msg)
    print(f"  WARNING: {msg}")


def alpha_of(im):
    return np.asarray(im.convert("RGBA"))[..., 3]


def detect_grid(alpha):
    """Infer (cols, rows) from fully-transparent gutters spanning the sheet."""
    cols_gap = np.where(alpha.sum(axis=0) == 0)[0]
    rows_gap = np.where(alpha.sum(axis=1) == 0)[0]

    def segments(gaps, total):
        cells, start = [], 0
        for g in gaps:
            if g > start:
                cells.append((start, g))
            start = g + 1
        if start < total:
            cells.append((start, total))
        return cells

    col_cells = segments(cols_gap, alpha.shape[1])
    row_cells = segments(rows_gap, alpha.shape[0])
    if len(col_cells) >= 2 or len(row_cells) >= 2:
        widths = [b - a for a, b in col_cells]
        heights = [b - a for a, b in row_cells]
        if (max(widths) - min(widths) <= 2) and (max(heights) - min(heights) <= 2):
            return col_cells, row_cells
    return None, None


def save_piece(im, box, out_dir, name, manifest, extra=None):
    crop = im.crop(box)
    crop.save(os.path.join(out_dir, f"{name}.png"))
    entry = {"name": name, "file": f"{name}.png",
             "bbox": [int(v) for v in box], "w": int(box[2] - box[0]), "h": int(box[3] - box[1])}
    if extra:
        entry.update(extra)
    manifest["pieces"].append(entry)


def draw_lines(im, v_lines, h_lines, path):
    out = im.copy()
    dr = ImageDraw.Draw(out)
    for x in v_lines:
        dr.line([(x, 0), (x, im.height)], fill=(255, 0, 80, 255), width=1)
    for y in h_lines:
        dr.line([(0, y), (im.width, y)], fill=(0, 200, 255, 255), width=1)
    out.save(path)


def mode_grid(im, out_dir, manifest, args):
    alpha = alpha_of(im)
    from_gutters = False
    if args.cols and args.rows:
        cw, ch = im.width // args.cols, im.height // args.rows
        col_cells = [(c * cw, (c + 1) * cw) for c in range(args.cols)]
        row_cells = [(r * ch, (r + 1) * ch) for r in range(args.rows)]
        if im.width % args.cols or im.height % args.rows:
            warn(f"image {im.width}x{im.height} not divisible by {args.cols}x{args.rows}; "
                 f"cell size rounded to {cw}x{ch}")
    else:
        col_cells, row_cells = detect_grid(alpha)
        if not col_cells:
            print("  no transparent gutters and no --cols/--rows given; use --mode scatter")
            return False
        from_gutters = True
        print(f"  auto-detected grid: {len(col_cells)}x{len(row_cells)} "
              f"(cell ~{col_cells[0][1]-col_cells[0][0]}x{row_cells[0][1]-row_cells[0][0]})")

    coverages, v_lines, h_lines = [], [], []
    for ri, (y0, y1) in enumerate(row_cells):
        h_lines.append(y0)
        for ci, (x0, x1) in enumerate(col_cells):
            if ri == 0:
                v_lines.append(x0)
            cell_a = alpha[y0:y1, x0:x1]
            cov = float((cell_a > 0).mean())
            coverages.append(cov)
            name = f"cell_{ri:02d}_{ci:02d}"
            save_piece(im, (x0, y0, x1, y1), out_dir, name, manifest,
                       {"row": ri, "col": ci, "coverage": round(cov, 3)})
            if cov < 0.005:
                warn(f"cell r{ri} c{ci} is EMPTY — wrong grid or staggered sheet?")
            # cut-through check: only meaningful for explicit grids on gutterless
            # sheets (full-bleed cells between gutters are normal, e.g. tiles)
            edges = [cell_a[0, :], cell_a[-1, :], cell_a[:, 0], cell_a[:, -1]]
            if not from_gutters and cov > 0.02 and all((e > 0).mean() > 0.5 for e in edges):
                warn(f"cell r{ri} c{ci} content touches all 4 edges — for a SPRITE sheet "
                     f"the grid cuts through sprites (tile sheets are fine; check preview)")

    manifest["mode"] = "grid"
    manifest["cols"], manifest["rows"] = len(col_cells), len(row_cells)
    print(f"  coverage min/mean/max: {min(coverages):.2f}/"
          f"{np.mean(coverages):.2f}/{max(coverages):.2f}")
    if args.preview:
        draw_lines(im, v_lines + [im.width], h_lines + [im.height], args.preview)
    return True


def mode_nineslice(im, out_dir, manifest, args):
    W, H = im.size
    if args.insets:
        L, T, R, B = args.insets
    else:  # default: third of each dimension
        L, R, T, B = W // 3, W // 3, H // 3, H // 3
        print(f"  no --insets given; using thirds L{L} T{T} R{R} B{B}")
    if L + R >= W or T + B >= H:
        print("  insets consume the whole image", file=sys.stderr)
        return False

    xs = [0, L, W - R, W]
    ys = [0, T, H - B, H]
    alpha = alpha_of(im)
    i = 0
    for r in range(3):
        for c in range(3):
            box = (xs[c], ys[r], xs[c + 1], ys[r + 1])
            name = NINE_NAMES[i]; i += 1
            save_piece(im, box, out_dir, name, manifest)
            piece_a = alpha[box[1]:box[3], box[0]:box[2]]
            if (piece_a > 0).mean() < 0.01:
                warn(f"patch {name} is empty")
            # stretchability: edge patches should be low-detail along stretch axis
            if name in ("t", "b"):
                noise = np.abs(np.diff(piece_a.astype(float), axis=1)).mean()
                axis = "horizontal"
            elif name in ("l", "r"):
                noise = np.abs(np.diff(piece_a.astype(float), axis=0)).mean()
                axis = "vertical"
            else:
                continue
            if noise > 28:
                warn(f"edge patch {name} has high {axis} detail ({noise:.0f}) — "
                     f"stretching will smear; prefer tile-repeat in the engine")

    manifest["mode"] = "nineslice"
    manifest["insets"] = {"left": L, "top": T, "right": R, "bottom": B}
    manifest["engine_hints"] = {
        "unity_sprite_border": [L, B, R, T],
        "godot_ninepatch_patch_margin": {"left": L, "top": T, "right": R, "bottom": B},
        "flame_nine_tile_box": {"left": L, "top": T, "right": R, "bottom": B},
        "note": "use piece 'c' (center) tiled or stretched; edges t/b stretch horizontally, l/r vertically"}
    if args.preview:
        draw_lines(im, [L, W - R], [T, H - B], args.preview)
    return True


def mode_scatter(im, out_dir, manifest, args):
    alpha = alpha_of(im)
    mask = alpha > 0
    if args.dilate:
        mask = ndimage.binary_dilation(mask, iterations=args.dilate)
    labels, n = ndimage.label(mask)
    boxes = []
    for i in range(1, n + 1):
        ys, xs = np.where(labels == i)
        area = int((alpha[labels == i] > 0).sum())
        if area < args.min_area:
            continue
        boxes.append((max(0, xs.min() - args.pad), max(0, ys.min() - args.pad),
                      min(im.width, xs.max() + 1 + args.pad), min(im.height, ys.max() + 1 + args.pad)))
    boxes.sort(key=lambda b: (b[1] // 32, b[0]))  # reading order
    if not boxes:
        print("  no objects found", file=sys.stderr)
        return False
    sizes = []
    for i, b in enumerate(boxes):
        save_piece(im, b, out_dir, f"piece_{i:02d}", manifest)
        sizes.append((b[2] - b[0], b[3] - b[1]))
    ws = [s[0] for s in sizes]; hs = [s[1] for s in sizes]
    manifest["mode"] = "scatter"
    print(f"  {len(boxes)} objects; size spread w {min(ws)}-{max(ws)}, h {min(hs)}-{max(hs)}")
    if len(boxes) >= 4 and (max(ws) - min(ws) <= 4) and (max(hs) - min(hs) <= 4):
        print("  sizes are uniform — this looks like a grid sheet; consider --mode grid")
    if args.preview:
        out = im.copy()
        dr = ImageDraw.Draw(out)
        for b in boxes:
            dr.rectangle(b, outline=(255, 0, 80, 255), width=1)
        out.save(args.preview)
    return True


def main():
    p = argparse.ArgumentParser(description="Validate + split generated images.")
    p.add_argument("input")
    p.add_argument("--mode", choices=["auto", "grid", "nineslice", "scatter"], default="auto")
    p.add_argument("--out", required=True)
    p.add_argument("--cols", type=int, default=0)
    p.add_argument("--rows", type=int, default=0)
    p.add_argument("--insets", type=int, nargs=4, metavar=("L", "T", "R", "B"),
                   help="9-slice border insets in px (default: thirds)")
    p.add_argument("--dilate", type=int, default=2, help="scatter: merge near parts")
    p.add_argument("--min-area", type=int, default=32)
    p.add_argument("--pad", type=int, default=2)
    p.add_argument("--preview", default=None, help="annotated cut-line preview PNG")
    args = p.parse_args()

    im = Image.open(args.input).convert("RGBA")
    os.makedirs(args.out, exist_ok=True)
    manifest = {"image": os.path.basename(args.input), "w": im.width, "h": im.height,
                "pieces": []}

    mode = args.mode
    if mode == "auto":
        cols, _ = detect_grid(alpha_of(im))
        mode = "grid" if cols else "scatter"
        print(f"auto mode -> {mode}")

    ok = {"grid": mode_grid, "nineslice": mode_nineslice,
          "scatter": mode_scatter}[mode](im, args.out, manifest, args)
    if not ok:
        return 1

    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"split into {len(manifest['pieces'])} pieces -> {args.out}/ "
          f"({len(WARNINGS)} warnings)")
    return 2 if WARNINGS else 0


if __name__ == "__main__":
    sys.exit(main())
