#!/usr/bin/env python3
"""
update_map.py - Modify existing Tiled maps (.map / .json) or generate live editor update ops.

Supports:
  - Adding layers to existing scenes
  - Stamping new patterns/structures into specified layers
  - Replacing tiles across a layer or bounded rectangle
  - Erasing/clearing regions
  - Resizing map dimensions with anchor support
"""

import sys
import os
import json
import argparse
from typing import Dict, Any, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from tile_math import transform_pattern, encode_gid, decode_gid


def find_layer_index(map_data: Dict[str, Any], layer_target: Any) -> Optional[int]:
    """Resolves layer_target (int index or str name) to an index in map_data['layers']."""
    layers = map_data.get("layers", [])
    if isinstance(layer_target, int):
        return layer_target if 0 <= layer_target < len(layers) else None
    name_clean = str(layer_target).strip().lower()
    for idx, l in enumerate(layers):
        if l.get("name", "").strip().lower() == name_clean:
            return idx
    return None


def add_layer_if_missing(map_data: Dict[str, Any], layer_name: str, layer_type: str = "tilelayer") -> Tuple[int, bool]:
    """Adds a new layer if it doesn't already exist. Returns (layer_index, was_created)."""
    idx = find_layer_index(map_data, layer_name)
    if idx is not None:
        return idx, False

    w = map_data.get("width", 20)
    h = map_data.get("height", 15)
    layers = map_data.setdefault("layers", [])
    new_id = map_data.get("nextlayerid", len(layers) + 1)
    map_data["nextlayerid"] = new_id + 1

    new_layer = {
        "id": new_id,
        "name": layer_name,
        "type": layer_type,
        "visible": True,
        "opacity": 1.0,
        "width": w,
        "height": h,
        "x": 0,
        "y": 0,
        "data": [0] * (w * h)
    }
    layers.append(new_layer)
    return len(layers) - 1, True


def stamp_into_map(
    map_data: Dict[str, Any],
    layer_target: Any,
    start_x: int,
    start_y: int,
    tiles_2d: List[List[int]],
    skip_empty: bool = True
) -> int:
    """Stamps a 2D tile matrix into the specified layer of map_data."""
    l_idx = find_layer_index(map_data, layer_target)
    if l_idx is None:
        # Create layer if missing
        l_idx, _ = add_layer_if_missing(map_data, str(layer_target))

    layer = map_data["layers"][l_idx]
    w = layer.get("width", map_data.get("width", 0))
    h = layer.get("height", map_data.get("height", 0))
    data = layer.setdefault("data", [0] * (w * h))

    changed = 0
    p_h = len(tiles_2d)
    p_w = len(tiles_2d[0]) if p_h > 0 else 0

    for py in range(p_h):
        ty = start_y + py
        if ty < 0 or ty >= h:
            continue
        for px in range(p_w):
            tx = start_x + px
            if tx < 0 or tx >= w:
                continue
            gid = tiles_2d[py][px]
            if skip_empty and gid == 0:
                continue
            cell_idx = ty * w + tx
            if cell_idx < len(data):
                data[cell_idx] = gid
                changed += 1

    return changed


def replace_tiles_in_layer(
    map_data: Dict[str, Any],
    layer_target: Any,
    old_gid: int,
    new_gid: int,
    box: Optional[Tuple[int, int, int, int]] = None
) -> int:
    """Replaces old_gid with new_gid across a layer or bounded box (x0, y0, x1, y1)."""
    l_idx = find_layer_index(map_data, layer_target)
    if l_idx is None:
        return 0

    layer = map_data["layers"][l_idx]
    w = layer.get("width", map_data.get("width", 0))
    h = layer.get("height", map_data.get("height", 0))
    data = layer.get("data", [])

    changed = 0
    min_x, min_y, max_x, max_y = box if box else (0, 0, w - 1, h - 1)

    for y in range(max(0, min_y), min(h, max_y + 1)):
        for x in range(max(0, min_x), min(w, max_x + 1)):
            idx = y * w + x
            if idx < len(data) and data[idx] == old_gid:
                data[idx] = new_gid
                changed += 1

    return changed


