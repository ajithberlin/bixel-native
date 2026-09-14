#!/usr/bin/env python3
"""
inspect_map.py - Inspect existing Tiled JSON maps (.map / .json) or editor state.

Reports:
  - Dimensions, projection orientation, tile sizes, tileset inventory
  - Layer hierarchy: index, name, type, visibility, opacity, occupied tile count
  - Bounding box of painted content per layer
  - ASCII visual representation of layer contents
"""

import sys
import os
import json
import argparse
from typing import Dict, Any, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from tile_math import decode_gid


def inspect_map_data(map_data: Dict[str, Any]) -> Dict[str, Any]:
    """Analyzes a Tiled map JSON structure and computes detailed statistics."""
    w = map_data.get("width", 0)
    h = map_data.get("height", 0)
    tw = map_data.get("tilewidth", 16)
    th = map_data.get("tileheight", 16)
    orientation = map_data.get("orientation", "orthogonal")
    render_order = map_data.get("renderorder", "right-down")
    infinite = map_data.get("infinite", False)

    tilesets_report = []
    for ts in map_data.get("tilesets", []):
        tilesets_report.append({
            "name": ts.get("name", ""),
            "first_gid": ts.get("firstgid", 1),
            "image": ts.get("image", ""),
            "tile_width": ts.get("tilewidth", tw),
            "tile_height": ts.get("tileheight", th),
            "columns": ts.get("columns", 0),
            "tile_count": ts.get("tilecount", 0)
        })

    layers_report = []
    for idx, layer in enumerate(map_data.get("layers", [])):
        layer_name = layer.get("name", f"Layer {idx + 1}")
        layer_type = layer.get("type", "tilelayer")
        visible = layer.get("visible", True)
        opacity = layer.get("opacity", 1.0)

        lw = layer.get("width", w)
        lh = layer.get("height", h)

        raw_data = layer.get("data", [])
        chunks = layer.get("chunks", [])

        occupied_count = 0
        min_x, min_y = 999999, 999999
        max_x, max_y = -999999, -999999
        unique_gids = set()

        ascii_lines = []

        if raw_data and lw > 0 and lh > 0:
            for y in range(lh):
                row_chars = []
                for x in range(lw):
                    cell_idx = y * lw + x
                    if cell_idx < len(raw_data):
                        gid = raw_data[cell_idx]
                        if gid != 0:
                            occupied_count += 1
                            unique_gids.add(gid)
                            min_x = min(min_x, x)
                            min_y = min(min_y, y)
                            max_x = max(max_x, x)
                            max_y = max(max_y, y)
                            row_chars.append("#")
                        else:
                            row_chars.append(".")
                    else:
                        row_chars.append(".")
                ascii_lines.append("".join(row_chars))

        elif chunks:
            # Infinite map chunk handling
            for chunk in chunks:
                cx = chunk.get("x", 0)
                cy = chunk.get("y", 0)
                cw = chunk.get("width", 16)
                ch = chunk.get("height", 16)
                cdata = chunk.get("data", [])
                for i, gid in enumerate(cdata):
                    if gid != 0:
                        occupied_count += 1
                        unique_gids.add(gid)
                        cell_x = cx + (i % cw)
                        cell_y = cy + (i // cw)
                        min_x = min(min_x, cell_x)
                        min_y = min(min_y, cell_y)
                        max_x = max(max_x, cell_x)
                        max_y = max(max_y, cell_y)

        has_occupied = occupied_count > 0
        bounds = [min_x, min_y, max_x, max_y] if has_occupied else None

        layers_report.append({
            "index": idx,
            "id": layer.get("id", idx + 1),
            "name": layer_name,
            "type": layer_type,
            "visible": visible,
            "opacity": opacity,
            "width": lw,
            "height": lh,
            "occupied_tiles": occupied_count,
            "bounding_box": bounds,
            "unique_tile_count": len(unique_gids),
            "ascii_preview": ascii_lines[:30]  # Cap at 30 rows for brevity
        })

    return {
        "width": w,
        "height": h,
        "tile_width": tw,
        "tile_height": th,
        "orientation": orientation,
        "render_order": render_order,
        "infinite": infinite,
        "tilesets": tilesets_report,
        "layers": layers_report
    }


def main():
    parser = argparse.ArgumentParser(description="Inspect existing Tiled JSON maps or editor state.")
    parser.add_argument("map_file", help="Path to Tiled map JSON file (.map or .json)")
    parser.add_argument("--json", action="store_true", help="Output full JSON analysis report")
    parser.add_argument("--ascii", action="store_true", help="Print ASCII occupancy map")
    parser.add_argument("--layer", type=int, help="Inspect specific layer index")
    args = parser.parse_args()

    if not os.path.exists(args.map_file):
        print(f"File not found: {args.map_file}")
        sys.exit(1)

    with open(args.map_file, "r", encoding="utf-8") as f:
        map_json = json.load(f)

    report = inspect_map_data(map_json)

    if args.json:
        print(json.dumps(report, indent=2))
        return

    # Formatted terminal summary
    print(f"Map: {args.map_file}")
    print(f"  Dimensions:   {report['width']} x {report['height']} cells ({report['tile_width']}x{report['tile_height']} px/tile)")
    print(f"  Orientation:  {report['orientation']} (render order: {report['render_order']})")
    print(f"  Tilesets:     {len(report['tilesets'])} loaded")
    for ts in report["tilesets"]:
        print(f"    - '{ts['name']}' (firstgid={ts['first_gid']}, {ts['columns']} cols, {ts['tile_count']} tiles)")

    print(f"\nLayers ({len(report['layers'])}):")
    for l in report["layers"]:
        bbox_str = f"bounds: ({l['bounding_box'][0]}, {l['bounding_box'][1]}) to ({l['bounding_box'][2]}, {l['bounding_box'][3]})" if l['bounding_box'] else "empty"
        vis_str = "visible" if l['visible'] else "hidden"
        print(f"  [{l['index']}] \"{l['name']}\" ({l['type']}, {vis_str}, opacity {l['opacity']}): {l['occupied_tiles']} tiles, {bbox_str}")

        if args.ascii and l.get("ascii_preview"):
            print(f"    ASCII occupancy preview:")
            for line in l["ascii_preview"]:
                print(f"      {line}")


if __name__ == "__main__":
    main()
