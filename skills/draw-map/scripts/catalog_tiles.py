#!/usr/bin/env python3
"""
catalog_tiles.py - Inspect tilesets tile-by-tile, generate annotated contact sheets,
and maintain semantic tile dictionaries for AI scene generation.

Works with Pillow when available for visual contact sheets and dominant color detection,
and includes a pure-Python fallback for environments before venv dependencies are staged.
"""

import sys
import os
import json
import struct
import argparse
from typing import Dict, Any, List, Optional, Tuple

try:
    from PIL import Image, ImageDraw, ImageFont
    HAS_PIL = True
except ImportError:
    HAS_PIL = False


def get_png_dimensions(path: str) -> Optional[Tuple[int, int]]:
    """Reads PNG width and height directly from the IHDR chunk (no dependencies)."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
            if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
                w, h = struct.unpack(">II", head[16:24])
                return w, h
    except Exception:
        pass
    return None


def get_dominant_color(img: Any) -> str:
    """Computes the dominant RGBA/RGB color as a hex string (requires Pillow)."""
    if not HAS_PIL:
        return "#808080"
    small = img.resize((8, 8), Image.Resampling.BOX)
    pixels = list(small.getdata())
    non_alpha = [p[:3] for p in pixels if len(p) < 4 or p[3] > 64]
    if not non_alpha:
        return "#00000000"
    r = sum(p[0] for p in non_alpha) // len(non_alpha)
    g = sum(p[1] for p in non_alpha) // len(non_alpha)
    b = sum(p[2] for p in non_alpha) // len(non_alpha)
    return f"#{r:02x}{g:02x}{b:02x}"


def analyze_tile_transparency(img: Any) -> Tuple[bool, float]:
    """Returns (is_empty, opacity_ratio) (requires Pillow)."""
    if not HAS_PIL or img.mode != "RGBA":
        return False, 1.0
    alpha = img.split()[-1]
    hist = alpha.histogram()
    transparent_pixels = hist[0]
    total = img.width * img.height
    opacity_ratio = 1.0 - (transparent_pixels / total)
    is_empty = (transparent_pixels == total)
    return is_empty, opacity_ratio


def slice_and_catalog_tileset(
    image_path: str,
    tile_w: int,
    tile_h: int,
    margin: int = 0,
    spacing: int = 0,
    output_dir: Optional[str] = None,
    save_individual_tiles: bool = False,
    existing_catalog_path: Optional[str] = None
) -> Dict[str, Any]:
    """
    Slices a tileset image tile by tile, generates an annotated contact sheet (if Pillow is present),
    and returns a structured catalog dictionary.
    """
    if not os.path.exists(image_path):
        raise FileNotFoundError(f"Tileset image not found: {image_path}")

    out_dir = output_dir or os.path.dirname(image_path) or "."
    os.makedirs(out_dir, exist_ok=True)

    img = None
    if HAS_PIL:
        img = Image.open(image_path).convert("RGBA")
        img_w, img_h = img.size
    else:
        dims = get_png_dimensions(image_path)
        if dims is None:
            raise ValueError(f"Cannot parse PNG dimensions from: {image_path}")
        img_w, img_h = dims

    stride_x = tile_w + spacing
    stride_y = tile_h + spacing

    cols = (img_w - margin + spacing) // stride_x if stride_x > 0 else 0
    rows = (img_h - margin + spacing) // stride_y if stride_y > 0 else 0
    tile_count = cols * rows

    # Load existing catalog if available
    existing_data: Dict[str, Any] = {}
    if existing_catalog_path and os.path.exists(existing_catalog_path):
        try:
            with open(existing_catalog_path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                existing_data = loaded.get("tiles", {})
        except Exception:
            pass

    tiles_dict: Dict[str, Any] = {}
    contact_sheet_path: Optional[str] = None

    if HAS_PIL and img:
        contact_sheet = img.copy()
        draw = ImageDraw.Draw(contact_sheet)
        try:
            font = ImageFont.load_default()
        except Exception:
            font = None

        tiles_dir = os.path.join(out_dir, "tiles")
        if save_individual_tiles:
            os.makedirs(tiles_dir, exist_ok=True)

        for row in range(rows):
            for col in range(cols):
                local_id = row * cols + col
                src_x = margin + col * stride_x
                src_y = margin + row * stride_y

                tile_crop = img.crop((src_x, src_y, src_x + tile_w, src_y + tile_h))
                is_empty, opacity = analyze_tile_transparency(tile_crop)
                dom_color = get_dominant_color(tile_crop)

                if save_individual_tiles:
                    tile_crop.save(os.path.join(tiles_dir, f"tile_{local_id:04d}.png"))

                str_id = str(local_id)
                prev_info = existing_data.get(str_id, {})
                name = prev_info.get("name") or (f"empty_{local_id}" if is_empty else f"tile_{local_id}")
                tags = prev_info.get("tags") or ([] if not is_empty else ["empty"])
                category = prev_info.get("category") or ("empty" if is_empty else "general")

                tiles_dict[str_id] = {
                    "id": local_id,
                    "col": col,
                    "row": row,
                    "name": name,
                    "category": category,
                    "tags": tags,
                    "is_empty": is_empty,
                    "opacity_ratio": round(opacity, 3),
                    "dominant_color": dom_color,
                    "box": [src_x, src_y, src_x + tile_w, src_y + tile_h]
                }

                # Badge on contact sheet
                badge_text = str(local_id)
                badge_w = max(10, len(badge_text) * 7 + 4)
                badge_h = 10
                badge_x0 = src_x + 1
                badge_y0 = src_y + 1
                badge_x1 = badge_x0 + badge_w
                badge_y1 = badge_y0 + badge_h

                if not is_empty:
                    draw.rectangle([badge_x0, badge_y0, badge_x1, badge_y1], fill=(0, 0, 0, 180))
                    draw.rectangle([src_x, src_y, src_x + tile_w - 1, src_y + tile_h - 1], outline=(255, 255, 255, 60))
                    draw.text((badge_x0 + 2, badge_y0 - 1), badge_text, fill=(255, 255, 0, 255), font=font)
                else:
                    draw.rectangle([src_x, src_y, src_x + tile_w - 1, src_y + tile_h - 1], outline=(100, 100, 100, 40))

        contact_sheet_path = os.path.join(out_dir, "contact_sheet.png")
        contact_sheet.save(contact_sheet_path)
    else:
        # Pure Python fallback for catalog metadata
        for row in range(rows):
            for col in range(cols):
                local_id = row * cols + col
                src_x = margin + col * stride_x
                src_y = margin + row * stride_y
                str_id = str(local_id)
                prev_info = existing_data.get(str_id, {})
                tiles_dict[str_id] = {
                    "id": local_id,
                    "col": col,
                    "row": row,
                    "name": prev_info.get("name") or f"tile_{local_id}",
                    "category": prev_info.get("category") or "general",
                    "tags": prev_info.get("tags") or [],
                    "is_empty": False,
                    "opacity_ratio": 1.0,
                    "dominant_color": "#808080",
                    "box": [src_x, src_y, src_x + tile_w, src_y + tile_h]
                }

    catalog_data = {
        "tileset_image": os.path.basename(image_path),
        "image_path": image_path,
        "contact_sheet": contact_sheet_path,
        "image_width": img_w,
        "image_height": img_h,
        "tile_width": tile_w,
        "tile_height": tile_h,
        "margin": margin,
        "spacing": spacing,
        "columns": cols,
        "rows": rows,
        "tile_count": tile_count,
        "tiles": tiles_dict
    }

    catalog_json_path = os.path.join(out_dir, "tile_catalog.json")
    with open(catalog_json_path, "w", encoding="utf-8") as f:
        json.dump(catalog_data, f, indent=2)

    return catalog_data


def update_tile_labels(catalog_path: str, labels: Dict[str, str]) -> Dict[str, Any]:
    """Update semantic names and tags for specified tile IDs in catalog.json."""
    if not os.path.exists(catalog_path):
        raise FileNotFoundError(f"Catalog file not found: {catalog_path}")

    with open(catalog_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    tiles = catalog.setdefault("tiles", {})
    for id_str, label in labels.items():
        if id_str in tiles:
            tiles[id_str]["name"] = label
            clean_tags = [part.strip().lower() for part in label.replace("-", "_").split("_") if part.strip()]
            for t in clean_tags:
                if t not in tiles[id_str]["tags"]:
                    tiles[id_str]["tags"].append(t)

    with open(catalog_path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, indent=2)

    return catalog


def search_tiles(catalog_path: str, query: str) -> List[Dict[str, Any]]:
    """Search catalog for tiles matching a name or tag query."""
    if not os.path.exists(catalog_path):
        return []
    with open(catalog_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    q = query.lower().strip()
    results = []
    for tile in catalog.get("tiles", {}).values():
        name = tile.get("name", "").lower()
        tags = [t.lower() for t in tile.get("tags", [])]
        category = tile.get("category", "").lower()
        if q in name or q in category or any(q in t for t in tags):
            results.append(tile)
    return results


def main():
    parser = argparse.ArgumentParser(description="Tileset inspector, contact sheet generator, and cataloger.")
    parser.add_argument("tileset", nargs="?", help="Path to tileset PNG image")
    parser.add_argument("--tile-width", type=int, default=16, help="Tile width in pixels (default 16)")
    parser.add_argument("--tile-height", type=int, default=16, help="Tile height in pixels (default 16)")
    parser.add_argument("--margin", type=int, default=0, help="Margin in pixels (default 0)")
    parser.add_argument("--spacing", type=int, default=0, help="Spacing in pixels (default 0)")
    parser.add_argument("--outdir", type=str, help="Output directory for catalog and contact sheet")
    parser.add_argument("--save-tiles", action="store_true", help="Save individual sliced tiles to tiles/ subfolder")
    parser.add_argument("--label", nargs="+", help="Assign names: e.g. --label 0:water 1:grass_center 2:stone_wall")
    parser.add_argument("--batch-label", type=str, help="Path to JSON file mapping id to name")
    parser.add_argument("--catalog", type=str, help="Existing catalog.json path to update or search")
    parser.add_argument("--search", type=str, help="Search tile catalog by name or tag")

    args = parser.parse_args()

    if args.search:
        cat_path = args.catalog or (os.path.join(args.outdir, "tile_catalog.json") if args.outdir else "tile_catalog.json")
        matches = search_tiles(cat_path, args.search)
        print(json.dumps(matches, indent=2))
        return

    if args.label or args.batch_label:
        cat_path = args.catalog or (os.path.join(args.outdir, "tile_catalog.json") if args.outdir else "tile_catalog.json")
        label_map: Dict[str, str] = {}
        if args.label:
            for item in args.label:
                if ":" in item:
                    k, v = item.split(":", 1)
                    label_map[k.strip()] = v.strip()
        if args.batch_label and os.path.exists(args.batch_label):
            with open(args.batch_label, "r", encoding="utf-8") as f:
                label_map.update(json.load(f))
        res = update_tile_labels(cat_path, label_map)
        print(f"Updated {len(label_map)} labels in {cat_path} ✓")
        return

    if args.tileset:
        cat = slice_and_catalog_tileset(
            args.tileset,
            tile_w=args.tile_width,
            tile_h=args.tile_height,
            margin=args.margin,
            spacing=args.spacing,
            output_dir=args.outdir,
            save_individual_tiles=args.save_tiles,
            existing_catalog_path=args.catalog
        )
        print(f"Cataloged {cat['tile_count']} tiles ({cat['columns']}x{cat['rows']}).")
        if cat.get('contact_sheet'):
            print(f"Contact sheet: {cat['contact_sheet']}")
        print(f"Tile catalog:  {os.path.join(args.outdir or '.', 'tile_catalog.json')} ✓")
        return

    parser.print_help()


if __name__ == "__main__":
    main()
