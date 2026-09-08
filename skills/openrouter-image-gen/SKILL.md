---
name: openrouter-image-gen
description: >
  Generate raster / pixel-art images with OpenRouter's image models via the
  `/api/v1/images/generations` endpoint, and optionally edit an existing image
  via `/api/v1/images/edits`. Use when the user wants to create or transform an
  image through OpenRouter (text-to-image, image-to-image edits, spritesheet
  concepts) and the result should be written to disk as a PNG. Triggers:
  "generate an image", "draw a sprite", "make pixel art", "create a spritesheet
  image", "edit this image", "change the background of this image".
  Requires OPENROUTER_API_KEY in the environment; the model is chosen from
  BIXEL_IMAGE_MODEL (falls back to a pixel-art-friendly default).
---

# OpenRouter Image Generation

A thin, dependency-free wrapper around OpenRouter's OpenAI-compatible images
API. It calls the model, downloads the returned image, and writes a PNG to the
current directory. No SDK or API client is required — only Python 3 stdlib.

## When to use

- The user asks for a new image / sprite / piece of art.
- The user provides an image and asks to transform it (edit endpoint).

Not for: text chat, code, or non-image requests — hand those off to the text
model instead.

## Setup

`OPENROUTER_API_KEY` must be present in the environment. Optionally set
`BIXEL_IMAGE_MODEL` to a specific model id (any OpenRouter image model); the
script falls back to `meta/muse-image` and then to `google/gemini-3-pro-image`.

## Usage

```bash
# text -> image, saved as out.png
python3 scripts/openrouter_generate.py --prompt "a small green slime monster, walking" --out slime.png

# choose a model and size hint
python3 scripts/openrouter_generate.py --prompt "..." --model meta/muse-image --size 1024x1024 --out out.png

# image -> image edit (e.g. re-style or modify an existing frame)
python3 scripts/openrouter_generate.py --prompt "make it winter-themed" --image in.png --out winter.png
```

The script exits non-zero on failure and prints a single-line error to stderr.
On success it prints the absolute path and pixel size of the saved PNG.

## Workflow

1. Pick the model: honor an explicit `--model`; otherwise read `BIXEL_IMAGE_MODEL`;
   otherwise use the default.
2. Run the script with a clear, specific prompt (style, subject, palette,
   background, "no text, no watermark").
3. Report the saved path to the user. If the output looks wrong (wrong subject,
   text artifacts, wrong aspect), refine the prompt and re-run rather than
   post-processing by hand.
