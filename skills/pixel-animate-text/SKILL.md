---
name: pixel-animate-text
description: Animate a pixel-art character or object from a text action description — walking, jumping, waving, attacking, idle — starting from a single first frame (user-provided or generated). Use when the user says "animate this sprite", "make it walk", "generate a walk cycle", "animate with text", "walking forward 4 frames", or provides one static frame plus an action. Handles pose-keyed frame generation with reference-image guidance, anti-jitter packing into a uniform spritesheet, JSON metadata, and GIF preview. For animation from two endpoint images (first + last frame), use pixel-interpolate instead.
---

# Animate with Text

Turn one static frame + an action description ("walking forward") into a loopable pixel animation.

## Inputs

| Input | Required | Notes |
|---|---|---|
| First frame | no | If absent, generate it first (character description + view). Transparent bg. |
| Action description | YES | "walking", "jumping", "waving". One action per sheet. |
| Frame count | no | Default 4. Walk cycles: 4 or 6. Attacks: 5–8. Idle: 2–4. |

Keep canvas ≤ 160×160 — larger frames lose pixel-art crispness and consistency.

## Workflow

1. **Lock the first frame.** If the user provides one, clean it (transparent bg, cropped to the subject). All later frames must match its scale, palette, and view — reference it on every generation.
2. **Plan key poses** for the action and describe each frame as an explicit POSE, never as "frame 2 of a walk". Walk cycle (4f):
   1. contact — left leg forward, right leg back
   2. recoil/down — legs passing under body, body lowest
   3. contact — right leg forward, left leg back
   4. passing — legs together mid-stride, body highest

   Other actions: jump = crouch → launch → airborne → land; wave = arm down → arm up → tilted; attack = windup → strike → follow-through → recover.
3. **Generate frames 2..N**, each with the first frame as reference image. Prompt skeleton per frame:

   > Same pixel art character as the reference image, identical outfit, palette, proportions and view, now in this pose: [explicit pose from step 2]. Transparent background, full body visible, same canvas size, crisp pixel art, no text.

4. **Pack without jitter** — run `scripts/pack_frames.py` (crops each frame, bottom-anchors so feet stay planted):

   ```bash
   python3 scripts/pack_frames.py --dir ./frames --out walk.png --gif walk.gif --fps 6
   ```

5. **Watch the GIF at 100% zoom.** Fix or regenerate frames where: feet slide, head height bounces >2px between adjacent frames, silhouette pops, palette drifts. Bottom-anchored packing fixes position jitter; scale drift requires regenerating the offending frame with "same height as reference".
6. **Deliver**: sheet PNG + `sheet.png.json` (frame rects for Flame/Unity/Godot) + GIF preview.

## Hard rules

- One action per spritesheet — never mix walk and attack rows.
- Loop check: last frame must flow into frame 1 (for walk: pose 4 ≈ mirror of pose 2).
- If 2+ regenerations keep failing, reduce frame count (4 → 3) — fewer, cleaner frames beat a long broken cycle.
