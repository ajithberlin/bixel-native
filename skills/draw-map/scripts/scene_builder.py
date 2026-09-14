#!/usr/bin/env python3
"""
scene_builder.py - Multi-layer scene generator and layer-stamping engine.

Translates scene specifications, ASCII layouts, and tile catalogs into:
  1. Complete Tiled 1.10 JSON maps (.map / .json) for orthogonal and isometric scenes.
  2. Batch editor_command ops for direct layer stamping in Bixel Studio.
"""

import sys
import os
import json
import argparse
from typing import Dict, Any, List, Optional, Tuple, Union

# Import local tile_math & iso_designer
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from tile_math import encode_gid, parse_direction, transform_pattern
from iso_designer import fit_iso_grid_to_viewport, is_valid_diamond_ratio


def load_catalog(catalog_path: str) -> Dict[str, Any]:
    """Loads tile_catalog.json and indexes tiles by id and by name."""
    if not os.path.exists(catalog_path):
        return {"tiles_by_id": {}, "tiles_by_name": {}, "meta": {}}

    with open(catalog_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    tiles_by_id = {}
    tiles_by_name = {}

    for k, v in data.get("tiles", {}).items():
        tid = int(v.get("id", k))
        tiles_by_id[tid] = v
        name = v.get("name")
        if name:
            tiles_by_name[name.lower()] = tid
        for tag in v.get("tags", []):
            tiles_by_name[tag.lower()] = tid

    return {
        "tiles_by_id": tiles_by_id,
        "tiles_by_name": tiles_by_name,
        "meta": data
    }


def resolve_tile_ref(ref: Union[int, str, dict], catalog: Dict[str, Any], first_gid: int = 1) -> int:
    """
    Resolves a tile reference (int ID, string name, or dict {tile, direction}) into a GID with flip flags.
    """
    if ref is None or ref == 0 or ref == "." or ref == "empty":
        return 0

    direction = "normal"
    raw_id = 0

    if isinstance(ref, dict):
        direction = ref.get("direction", "normal")
        tile_val = ref.get("tile", 0)
        gid = resolve_tile_ref(tile_val, catalog, first_gid=first_gid)
        if gid > 0 and direction != "normal":
            from tile_math import transform_tile
            return transform_tile(gid, direction)
        return gid
    elif isinstance(ref, int):
        raw_id = ref
    elif isinstance(ref, str):
        ref_clean = ref.strip().lower()
        if "@" in ref_clean:
            name_part, dir_part = ref_clean.split("@", 1)
            direction = dir_part
            ref_clean = name_part

        by_name = catalog.get("tiles_by_name", {})
        if ref_clean.isdigit():
            raw_id = int(ref_clean)
        elif ref_clean in by_name:
            raw_id = by_name[ref_clean]
        else:
            # Fuzzy match: find if ref_clean is substring of a tile name or vice versa
            matched_id = None
            for name_key, tid in by_name.items():
                if ref_clean in name_key or name_key in ref_clean:
                    matched_id = tid
                    break
            if matched_id is not None:
                raw_id = matched_id
            else:
                return 0

    return encode_gid(local_id=raw_id, first_gid=first_gid, direction=direction)


def build_layer_grid_from_ascii(ascii_rows: List[str], legend: Dict[str, Any], catalog: Dict[str, Any],
                               cols: int, rows: int, first_gid: int = 1) -> List[int]:
    """Converts ASCII grid rows and a legend into a flat 1D GID array of size cols * rows."""
    grid = [0] * (cols * rows)
    for r, line in enumerate(ascii_rows):
        if r >= rows:
            break
        # Tokenize by char or spaces
        tokens = line.split() if " " in line.strip() else list(line.strip())
        for c, char in enumerate(tokens):
            if c >= cols:
                break
            if char in legend:
                ref = legend[char]
                gid = resolve_tile_ref(ref, catalog, first_gid=first_gid)
                grid[r * cols + c] = gid
    return grid


def create_tiled_map_json(
    width: int,
    height: int,
    tile_width: int,
    tile_height: int,
    orientation: str = "orthogonal",
    layers_data: Optional[List[Dict[str, Any]]] = None,
    tilesets_data: Optional[List[Dict[str, Any]]] = None
) -> Dict[str, Any]:
    """Generates a valid Tiled 1.10 JSON map object."""
    layers_data = layers_data or []
    tilesets_data = tilesets_data or []

    map_layers = []
    for idx, l in enumerate(layers_data):
        lid = idx + 1
        name = l.get("name", f"Layer {lid}")
        visible = l.get("visible", True)
        opacity = l.get("opacity", 1.0)
        layer_type = l.get("type", "tilelayer")
        data = l.get("data", [0] * (width * height))

        map_layers.append({
            "id": lid,
            "name": name,
            "type": layer_type,
            "visible": visible,
            "opacity": opacity,
            "width": width,
            "height": height,
            "x": 0,
            "y": 0,
            "data": data
        })

    tiled_map = {
        "version": "1.10",
        "type": "map",
        "orientation": orientation,
        "renderorder": "right-down",
        "width": width,
        "height": height,
        "tilewidth": tile_width,
        "tileheight": tile_height,
        "infinite": False,
        "nextlayerid": len(map_layers) + 1,
        "nextobjectid": 1,
        "tilesets": tilesets_data,
        "layers": map_layers
    }

    return tiled_map


def generate_editor_ops(
    layers_data: List[Dict[str, Any]],
    width: int,
    height: int,
    orientation: str = "orthogonal",
    tileset_meta: Optional[Dict[str, Any]] = None
) -> List[Dict[str, Any]]:
    """
    Generates a list of Bixel editor_command operations (map_add_layer, map_stamp, etc.)
    for stamping the scene directly to the active editor.
    """
    ops: List[Dict[str, Any]] = []

    # 1. Orientation op if not orthogonal
    if orientation != "orthogonal":
        ops.append({
            "op": "map_set_orientation",
            "orientation": orientation
        })

    # 2. Resize map if different
    ops.append({
        "op": "map_resize",
        "width": width,
        "height": height
    })

    # 3. Add tileset if specified
    if tileset_meta and "image_path" in tileset_meta:
        ops.append({
            "op": "map_add_tileset",
            "name": tileset_meta.get("tileset_image", "Tileset"),
            "image": tileset_meta["image_path"],
            "tile_width": tileset_meta.get("tile_width", 16),
            "tile_height": tileset_meta.get("tile_height", 16),
            "margin": tileset_meta.get("margin", 0),
            "spacing": tileset_meta.get("spacing", 0)
        })

    # 4. Stamp each layer
    for layer_idx, layer in enumerate(layers_data):
        layer_name = layer.get("name", f"Tile Layer {layer_idx + 1}")
        # Add layer
        ops.append({
            "op": "map_add_layer",
            "name": layer_name,
            "layer_type": "tile"
        })

        # Break 1D data into 2D rows for map_stamp
        raw_data = layer.get("data", [])
        if raw_data:
            rows_2d = []
            for r in range(height):
                row_slice = raw_data[r * width : (r + 1) * width]
                rows_2d.append([int(g) for g in row_slice])

            # Stamp full layer (skip_empty=True)
            ops.append({
                "op": "map_stamp",
                "layer": layer_idx,
                "x": 0,
                "y": 0,
                "tiles": rows_2d,
                "skip_empty": True
            })

    return ops


def build_scene_from_spec(spec_data: Dict[str, Any], catalog_path: Optional[str] = None) -> Dict[str, Any]:
    """
    Builds a scene from a structured specification dictionary:
      - spec_data contains width, height, orientation, tilewidth, tileheight, tileset, legend, layers
    """
    catalog = load_catalog(catalog_path) if catalog_path else {"tiles_by_id": {}, "tiles_by_name": {}, "meta": {}}

    orientation = spec_data.get("orientation", "orthogonal").lower()
    tw = spec_data.get("tilewidth", 16)
    th = spec_data.get("tileheight", 16)

    # Designer intelligence for isometric viewport sizing if viewport is specified
    if "viewport" in spec_data and orientation == "isometric":
        vw, vh = spec_data["viewport"]
        iso_fit = fit_iso_grid_to_viewport(vw, vh, tw, th)
        w = spec_data.get("width", iso_fit["columns"])
        h = spec_data.get("height", iso_fit["rows"])
    else:
        w = spec_data.get("width", 20)
        h = spec_data.get("height", 15)

    first_gid = spec_data.get("first_gid", 1)
    tilesets = spec_data.get("tilesets", [])
    if not tilesets and "tileset" in spec_data:
        ts = spec_data["tileset"]
        tilesets = [{
            "firstgid": first_gid,
            "name": ts.get("name", "Tileset"),
            "image": ts.get("image", "tiles.png"),
            "imagewidth": ts.get("imagewidth", 256),
            "imageheight": ts.get("imageheight", 256),
            "tilewidth": tw,
            "tileheight": th,
            "columns": ts.get("columns", 16),
            "tilecount": ts.get("tilecount", 256),
            "margin": ts.get("margin", 0),
            "spacing": ts.get("spacing", 0)
        }]

    legend = spec_data.get("legend", {})
    layers_in = spec_data.get("layers", {})
    layers_out: List[Dict[str, Any]] = []

    # Check if layers is a dict of {name: ascii_rows} or list of layer objects
    if isinstance(layers_in, dict):
        for layer_name, layer_content in layers_in.items():
            if isinstance(layer_content, list) and layer_content and isinstance(layer_content[0], str):
                grid_data = build_layer_grid_from_ascii(layer_content, legend, catalog, w, h, first_gid=first_gid)
            elif isinstance(layer_content, list):
                grid_data = layer_content
            else:
                grid_data = [0] * (w * h)

            layers_out.append({
                "name": layer_name,
                "data": grid_data
            })
    elif isinstance(layers_in, list):
        for l in layers_in:
            l_name = l.get("name", "Tile Layer")
            raw_content = l.get("data", [])
            if raw_content and isinstance(raw_content[0], str):
                grid_data = build_layer_grid_from_ascii(raw_content, legend, catalog, w, h, first_gid=first_gid)
            else:
                grid_data = raw_content
            layers_out.append({
                "name": l_name,
                "data": grid_data
            })

    tiled_map = create_tiled_map_json(
        width=w,
        height=h,
        tile_width=tw,
        tile_height=th,
        orientation=orientation,
        layers_data=layers_out,
        tilesets_data=tilesets
    )

    editor_ops = generate_editor_ops(
        layers_data=layers_out,
        width=w,
        height=h,
        orientation=orientation,
        tileset_meta=catalog.get("meta")
    )

    return {
        "map_json": tiled_map,
        "editor_ops": editor_ops,
        "width": w,
        "height": h,
        "orientation": orientation,
        "tile_width": tw,
        "tile_height": th
    }


def main():
    parser = argparse.ArgumentParser(description="Multi-layer scene builder & layer-stamping engine.")
    parser.add_argument("--spec", type=str, help="Path to scene specification JSON file")
    parser.add_argument("--catalog", type=str, help="Path to tile_catalog.json")
    parser.add_argument("--output-map", type=str, help="Path to save generated Tiled JSON (.map/.json)")
    parser.add_argument("--output-ops", type=str, help="Path to save editor_command ops JSON")
    args = parser.parse_args()

    if not args.spec:
        parser.print_help()
        sys.exit(1)

    with open(args.spec, "r", encoding="utf-8") as f:
        spec = json.load(f)

    result = build_scene_from_spec(spec, catalog_path=args.catalog)

    if args.output_map:
        with open(args.output_map, "w", encoding="utf-8") as f:
            json.dump(result["map_json"], f, indent=2)
        print(f"Saved Tiled map to {args.output_map} ✓")

    if args.output_ops:
        with open(args.output_ops, "w", encoding="utf-8") as f:
            json.dump(result["editor_ops"], f, indent=2)
        print(f"Saved editor ops to {args.output_ops} ✓")

    if not args.output_map and not args.output_ops:
        print(json.dumps(result["map_json"], indent=2))


if __name__ == "__main__":
    main()
