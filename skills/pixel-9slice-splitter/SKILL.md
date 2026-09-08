---
name: pixel-9slice-splitter
description: Validate and split generated images into pieces — 9-slice UI panels (corners/edges/center with engine-ready insets), grid spritesheets (8-direction sheets, animation frames, tile sheets, with auto grid detection and per-cell validation), and scattered multi-object images. Use when the user says "9 slice", "nine patch", "split this spritesheet", "cut into frames", "slice this UI panel", "split image into pieces", "this sheet has multiple images, separate them", or needs to break any AI-generated multi-part image into individual assets with validation that the cut lines are correct. Handles empty-cell detection, cut-through-sprite warnings, edge stretchability checks, annotated cut previews, and manifest.json for Unity, Godot, Flame/Bonfire, and Tiled.
---

# 9-Slice / Sheet Splitter with Validation

Split generated images into pieces AND prove the split is correct. One script, four modes:

```bash
python3 scripts/smart_split.py panel.png --mode nineslice --out ./patches --preview cuts.png
python3 scripts/smart_split.py sheet.png --mode grid --cols 8 --rows 2 --out ./frames
python3 scripts/smart_split.py sheet.png --mode auto --out ./pieces      # gutters? grid : scatter
python3 scripts/smart_split.py multi.png --mode scatter --out ./objects
```

Exit code: 0 = clean, 2 = split OK but warnings (read them before delivering), 1 = failed.

## Choosing the mode

| Image looks like | Mode |
|---|---|
| One UI panel/dialog that must resize | `nineslice` |
| Regular rows/columns of frames (8-dir sheet, walk cycle, tiles) | `grid` (auto-detects from transparent gutters, or pass `--cols/--rows`) |
| Objects at arbitrary positions/sizes | `scatter` |
| Unknown | `auto` |

## 9-slice specifics

- Default insets = thirds; override with `--insets L T R B` when the frame border is visible and thinner/thicker.
- The manifest's `engine_hints` maps insets directly: Unity sprite border `[L,B,R,T]`, Godot `NinePatchRect` patch margins, Flame `nineTileBox`.
- Heed the stretchability warning: high-detail edge patches smear when stretched — advise tile-repeat instead, or re-generate the panel with flatter borders.

## Grid specifics

- Auto-detection needs transparent gutters between cells. Packed sheets without gutters need `--cols/--rows` (ask the user or count from the generator that produced it — e.g. 8-direction sheets are 8×1 or 4×2).
- Warnings that matter: EMPTY cell (wrong grid or staggered sheet), content touching all 4 edges on a gutterless sheet (grid cuts through sprites — check the preview), not-divisible dimensions.

## After splitting — ALWAYS validate

1. Read the warnings; fix the cause (wrong cols, wrong insets), not the symptom.
2. Open the `--preview` image: cut lines must run through transparent/flat areas, never through artwork.
3. For animation frames or directions, hand pieces to the pack scripts from pixel-animate-text / pixel-8dir-character — do NOT ship raw cells of varying sizes as a game sheet.
4. Deliver pieces + manifest.json; mention the engine hints when the target engine is known.
