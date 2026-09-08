---
name: pixel-ui-kit-gen
description: >
  Generate complete, consistent 2D pixel-art game UI component sets from a
  theme — batch-first to cut cost: each AI image is a sheet of related states
  or same-size items, split by script into separate game-ready assets on exact
  32x32-multiple canvases with a pure magenta (#FF00FF) background, plus a
  structured manifest. Use when the user wants a game UI kit, HUD components,
  button states, skill-tree nodes/connectors, inventory slots,
  quest/log/dialog panels, bars, badges, navigation or layout containers for
  Godot, Unity, Flame/Bonfire or web engines. Triggers: "generate a UI kit",
  "pixel art UI components", "make button states", "skill tree node assets",
  "inventory slot set", "game menu assets", "RPG UI pack". Core loop: anchor
  once, one sheet per family, split + normalize (32-multiples, #FF00FF,
  opaque), batch-verify, manifest.
  Do NOT use for: character spritesheets (pixel-spritesheet-gen),
  scene/tilemap images (tilemap-reference-gen / tilemap-blocks-gen), or
  combined mockups and full game screens.
---

# Pixel UI Kit Generation

Batch-first generation of full pixel-art UI component sets: AI images are
multi-item SHEETS, scripts do the cutting and normalization, and every final
asset is one component+state on an exact engine-ready canvas.

Core truth: **a UI kit is a system, not a pile of images — and it is built in
sheets, not singles. One style anchor, one canvas size per sheet, scripts do
the cutting; consistency and cost are decided before the first prompt.**

## Core Basics (non-negotiable output rules)

Every asset this skill ships obeys:

1. **One component or one state per FINAL asset.** Never ship a sprite sheet,
   mockup, or full screen. Generation is BATCHED — one AI image holds a row of
   states of one component, or a grid of same-size items — and
   `split_group.py` cuts every sheet into separate files before normalization.
2. **32x32 tile grid.** Every final canvas is exactly 32x32 or a multiple
   (64x32, 96x96, 192x128...). All states of one component share the identical
   canvas; one batch sheet = one canvas size.
3. **Pure magenta background, exactly #FF00FF, fully opaque.** No transparency,
   no gradients, no shadows cast on the background. The theme palette must not
   contain magenta/pink hues near the key color.
4. **Crisp pixels only.** No blur, no anti-aliasing, no soft shadows, no
   semi-transparent pixels.
5. **Centered and fully visible.** Identical alignment, proportions and >= 2px
   pure-background padding across all related states; never crop outlines,
   corners, or highlights.
6. **No text.** No letters, numbers, labels, fonts, watermarks. Text-bearing
   components are EMPTY visual containers with clean text-safe interiors.
   Glyphs that are part of a control (+, -, chevrons, padlocks, checkmarks)
   are drawn shapes.
7. **Clear identity.** Files are named `{component}_{state}.png` in category
   folders (`buttons/button_primary_hover.png`); the manifest records the rest.

## Cost discipline (batch-first — this is the point of the skill)

- **One sheet per family, never one image per state.** A 60-asset kit is
  ~5-8 generation calls, not 60.
- **Sheet budget: max 5 columns x 4 rows** (12-16 items). Beyond that, AI
  layouts drift and splits fail. One canvas size per sheet.
- **Reuse the style block VERBATIM** across sheets; only the item-list clause
  changes. The anchor sheet doubles as the reference image for all later
  sheets — no separate anchor render.
- **Display each SHEET to the user at most once** (or only failures) — never
  display every component file. Verification is by script, not eyeball.
- **Run every script in batch mode**: one split command per sheet, one
  normalize command per batch (folder mode), one verify + one manifest command
  per kit.

## Bundled resources

- `references/component-catalog.md` — the full component menu by category
  (input controls, feedback, overlays, navigation, layout, and the RPG kit:
  skill tree, movement, action, inventory, quest, resources, map) with
  applicable states, default canvas sizes, batch-planning hints, and
  nine-slice/tiling notes. Read when planning any set.
- `references/prompt-playbook.md` — the style-block/contract template, the
  three batch-sheet templates (state row, family grid, family sheet),
  state-phrasing cheat-sheet, and failure-to-reprompt fixes. Read before
  writing any prompt.
- `scripts/split_group.py` — cut a batch sheet into separate raw crops:
  single row, column, or N x M grid, named via `--names` (reading order) or
  `--rows`+`--states` (grid naming `{row}_{state}.png`), with `--grid CxR`
  layout assertion. Refuses to cut a broken sheet (mismatch = reprompt).
- `scripts/normalize_component.py` — one file or a whole folder: flatten
  alpha, key magenta, crop, NEAREST-resize into an exact multiple-of-32 canvas
  with uniform padding, snap near-magenta to EXACT #FF00FF, save opaque RGB.
- `scripts/verify_set.py` — batch-check finals: multiple-of-32 size, exact
  magenta corners, opaque, snake_case names, edge-touch, bg bleed, scattered
  fragments, off-center, palette noise. FAILs print reprompt hints.
- `scripts/build_manifest.py` — scan the verified folder -> manifest.json +
  manifest.csv (component, category, state, dimensions, suggested filename,
  nine-slice, recommended padding, none/stretch/tiling).

## Workflow

### 0. Lock the theme with the anchor sheet
Turn the theme into a fixed style block: palette of 6-10 named colors (no
magenta), outline color + width, lighting direction, shading rule. The FIRST
generation is the anchor: a state row of the primary button family (e.g.
default/hover/pressed/focused/disabled in one row). Split, normalize, verify —
then use that SHEET as the `--reference-image` for every later sheet (via
`image-to-url`). No separate anchor render, no re-invented style.

### 1. Plan the set AND the sheets
From `references/component-catalog.md`, build two lists: the asset list
(component, state, canvas) and the batch plan (which items share each sheet,
one canvas size + one ratio per sheet). Use the three batch patterns:
- **STATE ROW** — one component x all its states, one row.
- **FAMILY GRID** — same-size stateless items (markers, icon buttons, dots).
- **FAMILY SHEET** — same-size family sharing a state set; rows = components,
  columns = states (button families, slot variants, d-pad directions).
Generate ONLY logically applicable states. Name every target
`{component}_{state}.png` up front.

### 2. Generate sheets via the image_generation plugin
One sheet per call, using the matching batch template from
`references/prompt-playbook.md` (style block verbatim + item-list clause +
contract clause). Always `background: opaque`, `.png`, anchor sheet as
reference image. Ratio by sheet shape: row -> `3:2` (or `16:9` 2K for 5+
items), grid -> `1:1` or `3:2`, column -> `2:3`.
**Singles are the exception path**: only for an item that failed twice inside
sheets, or a one-off oversized panel that fits no batch.

### 3. Split every sheet
```bash
# state row or item grid (names in reading order):
python3 scripts/split_group.py raw/btn_primary_states.png raw/split \
    --names "button_primary_default,button_primary_hover,button_primary_pressed,button_primary_focused,button_primary_disabled"
# family sheet (rows = components, cols = states):
python3 scripts/split_group.py raw/button_families.png raw/split --grid 3x3 \
    --rows "button_primary,button_secondary,button_toggle" \
    --states "default,hover,pressed"
```
A band mismatch means the sheet broke the contract (items touching, uneven
gaps) — reprompt the sheet with wider even gaps; never hand-cut.

### 4. Normalize in batch (folder mode)
```bash
python3 scripts/normalize_component.py raw/split/ assets/buttons/ --size 96x32 --pad 2
```
One command per batch, one canvas size per batch. Use `--colors N` if the set
needs a shared quantized palette. Normalization fixes geometry, not style —
regenerate rather than hand-fix.

### 5. Verify the set — the closed loop
```bash
python3 scripts/verify_set.py assets/
```
FAIL -> apply the printed reprompt hint, regenerate the affected SHEET (the
single only if that item already failed twice), re-split, renormalize. WARN ->
accept (documented) or reprompt. Never ship FAILs.

### 6. Emit the manifest
```bash
python3 scripts/build_manifest.py assets/ --out-json manifest.json \
    --out-csv manifest.csv --theme "<theme name>"
```
Per asset: component, category, state, dimensions, suggested filename,
nine-slice compatibility, recommended padding, tile/stretch/repeat
(`--overrides overrides.json` for exceptions). Deliver `assets/` + manifest.

## Quality bar
- Every final image: multiple-of-32 canvas, exact #FF00FF at all corners,
  fully opaque, snake_case name, >= 2px background padding, verify_set.py
  clean (no FAIL).
- Every shipped asset traces to a script-split, normalized crop — no unsplit
  multi-component image is ever delivered.
- Sheets respect the budget: <= 5 columns x 4 rows, one canvas size each,
  anchor-referenced style.
- All states of a component: identical canvas, position, and proportions —
  only the state attribute changes.
- One palette across the whole set; no magenta-family color in the art.
- Empty text-safe interiors on all text-bearing containers; zero text,
  letters, numbers, or watermarks anywhere.
- Skill-tree set: all nodes one canvas size; connectors align to node-edge
  midpoints at constant stroke width — the 100-level tree assembles without
  custom fixes.
- Manifest lists every shipped file with nine-slice, padding, and
  tile/stretch/repeat metadata.
