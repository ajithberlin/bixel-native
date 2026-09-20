---
name: pixel-spritesheet-gen
description: >
  Generate AI image prompts for game character spritesheets that are actually
  extractable — then score, verify, and pack them into a uniform-grid atlas
  (one transparent PNG + one JSON). Use when the user wants a pixel-art /
  cartoon character spritesheet (idle/walk/run/talk rows or direction rows)
  from Midjourney, DALL-E, Stable Diffusion, or any image generator, for
  Flame/Bonfire, Unity, Godot, etc. Triggers: "generate a spritesheet",
  "prompt for a character sheet", "make sprite frames", "is this spritesheet
  usable", "score my spritesheet", "remove the green screen", "pack frames
  into an atlas". AI sheets are never grid-clean: prompts MINIMIZE extraction
  pain, a script scores each attempt 0-100 (count, identity, motion) with
  corrective reprompt hints so retries keep the best candidate, and two pack
  scripts: chroma_key_pack.py for grid sheets (preserves real alpha or keys
  out chroma fallback,
  normalizes frames into identical cells with aligned pivots, emits one
  atlas PNG + one JSON) and freeform_pack.py for IRREGULAR scattered-layout
  sheets (poses at arbitrary positions, mixed sizes, multi-part sprites
  with props/effects, white or any flat background) — it segments sprites
  by pixel-proximity clustering, crops each to its own pixels, masks out
  neighbors inside overlapping bounding boxes, and center-aligns by
  centroid so animations do not jitter.
  Also triggers on: "extract sprites from this image", "this spritesheet
  is not a grid", "sprites are cropped wrong", "frames contain parts of
  other sprites", "animation jitters / not centered".
  Do NOT use for: hand-made grid-perfect sheets, or scene/tilemap images.
---

# Pixel Spritesheet Generation

Prompt engineering for spritesheets an extractor can survive, a scored
closed-loop verification gate (score → corrective hint → regenerate, keep
the best candidate), and a pack script that turns a verified sheet into an
engine-ready atlas.

Core truth: **an AI spritesheet's value is decided by background, spacing,
and uniformity — not by how pretty the character is.**

## Core Basics (non-negotiable output rules)

Every sheet this skill produces — and every atlas it packs — obeys:

1. **Uniform grid size.** Every frame occupies the exact same cell width and
   height (e.g. 32x32 or 64x64), even when the pose does not fill the box.
   Prompts ask for identical character size; `chroma_key_pack.py` enforces it
   by placing every frame in an identical cell (`--cell` / `--snap 32`).
2. **Consistent pivot points.** Feet (bottom-center) aligned across all
   frames so loops do not bounce or jitter. Prompts say "feet at the bottom
   of each cell"; `sheet_report.py` measures per-row pivot drift; the pack
   step pastes every frame bottom-center into its cell.
3. **Frame padding & bleed.** Zero margins, or a uniform transparent padding
   around every cell (`--padding 1` or `2`), to stop adjacent-pixel bleeding
   when the engine renders with filtering.
4. **Optimal frame count.** Every action MUST end up with 4-8 frames —
   never ship a 3-frame action. 4 frames per row is the per-image AI
   reliability ceiling, so: for a 4-frame action generate ONE 4-frame row;
   for 5-8 frames generate TWO strips (e.g. 4+4) and give both rows the
   SAME action name — `chroma_key_pack.py` concatenates same-named rows,
   in order, into one action.

**Request true alpha for sheets YOU generate.** Every generation prompt must
request a PNG with a fully transparent background (alpha=0 outside each
frame), never a painted checkerboard, shadow, gradient, or vignette. If the
provider cannot return alpha, fall back to one flat exact chroma color — green
`#00FF00` (preferred) or magenta `#FF00FF` — and run the Python key cleanup
before packing. Sheets the user ALREADY HAS may use any near-flat background;
`freeform_pack.py` can sample it from the border.
Do not demand a regeneration just to change the backdrop color on a sheet the
user already has.

## Bundled resources

- `scripts/sheet_report.py` — analyze a generated sheet: background color +
  uniformity, row bands, connected-component frame count per row, frame size
  variance, per-row pivot (feet) drift, edge-touching warnings. Run it on
  every generated sheet BEFORE packing. Tested.
