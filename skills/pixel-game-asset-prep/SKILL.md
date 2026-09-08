---
name: pixel-game-asset-prep
description: >
  Convert AI-generated images into game-ready 2D assets: character spritesheets
  (idle/walk/run/talk x 4 directions) and top-down pixel-art scene maps. Use
  whenever a user provides AI-generated spritesheets or map images (Midjourney,
  DALL-E, Stable Diffusion, etc.) and wants them turned into usable game assets
  for Flame/Bonfire, Unity, Godot, or any 2D engine. Triggers: "use this
  spritesheet", "convert this pixel map", "build animations from this sheet",
  "make this image a game map", uploading character sheets or top-down RPG maps.
  Handles the messy reality of AI images: non-uniform frame grids, embedded
  text labels, coordinate borders, watermarks, near-uniform backgrounds, and
  chroma-green shadow placeholders that need converting to soft drop shadows.
  Do NOT use for: hand-drawn pixel-perfect tilesets already on a strict grid
  (slice directly), or 3D assets.
---

# Pixel Game Asset Prep

Turn AI-generated spritesheets and scene maps into engine-ready assets.
Core truth: **AI images are never on a clean grid — inspect and segment, never assume.**

## Bundled resources

- `scripts/extract_spritesheet.py` — segment an AI spritesheet (bg keying, band
  detection, connected components) and repack frames into a uniform transparent
  sheet + JSON manifest. Tested; run it rather than rewriting the logic.
- `scripts/crop_map.py` — strip black coordinate-label borders and corner
  watermarks from AI map images.
- `scripts/make_tiled_json.py` — turn a full-scene PNG into a Tiled v1.10 JSON
  ("single giant tile" trick) with collision/door/spawn/npc object layers.
- `scripts/green_to_shadow_v2.py` — convert a chroma-green shadow placeholder
  (any shade/variant of green, detected by hue not exact RGB) into a soft,
  semi-transparent drop shadow. Reads the green's brightness gradient to drive
  shadow alpha (darker green = more opaque shadow, lighter green near the rim
  = fades to transparent). Prefer this over the older `green_to_shadow.py`.
- `references/ai-image-pitfalls.md` — what to look for when inspecting AI game
  images (read before extracting anything).
- `references/engine-wiring.md` — how to consume the outputs in Flame/Bonfire
  (animation grid math, map loading, collision import) incl. the path-layout
  bug that renders an invisible "void" map.

## Workflow

### 1. Inspect first (always)
Open the image. Determine: sheet type (character sheet vs scene map), background
color (sample corners), text artifacts (labels like IDLE/WALK/DOWN, coordinate
numbers, watermarks), and rough layout (rows x column-groups x frames). Read
`references/ai-image-pitfalls.md` for the full checklist. For spritesheets,
identify row semantics (usually directions: down/left/right/up) and column-group
semantics (usually actions: idle/walk/run/talk) from the on-sheet labels.

### 2a. Spritesheet -> uniform sheet
```bash
python3 scripts/extract_spritesheet.py sheet.png \
  --out-sheet player.png --out-manifest player_manifest.json \
  --row-names down,left,right,up --group-names idle,walk,run,talk --frames-per-group 3
```
Verify: every cell reports the expected frame count (warnings mean detection
issues — adjust --tol or --min-sprite-h); visually spot-check the output on a
gray background. The manifest records cell size + group layout for the engine.

### 2b. Scene map -> clean map PNG
```bash
python3 scripts/crop_map.py raw_map.png map_zone.png [--crop-left N --crop-bottom N]
```
Record the output pixel size — every downstream coordinate depends on it.

### 2c. Chroma-green shadow placeholder -> soft shadow
When a re-generated/updated sprite or map image encodes character/object
shadows as a flat or gradiented chroma-green blob (any green variant — bright
chroma key, dark olive, pale anti-aliased edges), convert it before anything
else touches the image:
```bash
python3 skills/pixel-game-asset-prep/scripts/green_to_shadow_v2.py in.png out.png
```
Detection is hue-based (not exact RGB match) so it survives AI regen drift in
the exact green shade. Run this pass first — spritesheet extraction and map
cropping should operate on the shadow-corrected PNG, not the raw green one.
Spot-check the output on a mid-gray background: the shadow should look soft
and near-black/transparent at the rim, with no green fringe remaining.

### 3. Map -> playable zone
Define collisions/doors/spawns/NPCs as NORMALIZED (0..1) rects in a config
JSON (estimate from the labeled original image), then:
```bash
python3 scripts/make_tiled_json.py --name zone --image tiles/map_zone.png \
  --config zone_config.json --out tiles/zone.json
```
Rules that prevent shipped bugs:
- JSON and PNG must sit in the SAME directory under the engine image root; the
  tileset image must be a bare filename (no `..` — that renders a void map).
- Spawn feet must not overlap door sensor rects (instant zone bounce).
- Keep collision rects only in the JSON (single place to tune; ±5% is fine).

### 4. Wire into the engine
Follow `references/engine-wiring.md`: exact `SpriteAnimationData.sequenced`
grid math from the manifest, Bonfire `WorldMapReader.fromAsset` layout rules,
and the objectgroup-based collision approach (do NOT rely on the engine's
auto collision import).

## Quality bar
- Output spritesheet: uniform cells, transparent bg, feet bottom-anchored,
  frame order left-to-right matches animation playback order.
- Manifest matches the sheet (cell size x grid = sheet size exactly).
- Map JSON validates as JSON and loads in the engine with visible background,
  working collisions, and one-way door transitions.
