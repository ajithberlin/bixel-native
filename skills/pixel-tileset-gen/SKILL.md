---
name: pixel-tileset-gen
description: Generate seamless pixel-art tilesets in three modes — Top-Down (lower/transition/higher elevation tiles with edge shape, roundness, raggedness, side-wall controls), Sidescroller (platform tiles with grass top cap and stone/dirt center, top-cap depth and raggedness), and Pro (full Wang autotiling blob for terrain transitions between an upper and lower terrain). Use when the user wants "a tileset", "grass-to-water transition tiles", "platform tiles", "Wang tiles", "autotile", "top-down terrain tiles", or "sidescroller platform tileset". Handles terrain description writing, parameter-to-prompt mapping, seamlessness verification, seam repair, and slicing into individual tiles.
---

# Pixel Tileset Generator

Three modes. Pick from the user's words: "top-down / terrain / elevation" → Top-Down · "platform / sidescroller / jump-and-run" → Sidescroller · "Wang / autotile / full transitions" → Pro.

## Shared rules

- Tile size: 16×16 (retro), 32×32 (default), or 48/64 (HD). Smaller = more cohesive AI output.
- Always generate the WHOLE tileset as ONE image — per-tile generation never matches at the edges.
- Descriptions must state texture, not objects: "lush grassy field with varied green blades" ✓, "a meadow with a tree" ✗ (objects break tiling).
- No shadows cast across tile borders; lighting must be uniform (top-lit, noon).

## Mode 1 — Top-Down (elevation tiles)

Needs 2–3 textures: **higher elevation** (e.g. grass), **lower elevation** (e.g. water), optional **transition** (e.g. dirt cliff wall). Parameter → prompt mapping:

| Parameter | Prompt language |
|---|---|
| Transition size (0–100) | narrow/wide transition band between the two terrains |
| Edge shape: Round | smooth organic rounded coastline/edge |
| Edge shape: Square | angular blocky edge, straight segments |
| Roundness (0–100) | how curved the terrain boundary is |
| Raggedness (0–100) | noise/jitter along the boundary |
| Side wall thickness / placement | visible cliff face below the higher tile, offset outward |

Prompt skeleton:

> Seamless top-down pixel art terrain tiles, orthographic view: [higher description] on top, [lower description] below, joined by [transition description], [edge words]. Uniform top-down lighting, no objects, no shadows across edges, tileable texture, [tile]-pixel grid feel, no text.

## Mode 2 — Sidescroller (platform tiles)

Two textures: **top cap** (e.g. grass tufts) and **center/body** (e.g. mossy weathered bricks). Parameters: top cap depth (% of tile height), roundness, raggedness, auto platform thickness (let the generator choose a natural platform height).

> Seamless sidescroller platform tileset, side view: [top description] capping a [center description] platform, top cap [shallow/deep], edges [rounded/rugged], flat uniform lighting, tileable horizontally, pixel art, no background, no text.

## Mode 3 — Pro (Wang autotile blob)

A single blob image containing every edge combination of two terrains. Needs: **upper terrain**, **lower terrain**, **transition description** ("rocks, wet sand"), transition size (0–100), tile size.

> Full Wang autotiling pixel art tileset, one image containing all edge combinations transitioning from [upper terrain] (interior) to [lower terrain] (exterior) through [transition description]. Grid-aligned [tile]x[tile] tiles, every tile edge continuous with its neighbors, uniform lighting, no objects, no text.

## Verify and slice (mandatory)

```bash
python3 scripts/verify_wang.py blob.png --tile 32 --annotated seams.png \
    --report seams.json --tiles ./tiles
```

- Exit 0 + "seams ok 100%" → deliver `./tiles/` + the master blob.
- Bad seams → open the annotated PNG: red lines mark failures. Fixes, in order:
  1. **Regenerate** with "every tile edge continuous, no hard grid lines" added.
  2. **Mirror-blend repair**: for each bad vertical seam, average the 2px columns on both sides; same for horizontal (do it with numpy, preserve palette).
  3. If >30% of seams fail, the blob is unusable — regenerate; do not ship it.

## Delivery

Master PNG + sliced tiles + `seams.json` + (if engine known) a note that tiles map row-major, gid = row*cols + col + 1 for Tiled.
