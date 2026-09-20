---
name: draw-map
description: >
  Intelligently design, create, catalog, and stamp 2D tilemaps and scenes for both Orthogonal and Isometric/Staggered maps. Use when the user asks to "draw a map", "create a tilemap", "build a scene", "draw an isometric map", "generate a level", "stamp tiles to layer", "catalog this tileset", "flip tiles", or "update/edit this map". Handles tile-by-tile semantic understanding, 8-way flip/rotation flags, multi-layer depth planning (Ground, Decor, Structures, Overhead), intelligent 2:1 isometric diamond sizing and vertical extrusion offsets, tileset readiness checks with multi-skill generation collaboration, and direct in-editor layer stamping.
---

# Draw Map — Multi-Layer Tilemap & Scene Designer

Intelligently design, build, catalog, and stamp 2D game maps across both **Orthogonal** and **Isometric** projections.

---

## 1. Readiness Gate: Tileset Availability & Multi-Skill Collaboration

Before drawing a map, ensure a suitable tileset is available:

1. **Inspect Active State**:
   - Call `editor_read` (or inspect the workspace project assets). Check if the map has at least one tileset.
2. **If No Suitable Tileset Exists**:
   - **Do NOT fail silently or paint blank tiles.**
   - **Ask User Permission** to collaborate with asset generation skills:
     > *"No tileset is currently loaded for this scene. Would you like me to generate one for you using `pixel-tileset-gen` (for terrain/Wang autotiling or platforms) or `pixel_image_gen` (for themed isometric buildings/props)?"*
3. **Collaboration Flow Upon Approval**:
   - **Step A**: Invoke `load_skill pixel-tileset-gen` (or run `pixel_image_gen` with clear grid guidance).
   - **Step B**: Save the generated tileset PNG into the project `assets/` directory (e.g. via `accept_asset` op or file copy).
   - **Step C**: Register the tileset to the map with `map_add_tileset` op:
     ```json
     {
       "op": "map_add_tileset",
       "name": "VillageTiles",
       "image": "assets/village_tiles.png",
       "tile_width": 32,
       "tile_height": 16,
       "margin": 0,
       "spacing": 0
     }
     ```
   - **Step D**: Proceed to Step 2 to catalog and stamp the scene!

---

## 2. Projection & Designer Sizing Intelligence

Choose the projection based on user intent:
- **Orthogonal**: Top-down or 2D sidescroller (standard square/rectangular grid).
- **Isometric**: Classic 2:1 diamond grid (Strategy, Tactics, RPGs like Diablo, Age of Empires, SimCity).

### Designer Sizing for Isometric:
Run `scripts/iso_designer.py` to calculate optimal dimensions:

```bash
# Calculate optimal columns & rows for a 1280x720 screen framing with 64x32 diamond tiles
python3 scripts/iso_designer.py --viewport 1280x720 --tile-size 64x32
```

- **Diamond 2:1 Ratio**: Standard isometric tiles have `tile_width = 2 * tile_height` (e.g. 64×32, 32×16, 128×64).
- **Tall Tile Extrusions**: When tiles have vertical height (e.g. a 64×64 wall sprite on a 64×32 diamond grid):
  ```bash
  python3 scripts/iso_designer.py --analyze-image 256 256 --tile-dim 64 64
  ```
  The script identifies the 32px vertical wall extrusion and recommends `tileoffset: (0, -32)` so the diamond base stays locked to the ground plane.

---

## 3. Understand the Tileset: Tile-by-Tile Cataloging

Every tile in a tileset has a local index `0, 1, 2, ...` and grid position `(col, row)`.

```bash
# Slice tileset, generate visual contact sheet, and build initial catalog
python3 scripts/catalog_tiles.py assets/tileset.png --tile-width 16 --tile-height 16 --outdir ./tmp/cat

# Assign semantic labels
python3 scripts/catalog_tiles.py --catalog ./tmp/cat/tile_catalog.json \
    --label 0:water_deep 1:grass_center 2:stone_floor 3:dirt_path 10:tree_top_left
```

- **Visual Contact Sheet (`contact_sheet.png`)**: Open or view the generated contact sheet. Every tile has an illuminated badge showing its local ID number (`[0]`, `[1]`, `[2]`), allowing precise visual identification.
- **Search Catalog**:
  ```bash
  python3 scripts/catalog_tiles.py --catalog ./tmp/cat/tile_catalog.json --search water
  ```

---

## 4. Flipping & All 8 Directions

