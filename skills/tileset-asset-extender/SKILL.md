---
name: tileset-asset-extender
description: >-
  Add or generate new assets and insert them into an existing tileset / sprite sheet PNG (game map objects and area tiles). Use when the user asks to "add an asset to this tileset", "generate a building/tree/prop and put it in the tileset", "extend the tileset with ...", "add a road/grass/river area tile to the sheet", or provides a tileset image and wants one or more objects or area tiles appended in the same style and grid. Handles grid detection, AI asset generation with transparent background (object vs area types), grid-snapped bottom-anchored insertion without overlaps, canvas extension, seamless area-tile slicing, and final validation. Do NOT use for building full tilemap layouts (tilemap-blocks-gen / tilemap-reference-gen), character spritesheets (pixel-spritesheet-gen), or extracting objects from AI sheets (tile-object-extractor).
---

# Tileset Asset Extender

Append newly generated or user-provided assets to an existing tileset PNG so
they sit on the same grid, in the same style, without disturbing existing
content.

## Workflow

### 1. Identify the tileset and its grid

- If the user provided a tileset image, analyze it:
  ```bash
  python3 scripts/analyze_tileset.py TILESET.png            # auto-detect tile size
  python3 scripts/analyze_tileset.py TILESET.png --tile 48  # or pin it
  ```
  The report gives image size, detected tile size, object bounding boxes, and
  free grid slots. Sheets are usually free-form object sheets (variable-size
  sprites loosely snapped to a base grid, e.g. 48 px) — trust the detected
  tile size and the free-slot list, not assumptions of a uniform grid.
- If no file was provided, ask the user to upload the tileset, or offer to
  create a new empty tileset file.
- If creating a new file, ask for the tile size (common: 16/32/48 px), then
  create a transparent RGBA canvas whose width and height are whole multiples
  of that tile size.

### 2. Classify the requested asset

- **Object asset** — discrete props: bus stop, street light, house, temple,
  vending machine, tree, bench. Inserted as one sprite, bottom-anchored in its
  grid footprint.
- **Area asset** — repeatable ground: road, beach, river, grass, pavement.
  Generated as ONE big seamless texture, then sliced into reusable tile-size
  pieces (step 3).

### 3. Create the asset image (skip if the user already supplied the image)

Use a provider image tool — `pixel_image_gen` for pixel art (or `image_gen` for
a general raster look) — requesting a transparent background and PNG output.
Style-match the tileset: examine its perspective (e.g. top-down / 3/4
top-down), outline weight, palette, shading, and say them explicitly in the
prompt.

- Object: one image per asset. Prompt for a single centered object, transparent
  background, same perspective/palette as the sheet. If the user requested
  MULTIPLE assets, generate and insert them ONE BY ONE — never batch them into
  a single generated sheet (spacing/identity is unreliable).
- Area: generate ONE big square opaque texture (e.g. 1K 1:1) described as
  "seamless tileable texture, top-down, uniform pattern, no border, no vignette",
  then slice and seam-check it:
  ```bash
  python3 scripts/slice_area_tiles.py AREA.png --tile 48 --outdir tiles/
  ```
  Regenerate or touch up if seams are flagged. For a single wrap-around tile
  use `--wrap`.

### 4. Insert into the tileset (grid-snapped, no overlap)

Choose the footprint in grid cells (compare with similar existing objects —
e.g. a temple ≈ the existing shrine/buildings). Then:

```bash
python3 scripts/insert_asset.py TILESET.png ASSET.png \
    --tile 48 --tiles-w 6 --tiles-h 4 --out tileset_extended.png
```

The script despeckles and trims the asset (AI output often has stray alpha
specks), scales it to the footprint preserving aspect with a 1 px safety
inset (`--margin`), bottom-anchors it in the lowest free grid slot (or
`--cell C,R` for an explicit position), extends the canvas by whole tile rows
when no slot fits, and refuses to paste where the sprite would overlap or
touch existing pixels. Repeat per asset when inserting several. Keep the
final canvas dimensions whole multiples of the tile size.

### 5. Validate and deliver

```bash
python3 scripts/validate_tileset.py tileset_extended.png --tile 48 \
    --baseline TILESET_original.png --overlay tileset_extended_grid.png
```

All checks must pass: size multiple of tile, transparency present, and no NEW
sprite-to-sprite contacts versus the original baseline (packed sheets already
contain touching sprites — only added ones indicate a bad insert). Inspect
the overlay preview to confirm placement. Deliver the extended tileset (and
the overlay preview if helpful), reporting the tile size, new canvas
dimensions, and where each new asset was placed.

## Scripts

- `scripts/analyze_tileset.py` — grid detection, object boxes, free slots (JSON).
- `scripts/insert_asset.py` — grid-snapped bottom-anchored insertion with
  canvas extension and overlap guard (JSON placement).
- `scripts/slice_area_tiles.py` — slice a big area texture into tiles with
  seam-continuity check (`--wrap` for single tileable tiles).
- `scripts/validate_tileset.py` — final integrity checks + grid-overlay
  preview; exit 0 only when the sheet is clean.

## Rules

- Never overwrite or shift existing content; only add into free slots or newly
  appended rows.
- Every inserted object must be bottom-anchored and fully inside its grid
  footprint.
- Multiple requested assets = multiple separate generations and insertions.
- The delivered tileset keeps the original format (PNG + alpha) and grows only
  downward (or into proven-free slots).
