# Lessons Learned — From a Production Sprite-Generation Pipeline

Distilled from a production AI-sprite pipeline ("PerfectPixel"). Design
philosophy in one line: **signal processing, not heuristics** — wrapped in a
self-diagnostic, self-correcting closed loop. Read this when deciding how to
verify sheets, when naive keying/detection fails, or when a loop of
regenerations is not converging.

## Contents
- The closed loop (best-candidate scoring + retry hints)
- Lesson 1: Background removal — chrominance, not RGB
- Lesson 2: Segmentation — projection profile + optimal cut
- Lesson 3: Alignment — alpha-weighted centroid, not bbox center
- Lesson 4: Pixel-art post-processing — shared palette + grid snap
- Lesson 5: Identity & quality scoring — two orthogonal axes + motion
- Where each lesson lives in this skill

## The closed loop (the two ideas that matter most)

1. **Best-candidate scoring.** Score EVERY attempt; a perfect result returns
   immediately, otherwise regenerate up to 3x and keep the best-so-far —
   never return an empty hand. API errors and cancellations bail early.
2. **Measurement-driven retry hints.** Convert each detected defect into a
   precise English correction injected into the next prompt (e.g. "the
   previous result read as 7 poses but exactly 6 are required; split the
   canvas into 6 even columns..."). Each pass converges on the measured
   defect instead of rolling the dice again.

`scripts/sheet_score.py` implements both: 0-100 score per sheet, a
`retry hint:` line to paste verbatim into the next prompt, and best-of-N
selection when given several attempts.

## Lesson 1: Background removal — chrominance, not RGB

Naive RGB thresholding leaves residue and halos (measured: 2,739px key
residue + 8,164px halo vs 2px residue with chrominance matting).

- Work in **YCbCr and discard luma (Y)** — key only on (Cb, Cr). Shaded and
  bright background pixels read as the same color, and the chroma planes are
  inherently robust to JPEG's 4:2:0 subsampling (JPEG preserves luma but
  crushes chrominance).
- Estimate the key as the **mode of a CbCr histogram**, not the mean — a
  gradient or noise does not shift the mode. Sample from the four corners,
  where the character rarely intrudes.
- Feather edges with a **smoothstep soft alpha**, despill by projecting out
  **only the key-direction spill** (protects the character's own colors),
  and clear leftovers with a **4-connectivity flood fill from the borders**
  so isolated interior pixels survive (the character never gets holes).
- Add a **self-diagnostic fallback**: if opacity or key-residue metrics
  spike, re-matte with a pure reference key automatically.

`chroma_key_pack.py` today: corner-sampled RGB L1 key + edge-only despill.
Upgrade to chrominance matting when sheets arrive JPEG-compressed or the
report shows residue/halo the RGB key cannot handle.

## Lesson 2: Segmentation — projection profile + optimal cut

Asking for "6 frames" rarely yields 6 evenly spaced poses; arms touch the
neighbor and gaps are uneven. Borrow OCR's projection-profile technique:

- Vertical alpha projection P[x] = Σ_y α(x,y): inter-pose gutters appear as
  valleys; after smoothing, count content runs as the natural pose count.
- When poses FUSE and the valley vanishes, connected components merge them
  into one blob and equal-split cuts through bodies. Instead use **dynamic
  programming for the globally optimal expected−1 cuts**, minimizing
  `Σ P[cut] + λ·(width − ideal)²` — the cut slides to the minimum-alpha
  seam and splits exactly the expected count, slicing as little limb as
  possible (measured: 9/9 poses separated intact where equal-split put 8/8
  cut lines through characters).

`chroma_key_pack.py` uses connected components + bridging — sufficient when
the prompt enforces generous gaps. When a row's count is off by exactly one
fused pair, a DP seam split fixes it without a reprompt.

## Lesson 3: Alignment — alpha-weighted centroid, not bbox center

Centering by bounding box lets an outstretched arm or weapon push the torso
sideways — the character jitters during playback.

- Align the **alpha-weighted centroid** (center of mass, cx = Σ(x·α)/Σα) to
  the cell center. The torso dominates the centroid, so limbs can extend
  freely while the body stays pinned (measured: centroid σ 27.2px → 0.2px,
  ~135x more stable than bbox centering).
- Unify character size with a **shared scale across all frames** (downscale
  only), and keep a **baseline offset** so jump arcs survive.
- Horizontal = centroid; vertical = feet baseline. This pair is the
  "rock-steady axis" that matters most in-game.

`chroma_key_pack.py` currently pins the vertical axis (bottom-center paste).
If an action row still weaves left/right in playback, centroid alignment is
the fix.

## Lesson 4: Pixel-art post-processing — shared palette + grid snap

AI "pixel art" is a high-res image with AA and thousands of colors (measured:
7,834 colors → 12 after processing).

- Extract a **shared palette across ALL frames** via median-cut — per-frame
  quantization flickers during playback. Use a perceptually weighted color
  distance `2dr² + 4dg² + 3db²`.
- Estimate the real block size of the fake pixels from the **mode of
  same-color run lengths**, then grid-snap: fill each block with its
  dominant color on a shared grid.
- Run **identity inspection BEFORE quantization** — palette reduction dulls
  the drift signal.

## Lesson 5: Identity & quality scoring — two axes + motion

A single similarity metric misses whole classes of defects; use two
orthogonal axes plus a motion check, folded into one 0-100 score:

- **64-bin RGB color histogram**, intersection similarity, leave-one-out +
  base comparison — catches both a single outlier frame and batch-wide
  color drift.
- **dHash perceptual hash** (9x8 grayscale) — structure-sensitive and
  color-invariant; catches silhouette changes the histogram cannot.
- **Motion-presence metric** — catches the opposite defect: frames too
  similar, effectively a still image.

```
start at 100
 − (35 + 10·|Found−Expected|)   frame-count accuracy (largest penalty)
 − 13·errors − 3·warnings
 − 12   (motion < 0.01 with 2+ frames — effectively static)
 − 10   (dHash identity < 0.55 — structural collapse)
→ excellent (≥85) / good (≥70) / fair (≥50) / poor (<50)
```

Implemented verbatim in `scripts/sheet_score.py`. Never ship `poor`;
target ≥ 85, accept 70-84 only with warnings you understand.

## Where each lesson lives in this skill

| Lesson | Enforced by |
|--------|-------------|
| Best-candidate scoring, retry hints | `scripts/sheet_score.py` (+ SKILL.md workflow step 3) |
| Chrominance matting, despill, flood fill | `scripts/chroma_key_pack.py` (RGB key + edge despill today; upgrade path above) |
| Projection + DP segmentation | generous-gap prompts prevent fusion; DP split is the manual-fix fallback |
| Centroid alignment | `chroma_key_pack.py` bottom-center paste (vertical); centroid = horizontal fix |
| Shared-palette quantization | post-pack polish step when the target is true pixel art |
| Identity + motion scoring | `scripts/sheet_score.py` |
