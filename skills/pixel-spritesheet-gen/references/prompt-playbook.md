# Prompt Playbook — Extraction-Friendly Spritesheets

Every template below encodes the non-negotiables: flat chroma-green bg
(ALWAYS chroma green — never dark, never white), strict grid with gaps, no
text/borders, uniform character size, feet pinned to cell bottoms. Replace
only the [CHARACTER] and layout slots.

## Contents
- Universal clauses
- 4-direction walk sheet (RPG)
- Action grid (idle/walk/run/talk x directions)
- Single-action strip
- NPC / villager sheet
- Per-generator notes (Midjourney, DALL-E, SD)
- Phrases that BREAK extraction (never use)
- Repair prompts (when the first try fails)

## Universal clauses (append to every prompt)

```
flat solid chroma green background (#00FF00), single uniform background
color, no gradient, no drop shadow, strict uniform grid layout, evenly
spaced frames with generous gaps, identical character size in every frame,
full body visible, feet at the bottom of each cell, true pixel art, limited
color palette (16-32 colors), crisp 1-pixel outline, hard pixel edges, no
anti-aliasing, no shading gradients, no text, no labels, no captions, no
watermark, no signature, no border, no frame lines, no grid lines drawn
```

Note: a green character (green cloak, slime, etc.) still works — the pack
script keys on the corner-sampled background with edge-only despill, which
protects green clothing; just keep the character's green clearly darker or
lighter than pure #00FF00.

## 4-direction walk sheet (top-down RPG)

```
character spritesheet for a 2D top-down RPG, [CHARACTER], 4 rows x 4 columns:
row 1 walking down (front view, 4 walk phases), row 2 walking left
(side view), row 3 walking right (side view), row 4 walking up (back view),
each frame the same character mid-stride, + UNIVERSAL CLAUSES
```

[CHARACTER] example: "a young woman with a teal jacket and brown backpack,
chibi proportions, simple cute design"

## Action grid (idle/walk/run/talk x 4 directions)

**Row budget (read this before choosing a layout):**
- <= 4 rows per generation: reliable
- 5-8 rows: expect some grid drift; check with sheet_report.py
- \> 8 rows: do NOT plan around it — generate by parts

**Frame budget (hard rule):** every action ships with 4-8 keyframes —
3-frame actions are NOT acceptable. 4 frames per row is the per-image AI
reliability ceiling, so:
- 4-frame action: one image, 4 columns per row.
- 5-8 frame action: generate TWO strips (e.g. 4+4 or 4+3, different poses /
  later phases of the same motion) and merge them by giving both rows the
  SAME action name in one `chroma_key_pack.py` call — the packer
  concatenates same-named rows in order.

The safe pattern is ONE ACTION PER IMAGE (4 direction rows), or even one
direction strip per image, then assemble programmatically. A re-rolled
4-row sheet is far cheaper than salvaging a drifted 12-row one.

```
character animation spritesheet, [CHARACTER], 4 rows in a strict grid:
facing down, left, right, up — one row each — all performing [ACTION],
4 frames per row, + UNIVERSAL CLAUSES
```

Repeat per action (idle, walk, run, talk) with the SAME [CHARACTER]
description verbatim, then assemble the sheet by stacking rows (extraction
tools expect a uniform grid; assembling from 4-row pieces is deterministic,
generating 16 rows at once is not). For 5-8 frames per action, generate a
SECOND image per action ("same action, later phases, different frames")
and strip-merge at pack time. 16 rows is the hard failure boundary —
never the plan.

## Single-action strip

```
sprite animation strip, [CHARACTER], one horizontal row of 4 frames showing
[ACTION] in smooth progression, side view, + UNIVERSAL CLAUSES
```

## NPC / villager sheet

```
NPC character spritesheet for a cozy pixel game, [NPC DESCRIPTION], 4 rows
x 4 columns, directions down/left/right/up, simple idle sway animation,
+ UNIVERSAL CLAUSES
```

Keep NPCs simple (2-3 colors, few accessories) — they tile better and stay
on-model across frames.

## Per-generator notes

- **Midjourney**: add `--no text, labels, watermark, border, gradient
  background` and `--style raw`. Aspect: `--ar 4:3` for 4x3 grids, `--ar 1:1`
  for square grids. Avoid `--stylize` above 250 (drifts off-grid).
- **DALL-E 3**: it loves adding captions — repeat "no text anywhere in the
  image" at the END of the prompt. It may also soften the green; the pack
  script corner-samples the actual green, so a near-chroma green is fine as
  long as sheet_report.py shows corner-spread < 30. Ask for exactly
  1024x1024 or 1792x1024.
- **Stable Diffusion**: put the universal clauses in the prompt AND
  "text, watermark, logo, border, jpeg artifacts, gradient background,
  drop shadow" in the negative prompt. Use a pixel-art LoRA if available;
  CFG 6-8; avoid highres-fix upscalers that blur pixel edges.

## Phrases that BREAK extraction (never use)

- "sprite sheet with labels" / "annotated" — text labels everywhere
- "concept art sheet" / "character reference sheet" — adds name plates,
  color swatches, multiple poses at different scales
- "dynamic lighting" / "dramatic shadow" — gradient bg, cast shadows that
  merge with frames
- "various poses" — non-uniform frame sizes
- "white background" or "dark background" — the standard is ALWAYS flat
  chroma green (#00FF00); white keys out near-white character parts, dark
  keys out dark outlines, and both break the pack script's expectations
- any language text request ("with hiragana labels") — obviously
- "detailed shading" / "smooth gradients" / "painterly" — soft edges and
  thousands of colors; keys badly and isn't pixel art

## Repair prompts (first try failed)

- bg not uniform → "regenerate with a perfectly flat solid chroma green
  #00FF00 background, no lighting effects"
- frames touching → "increase the spacing between frames, each frame fully
  separated by empty background"
- size drift → "every frame exactly the same character height, aligned to a
  strict invisible grid"
- feet bouncing between frames → "feet planted at the exact same bottom
  line in every frame, no vertical offset"
- labels appeared → "remove ALL text, numbers and letters from the image"