- `scripts/sheet_score.py` — score a sheet 0-100 (ScoreFrames-style: frame
  count vs expectation, contract errors/warnings, 2-axis identity via RGB
  histogram + dHash, motion presence) and emit a `retry hint:` line to paste
  verbatim into the next prompt. Give it several attempts and it names the
  best candidate. Run BEFORE packing; prefer it over eyeballing. Tested.
- `scripts/chroma_key_pack.py` — GRID sheets only: preserve real alpha, or
  remove the chroma-green/magenta fallback (corner-sampled key + tolerance +
  edge despill that protects green clothing), detect each row's frames, normalize them into uniform
  cells with a bottom-center pivot, and pack ALL frames from one or more
  sheets into ONE transparent PNG atlas + ONE JSON (cell size, padding,
  pivot, per-action frame rects). Tested.
- `scripts/freeform_pack.py` — IRREGULAR / scattered-layout sheets (the
  ones chroma_key_pack.py mangles): auto-detects ANY flat background
  (white, green, …) from the border; strips grid/cell divider lines
  (directional opening: only long, thin, axis-aligned runs — thin artwork
  like weapons and speed wisps is untouched); finds sprites as
  pixel-proximity clusters of connected components (a character + its
  floating weapon + its effect cloud fuse into ONE sprite); splits fused
  clusters two ways — tolerance escalation for weakly-blended junctions,
  neck-cut erosion for thin contact points — with nearest-seed grow-back
  so no artwork is lost; content-crops each sprite to its own pixels
  while erasing foreign pixels inside overlapping bounding boxes; and
  packs everything into uniform cells aligned by centroid (jitter-free)
  or bottom pivot. One atlas PNG + one JSON, same JSON shape as
  chroma_key_pack.py plus per-frame source rects. Tested.
  HARD LIMIT it reports instead of hiding: sprites that OVERLAP in the
  artwork itself (drawn on top of each other over wide regions) cannot
  be separated by any pixel method — the script warns and keeps them
  fused; split manually or regenerate with gaps.
- `references/prompt-playbook.md` — copy-paste prompt templates per generator
  (Midjourney / DALL-E / SD) for: 4-direction walk sheets, action grids
  (idle/walk/run/talk), NPC sheets, plus negative prompts and the exact
  phrases that cause extraction-hostile artifacts (labels, borders,
  watermarks, gradient backgrounds).
- `references/extraction-contract.md` — the measurable contract a sheet must
  meet to pack cleanly (bg uniformity delta, min spacing, max size variance,
  pivot drift), mapped to sheet_report.py output fields, with
  fix-by-reprompt guidance for each failure.
- `references/lessons-learned.md` — production-pipeline lessons behind the
  scoring loop: best-candidate selection, measurement-driven retry hints,
  chrominance (YCbCr) matting, projection-profile + DP frame cutting,
  alpha-weighted centroid alignment, shared-palette pixel quantization, and
  the 2-axis identity + motion scoring formula sheet_score.py implements.
  Read when naive keying/detection fails or retries are not converging.

## Workflow

### 1. Decide the sheet layout FIRST
Lock these before writing any prompt — the engine and extractor both depend
on them:
- rows = directions (down/left/right/up) OR actions; column-groups = actions
  (idle/walk/run/talk) with N frames each. Do not mix semantics mid-sheet.
- frames per group: ALWAYS 4 columns per generated image (never 3 — the
  contract is 4-8 frames per action). For 5-8 frame actions, plan two
  strips with the same action name and merge at pack time.
- **row budget: <=4 rows per generation is reliable; >8 rows is a hard
  failure boundary.** For multi-action sets, generate one action (4
  direction rows) per image and assemble the atlas programmatically.
- one character per sheet. Never "various characters".

### 2. Generate with an extraction-friendly prompt
Use `references/prompt-playbook.md`. Non-negotiable clauses:
- "fully transparent background, real alpha=0 outside every frame, no
  checkerboard, no shadow" — preferred
- If alpha is unavailable: "flat solid chroma green background (#00FF00),
  one color, no gradient, no shadow" — then key it in Python before packing.
- "evenly spaced in a strict grid, generous gaps between frames"
- "no text, no labels, no watermark, no border, no frame lines"
- "consistent character size across all frames, feet at bottom of each cell"
Regenerate rather than fix a bad sheet — reprompting is 10x cheaper than
hand-extraction.

