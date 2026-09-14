#!/usr/bin/env python3
"""
iso_designer.py - Isometric map designer intelligence & projection math.

Provides:
  - 2:1 diamond grid validation (standard 30° dimetric projection)
  - Viewport-to-grid sizing: computes optimal (columns, rows) for 16:9, 4:3, or custom resolutions
  - Tall tile extrusion analysis: distinguishes diamond footprint from vertical height (e.g. walls/trees)
  - Coordinate transformations: cell (c, r) <-> screen pixel (px, py)
  - Depth sorting: back-to-front (col + row) traversal sequences
"""

import sys
import math
import json
import argparse
from typing import Tuple, List, Dict, Any, Optional


def is_valid_diamond_ratio(tile_w: int, tile_h: int) -> bool:
    """Checks if tile dimensions follow the standard 2:1 isometric diamond ratio."""
    return tile_w > 0 and tile_h > 0 and (tile_w == 2 * tile_h)


def suggest_diamond_dims(sprite_w: int, sprite_h: int) -> Tuple[int, int, int]:
    """
    Intelligently infers the base diamond size and vertical extrusion from a sprite/tile dimension.
    Returns: (diamond_w, diamond_h, vertical_extrusion)
    """
    diamond_w = sprite_w
    # Default standard 2:1 diamond: height is half of width
    expected_diamond_h = sprite_w // 2
    if sprite_h >= expected_diamond_h:
        diamond_h = expected_diamond_h
        extrusion = sprite_h - expected_diamond_h
    else:
        diamond_h = sprite_h
        extrusion = 0
    return diamond_w, diamond_h, extrusion


def calculate_iso_pixel_bounds(cols: int, rows: int, tile_w: int, tile_h: int) -> Tuple[int, int]:
    """
    Whole-map screen pixel bounds for an isometric map, matching bixel-core's tilemap.rs:
      pixel_w = (cols + rows + 1) * tile_w // 2
      pixel_h = (cols + rows) * tile_h // 2
    """
    if cols <= 0 or rows <= 0 or tile_w <= 0 or tile_h <= 0:
        return 0, 0
    pw = (cols + rows + 1) * tile_w // 2
    ph = (cols + rows) * tile_h // 2
    return pw, ph


