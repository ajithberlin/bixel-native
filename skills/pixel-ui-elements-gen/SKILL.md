---
name: pixel-ui-elements-gen
description: Generate individual pixel-art UI elements from a text description — menus, health bars, arrow keys / d-pads, buttons, icons, sliders, inventory slots, dialog boxes — with optional concept image and color palette guidance. Use when the user asks for "a health bar", "arrow keys", "a menu button in pixel style", "UI element", wants button states (normal/hover/pressed/disabled), or needs one-off game controls rather than a full screen layout (that is pixel-game-ui-gen). Handles description-driven prompting, state variants in one sheet, transparent-background output, and slicing variants into separate files.
---

# Pixel UI Elements

Generate single UI elements (or one element in several states) from text.

## Inputs

| Input | Required | Notes |
|---|---|---|
| Description | YES | e.g. "menu, arrow keys and health bar". Vague is fine — enrich it. |
| Concept image | no | Use as style/shape reference for generation. |
| Color palette | no | 2–3 colors ("brown and gold"). Default: pick from the game's theme. |

## Workflow

1. **Enrich the description** into a concrete visual spec: element type, shape, size class (16/24/32/48px feel), border style, shading (flat + 1 inner highlight), palette. Do not ask unless the element type itself is unclear.
2. **Decide states.** Interactive elements need states — generate them in ONE image so style stays identical:
   - Button: `normal, hover, pressed, disabled` in a 4×1 row
   - Health bar: `empty, half, full` + frame in a row (fill segments separately so the fill can animate in-engine)
   - D-pad/arrow keys: 4 directions + pressed variants
   - Static elements (icons, slots): single state is fine
3. **Generate** with the image tool: transparent background, 1:1, 1K. Prompt skeleton:

   > Pixel art game UI element: [spec]. [If states: "N variants in one horizontal row, evenly spaced, identical style: state1, state2, ..."]. [palette] palette, crisp 1px outline, flat shading, no text, no letters, no watermark, clearly separated variants, game asset.

4. **Verify**: all states present, identical style, nothing fused, no text. Regenerate once if failed; on second failure, generate states one per image instead.
5. **Slice variants** — run `scripts/slice_ui.py`:

   ```bash
   python3 scripts/slice_ui.py element.png --out ./out --names normal,hover,pressed,disabled
   ```

   Names apply in reading order (left→right within a row).
6. **Optional consistency pass**: if several elements are generated separately, unify them afterward with a fixed palette via the pixel-reduce-colors skill (same `--palette` for all).

## Prompt cheatsheet (append to description)

- health bar: `horizontal bar with ornate end caps, frame and fill as separate pieces`
- arrow keys / d-pad: `four directional arrow buttons plus center hub, chunky arcade style`
- inventory slot: `square slot with beveled inset center and 2px rim`
- dialog box: `9-slice friendly: flat center, ornate corners, straight edges`
- slider: `horizontal track with notches plus a separate handle piece`

## Rules

- Never bake text into elements — engines render text.
- Keep every element of a set on the same palette and outline width.
- Transparent background always; if the tool returns an opaque flat background, remove it with the pixel-remove-bg skill before slicing.
