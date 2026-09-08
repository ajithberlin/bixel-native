# Extraction Contract — When Is a Sheet Worth Extracting?

Measurable criteria, mapped to `sheet_report.py` output. Check BEFORE
packing (chroma key + atlas). A sheet that fails the contract costs more
time to fix than to reprompt. For a single 0-100 verdict instead of reading
individual fields, run `sheet_score.py` — it folds these criteria plus
identity/motion checks into a score and a corrective retry hint (see
`lessons-learned.md`).

The background is ALWAYS flat chroma green (#00FF00 prompted); criterion 1
is judged on the corner-sampled actual green, not on the prompted hex.

## Contract table

| # | Criterion | Threshold | report field |
|---|-----------|-----------|--------------|
| 1 | Background uniformity | corner spread < 30 (per channel) | `bg spread` |
| 2 | Background occupancy | fg coverage 5–90% | `fg coverage` |
| 3 | Row structure | band count == designed rows | `row bands` |
| 4 | Frame count | per-row counts == 4 (or two strips summing to 5-8); never ship 3-frame actions | `frames/row` |
| 5 | Frame size sanity | max/min frame height < 2.5x | `frame height variance` |
| 6 | Edge safety | no frame touches sheet edge | `edge-touching` warn |
| 7 | No text artifacts | zero labels/watermarks/numbers | visual check only |
| 8 | Pixel purity (soft check) | limited palette, hard edges, no AA blur | visual check only |
| 9 | Pivot alignment | per-row feet bottom-y drift < ~10% of median frame height | `pivot-drift` |

#8 is a soft criterion: painterly "pixel-look" sheets (thousands of colors,
anti-aliased edges) still key out, but edges fray and frames look wrong
next to true pixel art. If the sheet fails #8 but passes the rest, packing
works — expect cosmetic edge cleanup.

## Reading sheet_report.py output

```
bg=[0,255,0] spread=2             -> pass #1 (spread < 30)
fg coverage 38.2%                 -> pass #2
row bands: 5 (expected 5)         -> pass #3
frames per row: [12,12,14,14,14]  -> #4: rows differ -> inspect
frame height variance 3.1x        -> FAIL #5
WARN: 2 frames touch sheet edge   -> FAIL #6
row 0: ... frames=3 pivot-drift=22px -> FAIL #9 if >10% of median height
```

## Failure -> action

| Failure | Most likely cause | Action |
|---------|-------------------|--------|
| #1 spread > 30 | gradient/shadow bg | reprompt with flat-bg clause; do not attempt keyout |
| #2 coverage > 90% | bg clause ignored, full-bleed art | reprompt |
| #2 coverage < 5% | tiny sprites, huge canvas | usable, but re-generate at tighter crop for resolution |
| #3 band mismatch | rows touching / merged | reprompt with "generous gaps between rows"; extraction will mis-band |
| #4 count mismatch per row | merged adjacent frames or split limbs | try `--tol 30..60` once; still wrong → reprompt |
| #5 variance > 2.5x | text labels detected as frames, or size drift | visual inspect; labels → reprompt "no text"; drift → manual cut or reprompt |
| #6 edge touching | sheet cropped too tight | packing may clip sprites; reprompt with "margin around the whole grid" |
| #7 text present | generator added captions | reprompt; text keyed as foreground corrupts frames |
| #9 pivot drift | feet not pinned to cell bottom | reprompt with "feet planted at the exact same bottom line in every frame"; minor drift is auto-fixed by chroma_key_pack.py's bottom-center paste |

## When to accept warnings and proceed anyway

- Frame count off by exactly 1 in one row AND visual check shows two frames
  touching: proceed — packing with higher `--tol` or one manual split
  fixes it.
- Variance 2.5–3.5x with NO text visible: probably one dramatic pose frame;
  proceed if that frame is expendable.
- Pivot drift slightly over threshold in a walk row (mid-stride bounce is
  natural): proceed — chroma_key_pack.py bottom-aligns every frame into its
  cell, which removes the jitter.
- Everything else: reprompt. Reprompting costs one generation; packing a
  broken sheet costs an hour and yields bad frames regardless.

## Irregular / scattered-layout sheets

This contract's row-structure criteria (#3, #4, #9) assume a grid. Sheets
with poses scattered at arbitrary positions, mixed sizes, or multi-part
sprites (character + floating weapon + effect cloud) FAIL #3 by design —
do not reprompt them and do not force them through `chroma_key_pack.py`.
For these the contract reduces to:

| # | Criterion (freeform) | Check |
|---|----------------------|-------|
| F1 | Background near-flat (any color) | border-sampled key + `--tol` keys it out cleanly |
| F2 | Sprites separable | gaps BETWEEN sprites > gaps between a sprite's own parts; tune `--merge`. Divider LINES are auto-stripped (`--strip-lines`); weak blends and thin contacts are auto-split (`--split-factor`); sprites DRAWN OVER each other are not separable — crop by hand or regenerate |
| F3 | Sprite count | `freeform_pack.py` printed count == what you see; persistent WARN about an oversized cluster after auto-split = overlapping artwork, handle manually |
| F4 | No text artifacts | same as #7 — text keyed as foreground becomes a fake sprite |

Pack with `freeform_pack.py` (SKILL.md step 4b): pixel-proximity
clustering, content crops with foreign-pixel masking, centroid pivot.
`sheet_report.py` / `sheet_score.py` do not apply to these sheets.

## After the contract passes

Pack with `chroma_key_pack.py` (see SKILL.md step 4): it removes the chroma
green, normalizes every frame into a uniform cell (bottom-center pivot,
zero margins or uniform `--padding`), and emits ONE transparent PNG atlas +
ONE JSON with per-action frame rects. Record from the report: band count
(rows) and frames/row — they must match the `--actions` lists exactly;
chroma_key_pack.py errors out on any mismatch instead of packing garbage.