def fit_iso_grid_to_viewport(target_w: int, target_h: int, tile_w: int = 64, tile_h: int = 32,
                             aspect_ratio: Optional[str] = None) -> Dict[str, Any]:
    """
    Intelligently calculates the ideal (columns, rows) for an isometric scene to fill
    or comfortably fit inside a given viewport (e.g., 1280x720, 1920x1080, or 800x600).
    """
    if not is_valid_diamond_ratio(tile_w, tile_h):
        # Auto-correct or warn if not 2:1
        if tile_w > 0:
            tile_h = max(1, tile_w // 2)

    # Determine desired aspect ratio: target_w / target_h
    target_aspect = target_w / max(1, target_h)

    # In isometric, pixel_w = (c + r + 1)*tw/2, pixel_h = (c + r)*th/2.
    # The sum (c + r) determines both width and height when tile_w = 2*tile_h!
    # Max sum constrained by width:
    sum_from_w = int((2.0 * target_w / tile_w) - 1.0)
    # Max sum constrained by height:
    sum_from_h = int(2.0 * target_h / tile_h)

    # Choose the sum that fits comfortably within the viewport (with a modest margin)
    total_dim = max(4, min(sum_from_w, sum_from_h))

    # By default, a square diamond map has cols == rows = total_dim // 2
    base_cols = max(2, total_dim // 2)
    base_rows = base_cols

    # If the user requested a distinctly wide ratio (like 16:9), an asymmetric map can be considered,
    # though isometric maps are diamonds rotated 45 deg.
    pw, ph = calculate_iso_pixel_bounds(base_cols, base_rows, tile_w, tile_h)

    return {
        "columns": base_cols,
        "rows": base_rows,
        "tile_width": tile_w,
        "tile_height": tile_h,
        "pixel_width": pw,
        "pixel_height": ph,
        "fits_in_target": (pw <= target_w and ph <= target_h),
        "target_width": target_w,
        "target_height": target_h,
        "margin_x": max(0, target_w - pw),
        "margin_y": max(0, target_h - ph),
    }


def cell_to_iso_pixel(col: int, row: int, cols: int, rows: int, tile_w: int, tile_h: int) -> Tuple[int, int]:
    """
    Converts cell (col, row) to top-left screen pixel position (matching bixel-core).
    """
    origin_x = rows * tile_w // 2
    px = (col - row) * tile_w // 2 + origin_x
    py = (col + row) * tile_h // 2
    return px, py


def iso_pixel_to_cell(px: float, py: float, cols: int, rows: int, tile_w: int, tile_h: int) -> Tuple[int, int]:
    """
    Converts screen pixel (px, py) to integer isometric cell (col, row).
    """
    origin_x = float(rows * tile_w // 2)
    x = (px - origin_x) / (tile_w / 2.0)
    y = py / (tile_h / 2.0)
    col = int(math.floor((x + y - 1.0) / 2.0))
    row = int(math.floor((y - x + 1.0) / 2.0))
    return col, row


def get_depth_sorted_cells(cols: int, rows: int) -> List[Tuple[int, int]]:
    """
    Returns all (col, row) coordinates sorted by painter's depth:
    back-to-front (col + row ascending, North to South).
    """
    cells = [(c, r) for r in range(rows) for c in range(cols)]
    cells.sort(key=lambda item: (item[0] + item[1], item[0]))
    return cells


def analyze_tileset_geometry(image_w: int, image_h: int, tile_w: int, tile_h: int) -> Dict[str, Any]:
    """
    Analyzes tileset dimensions and detects if it has tall vertical extrusions (isometric blocks/walls).
    """
    cols = max(1, image_w // tile_w)
    rows = max(1, image_h // tile_h)
    tile_count = cols * rows
    diamond_w, diamond_h, extrusion = suggest_diamond_dims(tile_w, tile_h)

    is_iso = is_valid_diamond_ratio(diamond_w, diamond_h)

    return {
        "columns": cols,
        "rows": rows,
        "tile_count": tile_count,
        "tile_width": tile_w,
        "tile_height": tile_h,
        "diamond_width": diamond_w,
        "diamond_height": diamond_h,
        "vertical_extrusion": extrusion,
        "is_isometric_candidate": is_iso,
        "recommended_tileoffset": [0, -extrusion] if extrusion > 0 else [0, 0]
    }


def run_tests():
    """Unit tests for iso_designer intelligence."""
    print("Running iso_designer self-tests...")

    # Test 1: Diamond ratio checks
    assert is_valid_diamond_ratio(64, 32) is True
    assert is_valid_diamond_ratio(32, 16) is True
    assert is_valid_diamond_ratio(64, 64) is False

    # Test 2: Suggest diamond dims for tall tile (64x64 wall)
    dw, dh, ext = suggest_diamond_dims(64, 64)
    assert dw == 64 and dh == 32 and ext == 32

    # Test 3: Whole map pixel bounds (4x4 of 32x16)
    # (4 + 4 + 1) * 32 // 2 = 9 * 16 = 144
    # (4 + 4) * 16 // 2 = 8 * 8 = 64
    pw, ph = calculate_iso_pixel_bounds(4, 4, 32, 16)
    assert pw == 144 and ph == 64, f"Expected 144x64, got {pw}x{ph}"

    # Test 4: Viewport fitting (1280x720 with 64x32)
    fit = fit_iso_grid_to_viewport(1280, 720, 64, 32)
    assert fit["columns"] > 0 and fit["rows"] > 0
    assert fit["fits_in_target"] is True
    assert fit["pixel_width"] <= 1280 and fit["pixel_height"] <= 720

    # Test 5: Coordinate round-trip (col 2, row 1)
    px, py = cell_to_iso_pixel(2, 1, 10, 10, 64, 32)
    # Center pixel of that cell should map back to col 2, row 1
    c_back, r_back = iso_pixel_to_cell(px + 32, py + 16, 10, 10, 64, 32)
    assert c_back == 2 and r_back == 1, f"Expected (2, 1), got ({c_back}, {r_back})"

    # Test 6: Depth sorting sequence
    sorted_cells = get_depth_sorted_cells(2, 2)
    # (0, 0) sum 0, then (0, 1) and (1, 0) sum 1, then (1, 1) sum 2
    assert sorted_cells[0] == (0, 0)
    assert sorted_cells[-1] == (1, 1)

    print("All iso_designer tests passed successfully! ✓")


def main():
    parser = argparse.ArgumentParser(description="Isometric map designer intelligence & projection math.")
    parser.add_argument("--test", action="store_true", help="Run internal unit tests")
    parser.add_argument("--viewport", type=str, help="Desired viewport dimension (e.g. 1280x720, 1920x1080)")
    parser.add_argument("--tile-size", type=str, default="64x32", help="Diamond tile size (e.g. 64x32, 32x16)")
    parser.add_argument("--analyze-image", nargs=2, type=int, metavar=("W", "H"), help="Image dimensions W H")
    parser.add_argument("--tile-dim", nargs=2, type=int, metavar=("TW", "TH"), default=[64, 32], help="Tile dimensions TW TH")
    args = parser.parse_args()

    if args.test:
        run_tests()
        sys.exit(0)

    if args.viewport:
        try:
            vw, vh = map(int, args.viewport.lower().split("x"))
            tw, th = map(int, args.tile_size.lower().split("x"))
            res = fit_iso_grid_to_viewport(vw, vh, tw, th)
            print(json.dumps(res, indent=2))
            return
        except Exception as e:
            print(json.dumps({"error": str(e)}))
            sys.exit(1)

    if args.analyze_image:
        img_w, img_h = args.analyze_image
        tw, th = args.tile_dim
        res = analyze_tileset_geometry(img_w, img_h, tw, th)
        print(json.dumps(res, indent=2))
        return

    parser.print_help()


if __name__ == "__main__":
    main()