Tiles can be stamped in 8 canonical orientations using Tiled GID flag bits:
- `GID_H_FLIP = 0x80000000` (Horizontal mirror)
- `GID_V_FLIP = 0x40000000` (Vertical mirror)
- `GID_D_FLIP = 0x20000000` (Diagonal mirror / Transpose)

Use `scripts/tile_math.py`:

```bash
# Encode a tile with 90° clockwise rotation
python3 scripts/tile_math.py --encode 5 --first-gid 1 --dir rot_90

# Decode a raw GID to its local ID and direction
python3 scripts/tile_math.py --decode 2684354565 --first-gid 1
```

Supported direction names:
`normal`, `flip_h`, `flip_v`, `flip_d`, `rot_90`, `rot_180`, `rot_270`, `anti_transpose`.

**Isometric Flipping**:
`flip_h` mirrors the tile horizontally across the vertical axis, swapping left-facing walls/slopes into right-facing walls/slopes.

---

## 5. Designing & Direct Layer Stamping

Always structure maps into standard game engine layers:

| Layer Order | Layer Name | Content | Rules |
|---|---|---|---|
| **0** | `Ground` | Base terrain (grass, water, stone floor) | Solid, continuous |
| **1** | `Decor` / `Paths` | Footpaths, flowers, shorelines, carpets | `skip_empty: true` |
| **2** | `Structures` / `Walls` | Buildings, cliff walls, fences, tree trunks | `skip_empty: true` |
| **3** | `Overhead` / `Roofs` | Roof tops, upper tree foliage (overhead) | `skip_empty: true` |

### Method A: Direct In-Engine Stamping (`editor_command`)
Apply updates directly to the live editor:

```json
{
  "ops": [
    {
      "op": "map_add_layer",
      "name": "Structures",
      "layer_type": "tile"
    },
    {
      "op": "map_stamp",
      "layer": 1,
      "x": 5,
      "y": 8,
      "tiles": [
        [10, 11],
        [12, 13]
      ],
      "skip_empty": true
    }
  ]
}
```

### Method B: Scene Specification Generator (`scripts/scene_builder.py`)
Write an ASCII layout spec and compile it into a Tiled JSON map or editor ops:

```json
{
  "width": 10,
  "height": 8,
  "tilewidth": 16,
  "tileheight": 16,
  "orientation": "orthogonal",
  "legend": {
    "G": "grass_center",
    "W": "water_deep",
    "S": "stone_floor",
    ".": "empty"
  },
  "layers": {
    "Ground": [
      "GGGGGGGGGG",
      "GGWWWWGGGG",
      "GGWWWWGGGG",
      "GGGGGGGGGG",
      "GGGGGGGGGG",
      "GGGGGGGGGG",
      "GGGGGGGGGG",
      "GGGGGGGGGG"
    ],
    "Structures": [
      "..........",
      "..........",
      "....SSSS..",
      "....SSSS..",
      "..........",
      "..........",
      "..........",
      ".........."
    ]
  }
}
```

Compile command:
```bash
python3 scripts/scene_builder.py --spec scene.json --catalog tile_catalog.json \
    --output-map village.json --output-ops ops.json
```

---

## 6. Inspecting & Updating Existing Scenes

Never overwrite existing work blindly.

### 1. Inspect Existing Content
```bash
# View layer breakdown, occupied cell count, and ASCII occupancy map
python3 scripts/inspect_map.py existing_map.json --ascii
```

Or query the live editor with `editor_read` / `map_read_region`:
```json
{
  "ops": [
    {
      "op": "map_read_region",
      "layer": 0,
      "x": 0,
      "y": 0,
      "width": 10,
      "height": 10
    }
  ]
}
```

### 2. Update Safely
```bash
python3 scripts/update_map.py existing_map.json --instructions updates.json --out-ops update_ops.json
```

Instruction actions supported by `update_map.py`:
- `add_layer`: Adds a named layer if not already present.
- `stamp`: Stamps a multi-tile structure with `skip_empty: true`.
- `replace`: Replaces all occurrences of `old_gid` with `new_gid` across a layer or box.
- `clear`: Clears a bounded area without touching other layers.

---

## 7. Delivery Checklist

- [ ] Tileset verified / cataloged with semantic names.
- [ ] Projection (`orthogonal` vs `isometric`) set correctly with verified aspect ratio.
- [ ] Stamped content placed on appropriate semantic layers (`Ground`, `Decor`, `Structures`, `Overhead`).
- [ ] Multi-tile stamps used `skip_empty: true` to avoid erasing lower details.
- [ ] Existing scene elements preserved during updates.