### 3. Score BEFORE packing — the closed loop
```bash
python3 scripts/sheet_score.py sheet.png --rows 4 --frames 4 [--tol 45]
# several attempts -> best candidate is named:
python3 scripts/sheet_score.py try1.png try2.png try3.png --rows 4 --frames 4
```
Run the loop, do not eyeball:
1. Score the attempt. A perfect/excellent result (≥ 85) proceeds to packing
   immediately.
2. Below 85: paste the printed `retry hint:` VERBATIM into the next
   generation prompt (it is a precise correction built from the measured
   defects — e.g. "the previous result read as 7 poses but exactly 6 are
   required; split the canvas into 6 even columns…"). Regenerate up to 3x.
3. After 3 attempts, pack the best-scoring candidate — never restart from
   zero and never ship `poor` (< 50). Scoring every attempt and keeping the
   best-so-far converges far faster than re-rolling the dice.

For the full per-field contract detail behind the score, run
`python3 scripts/sheet_report.py sheet.png [--expected-bg 0,255,0]` and read
it against `references/extraction-contract.md`:
- bg spread > 30 or fg coverage > 90% → reprompt (bg clause failed)
- row band count ≠ expected rows → reprompt (spacing clause failed)
- frame height variance > 2.5x → likely text labels or merged frames;
  inspect visually, then reprompt or plan manual cuts
- pivot-drift > ~10% of frame height in a row → feet misaligned; reprompt
  with the feet clause or accept and let the pack step align bottoms
Only proceed to packing when the report is clean or has warnings you accept.

### 4. Pack: pick the packer that matches the sheet's ACTUAL layout

**Decision rule — look at the sheet, not the hope:**

| Sheet looks like… | Use |
|---|---|
| strict rows of similar-size frames on chroma green | `chroma_key_pack.py` (4a) |
| poses scattered at arbitrary positions, mixed sizes, white/other flat bg, sprites with detached parts (weapons, clouds, effects), bounding boxes that would overlap | `freeform_pack.py` (4b) |

Never force a scattered sheet through the grid packer: row-band slicing
crops sprites mid-body, pulls neighbors into frames, and misaligns pivots.
When in doubt, run `freeform_pack.py --actions auto` first and inspect the
printed sprite count against what you see.

#### 4a. Grid sheets -> chroma_key_pack.py
```bash
python3 scripts/chroma_key_pack.py sheet.png \
    --actions "walk_down,walk_left,walk_right,walk_up" \
    --out-image atlas.png --out-json atlas.json [--padding 1] [--snap 32]

# merge several sheets into one atlas (';' separates sheets):
python3 scripts/chroma_key_pack.py walk.png gestures_a.png gestures_b.png \
    --actions "walk_down,walk_left,walk_right,walk_up;idle,open_map,close_map;think,thanks,bye" \
    --out-image atlas.png --out-json atlas.json

# 8-frame actions: two 4-frame strips, SAME action names -> concatenated:
python3 scripts/chroma_key_pack.py walk_a.png walk_b.png \
    --actions "walk_down,walk_left,walk_right,walk_up;walk_down,walk_left,walk_right,walk_up" \
    --out-image atlas.png --out-json atlas.json
```
- Action names are given in row order, one comma-list per input sheet; the
  script errors if a sheet's detected row count differs from its name list —
  a mismatch means the sheet failed the contract, go back to step 2.
- Repeating an action name (within or across sheets) merges those rows'
  frames in order — this is the supported way to reach 5-8 frames.
- The JSON records cell size, padding, pivot (0.5, 1.0 = bottom-center) and
  per-action frame rects; engines slice the atlas by cell directly.
- Default padding is 0 (zero margins). Use `--padding 1` or `2` when the
  target engine renders with linear filtering (prevents bleeding).
- Use `--snap 32` (or `--cell 64x64`) to force classic power-of-two cells.

#### 4b. Irregular / scattered sheets -> freeform_pack.py
```bash
# every sprite on the sheet -> one action, reading order (start here):
python3 scripts/freeform_pack.py sheet.png --actions auto \
    --out-image atlas.png --out-json atlas.json --padding 2

# named rows: one name per detected VISUAL row (top-to-bottom);
# repeat a name to merge rows into one action:
python3 scripts/freeform_pack.py poses.png --actions "fly,fly,land" \
    --out-image atlas.png --out-json atlas.json

# several sheets -> ONE atlas (';' separates sheets, same as 4a):
python3 scripts/freeform_pack.py fly_a.png fly_b.png \
    --actions "auto;auto" --out-image atlas.png --out-json atlas.json
```
- **Background uses alpha when present; otherwise it is auto-detected from the
  border** — white, chroma green, or any near-flat color works; `--key R,G,B`
  overrides, `--tol` widens it.
- **Grid/cell divider lines are stripped automatically** (`--strip-lines`,
  auto on). Without this they key out as foreground and fuse the whole
  sheet into one cluster. Only long thin axis-aligned runs are removed —
  weapons, wisps, and other thin art survive.
- **Fused sprites are auto-split** (`--split-factor 3.0`): clusters far
  bigger than the median sprite are first re-keyed at escalating tolerance
  (cuts weak blended junctions), then neck-cut by progressive erosion
  (cuts thin contact points); parts grow back over the full cluster pixels,
  so no art is lost. Sprites that OVERLAP in the artwork (drawn over each
  other) cannot be split by pixels — the script prints a WARN and keeps
  them fused; crop those by hand or regenerate with gaps.
- **Sprites are pixel-proximity clusters, not grid cells.** Detached parts
  of one sprite (floating staff, effect cloud) fuse via the `--merge`
  bridge radius (default auto = 0.8% of the short side):
  - sprite SPLIT into pieces (part became its own frame) → raise `--merge`
  - two NEIGHBORS fused (WARN: sprite Nx the median area) → lower `--merge`
- **Crops follow the artwork.** Each sprite is cropped to its own pixels;
  when bounding boxes overlap, pixels belonging to other sprites inside
  the box are erased — neighbors can never bleed into a frame.
- **Pivot kills the jitter.** Default `--pivot centroid` aligns the
  alpha-weighted center of mass of every frame to the cell center — the
  object stays steady even when poses sprawl differently. Use
  `--pivot bottom` for standing characters (feet on cell bottom),
  `--pivot center` for strict bbox centering.
- `--edge-trim 1` (default) erodes sprite edges 1 px to remove white halo
  on light backgrounds; set `--edge-trim 0` for hard-pixel art.
- `--cell` / `--snap` / `--padding` behave exactly as in 4a. The JSON adds
  `"layout": "freeform"` and a per-frame `source` rect pointing back into
  the original sheet.
- Verification: sprite count printed must equal what you see; visually
  scan the atlas for one whole sprite per cell, no foreign fragments,
  and steady alignment across frames.

## Troubleshooting: the three irregular-sheet symptoms

| Symptom | Cause in grid packers | Fix in freeform_pack.py |
|---|---|---|
| Not cropped based on the image | fixed row bands / cells guessed from projections | content crop to each sprite's own pixels; uniform cell = max sprite size |
| Frame contains pieces of another sprite | bounding-box slicing grabs whatever overlaps the rectangle | component-level ownership: only this sprite's pixels survive the crop |
| Animation glitches / object not centered | bottom-center paste of inconsistently cropped boxes | `--pivot centroid` (default) pins the object's mass to the cell center; trim + uniform cells keep every frame consistent |

## Quality bar
- Sheet scores ≥ 85 (excellent) on sheet_score.py — or 70-84 (good) with
  warnings you explicitly accept. Never ship poor (< 50); if 3 attempts
  stay poor, change the prompt/layout, don't keep re-rolling.
- Sheet passes sheet_report.py with bg spread < 30, one band per row, and
  pivot drift within tolerance.
- Identity holds: dHash similarity ≥ 0.55 and histogram similarity ≥ 0.5
  across consecutive frames (sheet_score.py reports both), and every row
  shows real motion (no near-identical frames posing as animation).
- Frame count per row matches the design (or is fixable with --tol), and
  every packed action ends with 4-8 frames — regenerate or strip-merge,
  never ship 3.
- No text labels, watermarks, or coordinate borders anywhere on the sheet.
- Character identical across frames (same outfit/colors) — check visually.
- Atlas: every cell identical size, feet aligned to cell bottoms, background
  fully transparent, no green fringe on sprite edges.
