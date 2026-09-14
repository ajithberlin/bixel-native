# Isometric Map Design & Projection Guide

## 1. The 2:1 Diamond Projection

Classic 2D pixel-art games use a 2:1 dimetric/isometric projection (often called 30-degree isometric).
The grid cell is a diamond where the width is twice the height:

```
          (cx, cy)
            /\
           /  \
          /    \
  width  /      \  height = width / 2
         \      /
          \    /
           \  /
            \/
```

Common standard resolutions:
- **16×8**: Extreme retro retro / miniature (Pokemon GBA battle terrain)
- **32×16**: Classic retro isometric (Final Fantasy Tactics, Tactics Ogre)
- **64×32**: Standard modern pixel art RPG / strategy (Age of Empires, SimCity 2000, Diablo)
- **128×64**: HD pixel art / high fidelity

## 2. Whole-Map Canvas Bounds

In an isometric grid with `columns = W` and `rows = H`:
- `pixel_width = (W + H + 1) * tile_width / 2`
- `pixel_height = (W + H) * tile_height / 2`

For a square 20×20 map with 64×32 diamond tiles:
- `pixel_width = (20 + 20 + 1) * 64 / 2 = 41 * 32 = 1,312` pixels
- `pixel_height = (20 + 20) * 32 / 2 = 40 * 16 = 640` pixels

### Viewport Fitting Rule:
To fit an isometric map comfortably into a standard screen (e.g. 1280×720 or 1920×1080):
Run `python3 scripts/iso_designer.py --viewport 1280x720 --tile-size 64x32`
The script balances the diagonal diamond to fit within the viewport framing with proper margins.

## 3. Tall Tiles & Vertical Extrusion

Isometric tiles are often taller than their base diamond footprint:
1. **Flat Ground Tile**: 64×32 (occupies the exact diamond base).
2. **Elevated Block / Wall**: 64×64 (top diamond 32px + 32px vertical front cliff/wall).
3. **Pillar / Tree**: 64×96 (32px diamond base footprint + 64px vertical height).

In Tiled & Bixel:
- Tiles align by bottom-left by default.
- If a sprite is taller than the grid cell diamond, set `tileoffset: (0, -extrusion)` in the tileset properties so the diamond base aligns with the grid floor.
- Use `python3 scripts/iso_designer.py --analyze-image W H --tile-dim 64 32` to inspect vertical extrusion.

## 4. Depth Sorting (Painter's Order)

In isometric projection, rendering order is strictly back-to-front:
- Render order in Tiled: `"right-down"`.
- A cell at `(col, row)` is sorted by its depth key: `col + row`.
- Cells with lower `(col + row)` (North / top) are drawn first.
- Cells with higher `(col + row)` (South / bottom) are drawn later, naturally overlapping the back edges of objects behind them.

## 5. Multi-Layer Hierarchy for Isometric Scenes

1. **`Ground`**: Base diamond floor tiles (grass, water, stone pavement). No vertical extrusion.
2. **`Paths & Transitions`**: Shorelines, dirt paths, carpet runners, decals.
3. **`Elevation / Cliffs`**: Cliff walls, raised plateaus, steps.
4. **`Walls & Buildings`**: Solid structures, interior walls, furniture.
5. **`Overhead / Roofs`**: Roof peaks, upper tree canopy, door lintels (tiles that characters can walk behind).
