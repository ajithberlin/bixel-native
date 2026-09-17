---
name: pixel-image-gen
description: >
  Generate standalone, game-ready pixel-art assets from natural language or a
  reference image, with explicit controls for style, resolution, palette,
  perspective, transparency, and sprite size. Use for single sprites, objects,
  environments, tilesets, characters, items, and scenes — plus style-reference
  matching, image-to-pixel-art conversion, same-style character generation,
  portrait-to-character conversion, pixel fonts, and template-based characters.
  Do NOT use for multi-frame animation strips (pixel-spritesheet-gen) or UI
  component kits (pixel-ui-kit-gen).
---

# Pixel Image Generation

Turn a subject and structured controls into a single, clean, game-ready
pixel-art asset. The user's structured choices (style, resolution, palette,
perspective, transparency, sprite size) are always honored over any stylistic
taste the model might otherwise apply.

## Non-negotiable output rules

1. **One asset per image.** Never return a sheet, a collage, a mockup, or
   multiple variants of the subject in one image.
2. **Crisp pixels only.** No blur, no anti-aliasing, no soft gradients, no
   photography-style lighting. Hard, flat pixel clusters with clean 1px
   outlines where the style calls for them.
3. **Honor the chosen resolution.** If a resolution is given, the subject
   reads as that pixel density (e.g. a 64x64 sprite), with a visible pixel
   grid at that scale.
4. **Honor the chosen palette.** Stick to the named palette or the described
   palette family; do not introduce off-palette colors.
5. **Honor transparency.** For a no-background asset, request a PNG with a
   real alpha channel: every background pixel must be alpha=0 (no backdrop,
   vignette, checkerboard, or baked ground shadow). If the provider cannot
   return alpha, use one flat chroma key instead — exact green `#00FF00` or
   magenta `#FF00FF`, with clear margins — then load `pixel-remove-bg` and run
   its Python key cleanup before delivering or slicing the asset. A solid
   background is allowed only when the user asks for one.
6. **Consistent light and perspective.** One lighting direction and one
   camera angle across the whole asset.
7. **No text, labels, watermarks, borders, or frame lines** anywhere.

## Reference image rules (style-reference, image-to-pixel, same-style)

- The reference defines identity and art direction, not content: reproduce its
  palette, shading model, outline thickness, proportions, and level of detail
  on the *new* subject.
- For image-to-pixel-art, preserve the subject's identity and composition
  while dropping photographic detail; quantize to the requested color count
  and apply the requested dithering and outline strength.
- For same-style characters, keep body proportions, head-to-body ratio, and
  pixel density identical to the reference.

## Direction / sheet rules (eight-direction only)

- Exactly 8 equal cells in one horizontal row: front, back, left, right, and
  the four diagonals (front-left, front-right, back-left, back-right).
- Every cell is the same size; the character's feet are bottom-aligned in each
  cell; the design (clothing, colors, accessories, proportions) is identical
  across all 8 — only the facing changes.

## Font rules (pixel-font only)

- A complete monospace glyph set: A–Z, a–z, 0–9, and common punctuation and
  symbols, arranged in a tidy grid with equal cell sizes.
- Identical glyph weight, height, and spacing; no serif drift; no anti-aliasing.

## Quality bar

- The image can be downscaled to the requested resolution with NEAREST
  sampling and still read cleanly (no blur, no sub-pixel mush).
- The palette is limited and consistent; transparency is fully transparent
  where requested.
- A reader can name the perspective, lighting direction, and style without
  ambiguity.
