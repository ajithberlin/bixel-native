---
name: pixel-interpolate
description: Generate in-between animation frames from a first frame and a last frame (image-referenced animation / interpolation) — e.g. smooth a 2-pose walk into 5 frames, morph a door open, tween a slash effect. Use when the user provides or wants TWO endpoint images ("first frame" + "last frame") and asks to "interpolate", "generate frames between these", "animate from image A to image B", "in-betweening", or "new frames (3)". Handles endpoint normalization, midpoint-conditioned generation, ordering, anti-jitter packing, and GIF preview. For text-only animation from a single frame, use pixel-animate-text.
---

# Interpolate (Animate from Image Reference)

Given a **first frame** and a **last frame**, generate the frames in between.

## Inputs

| Input | Required | Notes |
|---|---|---|
| First frame | YES | Transparent bg preferred. |
| Last frame | YES | Same subject, same canvas size, same view. |
| New frame count | no | Default 3. Keep ≤ 5 — more in-betweens amplify drift. |
| Action description | no | "walking forward" — strongly recommended; it disambiguates the motion path. |

## Pre-flight checks (do these BEFORE generating)

1. **Same subject & style**: if the two endpoints differ in outfit/palette/proportions, interpolation will smear — regenerate one endpoint from the other as reference first.
2. **Same canvas size & scale**: resize/crop so both match. Subject height should differ by < 10%; if the last frame is scaled, fix it with nearest-neighbor resize, not by hoping.
3. **Small motion delta**: interpolation works when endpoints are close (leg lift vs leg down, door closed vs door ajar). For large motions (full walk cycle, 180° turn), **chain interpolations**: A→mid, then mid→B, generating mid as its own keyframe with the pixel-animate-text skill.

## Workflow

1. Normalize endpoints (checks above). Save as `frame_first.png`, `frame_last.png`.
2. **Generate each in-between** with BOTH endpoints as reference, one image per frame, describing its position in the motion. For N new frames, frame i of N sits at t = i/(N+1) of the motion. Prompt skeleton:

   > Pixel art in-between frame, [t*100]% of the way from the first reference image to the last reference image. Action: [action description]. Pose at this moment: [explicit pose, e.g. "legs passing under body, arm mid-swing"]. Identical palette, proportions, canvas size and view as both references. PNG with real alpha=0 transparent background, no checkerboard or shadow; if alpha is unavailable, use flat #00FF00 chroma green, then run pixel-remove-bg in key mode before packing. Crisp pixel art, no text.

   Write the explicit pose yourself from the endpoints — never write "intermediate pose".
3. **Order and verify**: sequence is first → in-betweens (ascending t) → last. Look for swapped or duplicated frames before packing (AI occasionally returns the endpoint again).
4. **Pack** — run `scripts/pack_frames.py` with ALL frames including endpoints:

   ```bash
   python3 scripts/pack_frames.py --frames frame_first.png mid1.png mid2.png mid3.png frame_last.png \
       --out anim.png --gif anim.gif --fps 8
   ```

5. **Watch the GIF**: motion should be monotone (no back-and-forth). If a middle frame pops, regenerate just that frame with a clearer pose description and re-pack.
6. **Deliver**: sheet PNG + JSON + GIF, endpoints included in the sheet (engines want the full sequence).

## Good vs bad candidates

- GOOD: door/chest opening, weapon slash (2 keyframes), walk leg swap, size pulse, simple transforms.
- BAD: rotations > 45°, shape-shifting, anything changing the silhouette outline completely — use pixel-animate-text keyframes instead.