def clear_region(map_data: Dict[str, Any], layer_target: Any, x: int, y: int, width: int, height: int) -> int:
    """Clears a rectangle of tiles to 0."""
    empty_matrix = [[0] * width for _ in range(height)]
    return stamp_into_map(map_data, layer_target, x, y, empty_matrix, skip_empty=False)


def apply_update_instructions(map_data: Dict[str, Any], instructions: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Applies a series of update actions to map_data and returns equivalent editor_command ops.
    Actions can be:
      - {"action": "add_layer", "name": "..."}
      - {"action": "stamp", "layer": "...", "x": 0, "y": 0, "tiles": [...], "skip_empty": True}
      - {"action": "replace", "layer": "...", "old_gid": 1, "new_gid": 2}
      - {"action": "clear", "layer": "...", "x": 0, "y": 0, "width": 4, "height": 4}
    """
    editor_ops = []

    for item in instructions:
        action = item.get("action", "").lower()

        if action == "add_layer":
            layer_name = item.get("name", "New Layer")
            _, created = add_layer_if_missing(map_data, layer_name)
            if created:
                editor_ops.append({
                    "op": "map_add_layer",
                    "name": layer_name,
                    "layer_type": "tile"
                })

        elif action == "stamp":
            layer = item.get("layer", 0)
            x = item.get("x", 0)
            y = item.get("y", 0)
            tiles = item.get("tiles", [[]])
            direction = item.get("direction", "normal")
            skip_empty = item.get("skip_empty", True)

            if direction != "normal":
                tiles = transform_pattern(tiles, direction)

            stamp_into_map(map_data, layer, x, y, tiles, skip_empty=skip_empty)

            l_idx = find_layer_index(map_data, layer) or 0
            editor_ops.append({
                "op": "map_stamp",
                "layer": l_idx,
                "x": x,
                "y": y,
                "tiles": tiles,
                "skip_empty": skip_empty
            })

        elif action == "replace":
            layer = item.get("layer", 0)
            old_g = item.get("old_gid", 0)
            new_g = item.get("new_gid", 0)
            box = item.get("box")
            replace_tiles_in_layer(map_data, layer, old_g, new_g, box=box)

            l_idx = find_layer_index(map_data, layer) or 0
            editor_ops.append({
                "op": "map_replace",
                "layer": l_idx,
                "old_tile": old_g,
                "new_tile": new_g
            })

        elif action == "clear":
            layer = item.get("layer", 0)
            x = item.get("x", 0)
            y = item.get("y", 0)
            w = item.get("width", 1)
            h = item.get("height", 1)
            clear_region(map_data, layer, x, y, w, h)

            l_idx = find_layer_index(map_data, layer) or 0
            empty_mat = [[0] * w for _ in range(h)]
            editor_ops.append({
                "op": "map_stamp",
                "layer": l_idx,
                "x": x,
                "y": y,
                "tiles": empty_mat,
                "skip_empty": False
            })

    return editor_ops


def main():
    parser = argparse.ArgumentParser(description="Update existing Tiled map (.map / .json) or generate live editor update ops.")
    parser.add_argument("map_file", help="Path to existing Tiled map JSON file")
    parser.add_argument("--instructions", type=str, required=True, help="Path to JSON file with update actions")
    parser.add_argument("--out-map", type=str, help="Save modified map to new or existing file")
    parser.add_argument("--out-ops", type=str, help="Save generated editor_command ops JSON")
    args = parser.parse_args()

    if not os.path.exists(args.map_file):
        print(f"Map file not found: {args.map_file}")
        sys.exit(1)

    with open(args.map_file, "r", encoding="utf-8") as f:
        map_data = json.load(f)

    with open(args.instructions, "r", encoding="utf-8") as f:
        instructions = json.load(f)

    editor_ops = apply_update_instructions(map_data, instructions)

    save_path = args.out_map or args.map_file
    with open(save_path, "w", encoding="utf-8") as f:
        json.dump(map_data, f, indent=2)
    print(f"Updated map saved to {save_path} ✓")

    if args.out_ops:
        with open(args.out_ops, "w", encoding="utf-8") as f:
            json.dump(editor_ops, f, indent=2)
        print(f"Generated {len(editor_ops)} editor ops in {args.out_ops} ✓")


if __name__ == "__main__":
    main()
