# Prompt Playbook

Batch-first prompting: every AI image is a SHEET of related items (a row of
states or a grid of same-size components), cut apart by `split_group.py`.
Singles are the fallback, not the default.

## The one rule of consistency

Build ONE anchor sheet first (a state row of the primary button family),
split/verify it, then reuse it two ways for every later sheet:

1. Pass it as a reference image (`image-to-url` → `--reference-image`).
2. Repeat the STYLE BLOCK verbatim in every prompt — swap only the ITEM-LIST
   clause.

If the set drifts mid-run, stop and re-anchor; do not keep re-rolling.

## Prompt anatomy (every sheet)

```
[STYLE BLOCK — identical for the whole kit]
2D pixel-art game UI for a [THEME] game, [palette description, e.g. "indigo
night-market palette: deep navy panels, warm amber accents, cream highlights,
dark plum outlines"]. Chunky crisp pixels with hard nearest-neighbor edges, no
anti-aliasing, no blur, no soft shadows, no semi-transparent pixels. Dark 2px
outline, top-left lighting, flat 2-tone shading. Retro 16-bit handheld RPG UI
style.

[ITEM-LIST CLAUSE — one of the three batch templates below]

[CONTRACT CLAUSE — always verbatim]
Flat solid pure magenta background (#FF00FF), one uniform color, no gradient,
no vignette, no shadows cast onto the background. Generous even gaps of empty
background between all items — nothing touches anything else, nothing touches
the image edges. No text, no letters, no numbers, no labels, no placeholder
scribbles, no watermark, no border frame around the image. All interior text
areas are left completely empty.
```

Palette rule: NEVER put magenta/pink near #FF00FF in the theme palette — the
normalizer snaps near-magenta pixels to background and would eat the art.

## Batch template A — STATE ROW (one component, all its states)

The workhorse. One row, 3-5 states of the SAME component:

```
A horizontal row of 5 identical [component, e.g. "rectangular raised primary
buttons"], same size, aligned on one baseline, evenly spaced. From left to
right: DEFAULT — plain resting face; HOVER — brighter rim highlight along the
top edge; PRESSED — face shifted 2px lower, darker tones; FOCUSED — dotted
inner outline one pixel inside the border; DISABLED — desaturated gray tones.
```

Split with `--names "cmp_default,cmp_hover,cmp_pressed,cmp_focused,cmp_disabled"`.

## Batch template B — FAMILY GRID (same-size stateless items)

For markers, icon buttons, dots, badges, frames — one grid, up to 4x4:

```
A 4x2 grid of pixel-art UI icon buttons, all the same size and style, aligned
in even rows and columns. Row 1: back arrow, X close, house home, hamburger
menu. Row 2: left chevron, right chevron, magnifier zoom-in, expand arrows.
Each icon is a drawn shape, centered in its own identical button face.
```

Split with `--names` in reading order. Same rule for a grid of map markers,
pagination dots, or resource icon frames.

## Batch template C — FAMILY SHEET (rows = components, columns = states)

The highest-density pattern — a whole family in ONE image (max 5 cols x 4
rows; every cell the SAME canvas size and state set):

```
A 3x3 grid of game buttons, identical size, aligned rows and columns, evenly
spaced. Each ROW is one button family — row 1: primary; row 2: secondary
(quieter tones, same shape); row 3: toggle. Each COLUMN is one state — column
1: default; column 2: hover (brighter rim highlight); column 3: pressed (face
2px lower, darker). The three rows share one shape language and differ only in
color scheme.
```

Split with `--rows "button_primary,button_secondary,button_toggle"
--states "default,hover,pressed" --grid 3x3` (outputs auto-named
`button_primary_default.png`, ...). Works for slot variants, d-pad directions,
quest badges x states, bar types x fill levels, node types x tree states.

## Batch rules (breaking them = unsplittable sheet)

- ONE canvas size per sheet — normalization resizes the whole batch to one
  target; mixed sizes belong in different sheets.
- Max 5 columns x 4 rows; 12 items recommended ceiling.
- Gaps between items must be generous and even (> ~5% of image width); items
  aligned on shared baselines/rows.
- Decorations (padlocks, checkmarks, chevrons) must be attached to their
  item's face — floating decals between items break band detection.
- If `split_group.py` reports a band mismatch: reprompt with wider even gaps
  and stricter alignment. Never hand-cut.

## Fallback: single-component image

Only for an item that failed twice inside sheets, or an oversized one-off
(192x128 panels that fit no batch). Same style + contract clauses, one
component centered with a generous margin on every side. Normalize directly
(no split step).

## Ratio selection (per SHEET)

Sheet shape -> generation parameters (always `background: opaque`, `.png`):
- horizontal row of <= 4 -> `3:2` 1K; row of 5+ -> `16:9` 2K
- square-ish grid (3x3, 4x4) -> `1:1` 1K (2K if 16 items)
- wide grid (4x2, 5x3) -> `3:2` 1K
- vertical column -> `2:3` 1K
- single oversized panel -> `3:2` or `2:3` by aspect

## State phrasing cheat-sheet

Keep geometry IDENTICAL across states — only the listed attribute changes:

| State | Clause that works |
|---|---|
| default | plain resting face |
| hover | "brighter rim highlight along the top edge, otherwise identical" |
| pressed | "face shifted 2px lower, darker tones, no raised edge" |
| selected | "thick accent-colored outline ring around the face" |
| focused | "dotted inner outline one pixel inside the border" |
| active | "accent-colored glow pixels along the border" |
| disabled | "desaturated gray tones, low contrast, same shape" |
| locked | "dark tones with a small closed padlock emblem in the center" |
| unlocked | "bright tones with a small open padlock emblem" |
| completed | "small checkmark emblem in the corner, gold trim" |
| mastered | "ornate gold frame with a small crown emblem" |
| error | "red accent border" / warning "amber border" / success "green border" |
| empty | "hollow dark interior" / filled "interior filled with the accent fill" |
| loading | "fill strip half full with diagonal stripe pixels" |
| cooldown | "darkened face with a radial sweep wedge" |
| drag | "dashed-outline variant, slightly raised" |
| drop-target | "bright inset highlight inside the frame" |

## Failure -> reprompt fixes

| Symptom (verify_set.py / split_group.py catches it) | Fix in next prompt |
|---|---|
| split band mismatch (items touch/uneven gaps) | "generous even gaps between all items, aligned rows and columns, nothing touching" |
| outline cropped at image edge | "smaller in frame, generous empty margin on every side, nothing touches the edges" |
| text/letters/numbers appear | repeat the no-text clause; add "pure shapes only, no typography" |
| gradient/vignette/shadow on background | repeat the magenta clause; add "background is one flat uniform color" |
| extra sparkles/decorations scattered | "nothing between the items but empty background" |
| blurry/anti-aliased pixels | "chunky pixels, hard edges, no anti-aliasing, no smoothing" |
| wrong state (hover looks like pressed) | paste the state clause from the cheat-sheet verbatim |
| palette drift vs earlier sheets | re-attach the anchor sheet as reference image |
| magenta-ish colors in the art | swap that palette color — it collides with the key |
| item count wrong (4 instead of 5) | state the count twice: "a row of exactly 5 buttons: 1... 2... 3... 4... 5..." |
