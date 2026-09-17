---
name: pixel-game-ui-gen
description: Generate a complete themed pixel-art game UI from a rough layout — a user sketch, wireframe image, or described arrangement of pieces (avatar, health bar, panel, menu buttons, icon buttons, toolbar, tabs, window). All inputs are optional; the skill fills gaps with genre-aware defaults. Use when the user wants "game UI from a layout", "turn this wireframe into pixel UI", "make me a game menu/HUD mockup", "create UI from layout", provides a UI sketch or screenshot of arranged placeholder shapes, or wants a full cohesive screen (not individual elements — that is pixel-ui-elements-gen). Handles layout interpretation, theme/palette selection, AI generation at small canvas with transparent background, slicing into engine-ready components, and a manifest.
---

# Pixel Game UI from Layout

Turn a rough arrangement of placeholder shapes into a cohesive, themed pixel-art UI, then slice it into engine-ready components.

## Inputs (all optional — fill gaps with defaults, ask at most ONE round of questions)

| Input | If missing, default to |
|---|---|
| Layout (sketch / wireframe image / list of pieces) | Classic RPG HUD: circular avatar top-left, health bar top, central panel, right-side vertical menu buttons |
| Theme | Dark-fantasy RPG |
| Color palette | 2 colors from the theme (e.g. "brown and gold") |
| Canvas size | 256×256 (never exceed 512 — AI pixel art degrades) |
| Target engine | None (just PNGs + manifest.json) |

Ask only when BOTH theme and layout are absent; otherwise proceed with defaults.

## Workflow

1. **Normalize the layout.** Convert the user's input into a precise piece list: piece type, position (fraction of canvas), size, and which are interactive. If the user supplies a wireframe image, read positions directly from it and keep them — the layout is the contract, the theme is the variable.
2. **Generate the UI** with the image-generation tool: request PNG output
   with a real transparent background (alpha=0 outside the pieces), 1:1, 1K.
   If the provider cannot return alpha, use a flat `#00FF00` or `#FF00FF`
   fallback and run `pixel-remove-bg` in Python before slicing. Use this
   prompt skeleton:

   > Pixel art game UI sheet, [theme] style, [color1] and [color2] palette. Arranged EXACTLY like this layout: [piece list with positions]. Crisp 1px outlines, flat shading with subtle inner highlight, consistent border radius and border width across all pieces, no text, no letters, no numbers, no shadows outside the pieces, pieces clearly separated from each other, video game UI asset.

   - Always say **no text** — AI renders garbled labels; real text belongs in the engine.
   - "pieces clearly separated" is required for clean slicing (step 4).
3. **Review the result.** Reject and regenerate if: pieces fused together, text/artifacts appeared, piece count wrong, or style inconsistent between pieces. Keep the best of at most 3 attempts.
4. **Slice into components** — run `scripts/slice_ui.py`:

   ```bash
   python3 scripts/slice_ui.py ui.png --out ./components --dilate 4 \
       --names avatar,health_bar,panel,btn_inventory,btn_map,btn_quit,icon_button
   ```

   - `--names` are applied in reading order (top→bottom, left→right); count the printed components and compare with the layout before naming.
   - If a control splits into pieces (icon detached from its button), raise `--dilate`. If two controls merged, lower it.
5. **Upscale for use** (optional): `4x` with nearest-neighbor (`Image.resize((w*4, h*4), Image.NEAREST)`) for crisp modern displays.
6. **Deliver**: component PNGs + `manifest.json` (bboxes, sizes). If an engine is known, note import hints: manifest bboxes map 1:1 to Flame `Sprite` rects / Unity sprite editor / Godot `AtlasTexture`.

## Quality checklist

- [ ] Every piece from the layout exists exactly once
- [ ] Consistent outline width and corner radius across pieces
- [ ] Transparent background (alpha 0 outside pieces)
- [ ] No baked-in text
- [ ] Interactive pieces (buttons) visually distinct from static panels
