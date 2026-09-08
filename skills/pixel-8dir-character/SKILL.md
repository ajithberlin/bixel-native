---
name: pixel-8dir-character
description: Create an 8-direction rotation set for a pixel-art character or object (N, NE, E, SE, S, SW, W, NW) from a description, style image, or existing sprite — for top-down RPGs, twin-stick games, and tactics games. Use when the user wants "8 direction character", "rotation frames", "character facing all directions", "8-way sprite", "create rotations", "top-down character directions", or has one sprite that must face 8 ways. Handles view selection (top-down / low top-down / side), the generate-vs-mirror decision, reference-locked rotation prompting, and packing in canonical engine order with JSON + GIF preview.
---

# 8-Direction Character Rotation

Produce 8 consistent rotation frames: S, SW, W, NW, N, NE, E, SE.

## Inputs (at least ONE required)

| Input | Notes |
|---|---|
| Description | "cute wizard" — enrich into outfit, colors, proportions. |
| Style image | Palette/art-style reference only. |
| Reference sprite | Existing character art — the identity to preserve. |

Also: **view** (`low top-down` default, `top-down`, `side`) and canvas ≤ 160×160.

## Workflow

1. **Establish the master frame.** Best: generate or take the **S (facing camera)** frame first — it shows the most detail and anchors identity. Clean it (transparent bg, centered).
2. **Decide mirror vs generate** per axis:
   - Symmetric character (wizard, knight, slime): generate **E once, mirror it for W** (`Image.FLIP_LEFT_RIGHT`) — free and perfectly consistent. Same for NE↔NW and SE↔SW if the design is symmetric.
   - Asymmetric (sword in right hand, shoulder pad on one side): generate all 8; mirroring would flip the handedness.
3. **Generate the missing directions**, each with the master frame as reference image:

   > Same pixel art character as the reference image, identical outfit, palette, proportions and [view] view, rotated to face [direction: north / away from camera | north-east / ... ]. Feet planted at the same baseline, same height, transparent background, crisp pixel art, no text.

   Use compass words AND a plain-language cue ("away from camera", "three-quarter back-left") — models confuse "north" alone.
4. **Name files by direction** (`hero_S.png`, `hero_SW.png`, ...) — the packer reads direction from the filename.
5. **Pack in canonical order** — run `scripts/pack_8dir.py`:

   ```bash
   python3 scripts/pack_8dir.py --dir ./rotations --out hero_8dir.png --layout 4x2 --gif rotate.gif
   ```

   Cells are uniform and bottom-anchored so the character never jumps. JSON maps each direction to its cell: order S, SW, W, NW, N, NE, E, SE (Flame/Bonfire-friendly; reindex in-engine if it expects E-first).
6. **Watch the GIF**: it should read as a smooth turntable. Fix: hat/cape teleporting between adjacent directions → regenerate the offender with "same [item] as reference, now seen from [direction]"; height drift → the packer reports cell size, but scale drift needs regeneration ("same height as reference").

## Hard rules

- Never mix views in one set (all 8 must share the same camera angle).
- Diagonals are three-quarter views, NOT 45°-rotated side views — say "three-quarter" in the prompt.
- One frame per direction per sheet; animation frames per direction are a separate sheet per direction (use pixel-animate-text).
