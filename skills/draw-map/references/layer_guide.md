# Multi-Layer Scene Architecture Guide

Bixel Studio tilemaps follow standard 2D game engine multi-layer conventions. Stamping content into distinct semantic layers ensures clean rendering, easy updates, depth sorting, and game-engine export parity.

## Standard Layer Hierarchy

| Layer Order | Standard Name | Content & Purpose | Transparency Rule |
|---|---|---|---|
| **0 (Bottom)** | `Ground` | Continuous terrain (grass, water, stone, sand). No holes. | 100% opaque |
| **1** | `Decor` / `Paths` | Dirt paths, cobblestone borders, flowers, shorelines, carpets. | Transparent background (`skip_empty: true`) |
| **2** | `Structures` / `Walls` | Buildings, fences, cliff faces, furniture, tree trunks. | Transparent background (`skip_empty: true`) |
| **3 (Top)** | `Overhead` / `Roofs` | Roof tops, upper tree canopies, door lintels (drawn above characters). | Transparent background (`skip_empty: true`) |
| **Special** | `Collision` | Optional non-rendered layer marking solid/passable tiles. | Usually hidden in game export |

## Stamping Rules

1. **Always Set `skip_empty: true` on Detail/Structure Layers**:
   When stamping a multi-tile structure (e.g. a 3×4 house or tree) onto `Structures`, empty cells (`0`) must not erase underlying ground or wall tiles on that layer.
2. **Direct Layer Stamping**:
   - In Bixel Studio, `map_stamp` accepts an explicit `layer: <index_or_name>` target.
   - Always target the appropriate semantic layer:
     - Ground fills -> `Ground`
     - Trees, houses, rocks -> `Structures`
     - Overhangs, roofs -> `Overhead`
3. **Non-Destructive Scene Updates**:
   - When asked to add elements to an existing scene (e.g. "add a campfire in the clearing"):
     1. Inspect existing layers using `scripts/inspect_map.py` to identify occupied coordinates.
     2. Choose an empty or suitable area on the target layer.
     3. Stamp only the new structure without clearing existing tiles.
