#!/usr/bin/env python3
"""
compress_image.py — Trim blank/background margins from an image, then
downscale it to a small target resolution (e.g. 1600x1600 -> 32x32) using
high-quality resampling, and save with optimized compression.

Why crop before resizing:
Most source images (logos, icons, screenshots, scanned art) carry a border
of blank canvas — white space, a solid background color, or transparency —
around the actual subject. If you shrink the *whole* canvas straight down to
32x32, a big chunk of those 32x32 pixels gets wasted on that dead space, and
the subject itself shrinks even further inside the frame, losing detail.
Finding the real content first and cropping to it means every one of the
few pixels you have left in the output is spent on the subject, not on
margin.

Usage:
    python compress_image.py INPUT OUTPUT [options]

Examples:
    # Basic: 1600x1600 logo on white background -> a crisp 32x32 icon
    python compress_image.py logo.png icon.png --size 32x32

    # Keep exact aspect ratio, pad to a perfect square with transparency
    python compress_image.py photo.jpg thumb.png --size 64x64 --pad

    # Looser tolerance for a background that isn't perfectly flat (jpeg noise, gradients)
    python compress_image.py scan.jpg icon.png --size 32x32 --tolerance 25

    # Skip the auto-crop entirely (image has no blank margin, e.g. a full-bleed photo)
    python compress_image.py photo.jpg thumb.png --size 128x128 --no-crop
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops


def detect_content_bbox(img: Image.Image, tolerance: int = 12, pad: int = 0):
    """
    Find the bounding box of the actual subject inside `img`, treating a
    uniform border (transparent, or a solid/near-solid background color) as
    blank space to discard.

    Strategy:
    - If the image has an alpha channel, blank space is wherever alpha is
      (near) zero. We treat that as the border and crop to where content is
      opaque.
    - Otherwise, we sample the four corner pixels to guess the background
      color (the most common corner color), build a same-size solid image of
      that color, diff it against the real image, threshold the diff by
      `tolerance` (0-255; higher = more forgiving of noise/gradients in the
      "background"), and take the bounding box of what's left.

    Returns a (left, upper, right, lower) box, or None if no content could
    be distinguished from background (e.g. a perfectly solid image) — in
    that case the caller should skip cropping rather than crop to nothing.
    """
    rgba = img.convert("RGBA")
    alpha = rgba.getchannel("A")
    has_transparency = alpha.getextrema()[0] < 255

    if has_transparency:
        # Treat near-transparent pixels as blank. Threshold so faint
        # antialiased edges (alpha ~1-10) don't count as "content".
        thresholded = alpha.point(lambda a: 255 if a > 10 else 0)
        bbox = thresholded.getbbox()
    else:
        rgb = img.convert("RGB")
        w, h = rgb.size
        corners = [rgb.getpixel((0, 0)), rgb.getpixel((w - 1, 0)),
                   rgb.getpixel((0, h - 1)), rgb.getpixel((w - 1, h - 1))]
        # Most common corner color = our best guess at the background.
        bg_color = max(set(corners), key=corners.count)

        bg = Image.new("RGB", rgb.size, bg_color)
        diff = ImageChops.difference(rgb, bg)
        # Collapse to one channel (max across R/G/B) and threshold.
        diff_gray = diff.convert("L")
        thresholded = diff_gray.point(lambda p: 255 if p > tolerance else 0)
        bbox = thresholded.getbbox()

    if bbox is None:
        return None

    if pad:
        left, upper, right, lower = bbox
        w, h = img.size
        left = max(0, left - pad)
        upper = max(0, upper - pad)
        right = min(w, right + pad)
        lower = min(h, lower + pad)
        bbox = (left, upper, right, lower)

    return bbox


def resize_high_quality(img: Image.Image, size, fit: str, canvas_color):
    """
    Resize `img` to exactly `size` = (w, h) using the highest-quality
    standard resampling filter (LANCZOS), which does proper band-limited
    downsampling instead of naive pixel dropping — this matters a lot when
    the size reduction is drastic (e.g. 1600px -> 32px).

    fit:
      - "stretch": resize directly to `size`, ignoring aspect ratio.
      - "pad":     resize to fit *inside* `size` preserving aspect ratio,
                   then center it on a `size` canvas filled with
                   `canvas_color` (transparent if the image has alpha).
                   This guarantees the exact output dimensions requested
                   without distorting the subject.
    """
    target_w, target_h = size

    if fit == "stretch":
        return img.resize((target_w, target_h), Image.LANCZOS)

    # fit == "pad"
    src_w, src_h = img.size
    scale = min(target_w / src_w, target_h / src_h)
    new_w = max(1, round(src_w * scale))
    new_h = max(1, round(src_h * scale))
    resized = img.resize((new_w, new_h), Image.LANCZOS)

    mode = "RGBA" if img.mode in ("RGBA", "LA") or "transparency" in img.info else "RGB"
    canvas = Image.new(mode, (target_w, target_h), canvas_color)
    offset = ((target_w - new_w) // 2, (target_h - new_h) // 2)
    canvas.paste(resized, offset, resized if mode == "RGBA" and resized.mode == "RGBA" else None)
    return canvas


def save_optimized(img: Image.Image, out_path: Path, fmt: str, quality: int):
    """Save with format-appropriate maximum compression that doesn't throw
    away visible quality — optimize flags and, for PNG, letting Pillow pick
    the best filter/compression level. JPEG/WEBP use `quality` (lossy)."""
    fmt = fmt.upper()
    save_kwargs = {}

    if fmt == "PNG":
        save_kwargs.update(optimize=True, compress_level=9)
        if img.mode not in ("RGBA", "RGB", "P", "L", "LA"):
            img = img.convert("RGBA")
    elif fmt in ("JPEG", "JPG"):
        fmt = "JPEG"
        if img.mode in ("RGBA", "LA", "P"):
            # JPEG has no alpha; flatten onto white.
            background = Image.new("RGB", img.size, (255, 255, 255))
            if img.mode != "RGBA":
                img = img.convert("RGBA")
            background.paste(img, mask=img.getchannel("A"))
            img = background
        save_kwargs.update(quality=quality, optimize=True, progressive=True)
    elif fmt == "WEBP":
        save_kwargs.update(quality=quality, method=6)
    else:
        raise ValueError(f"Unsupported output format: {fmt}")

    img.save(out_path, format=fmt, **save_kwargs)


def parse_size(s: str):
    if "x" not in s.lower():
        raise argparse.ArgumentTypeError("size must look like WIDTHxHEIGHT, e.g. 32x32")
    w, h = s.lower().split("x")
    return int(w), int(h)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", type=Path, help="Source image path")
    parser.add_argument("output", type=Path, help="Destination image path (extension picks the format unless --format is given)")
    parser.add_argument("--size", type=parse_size, default=(32, 32), help="Target size as WIDTHxHEIGHT (default: 32x32)")
    parser.add_argument("--no-crop", action="store_true", help="Skip auto-cropping blank margins; resize the full canvas as-is")
    parser.add_argument("--tolerance", type=int, default=12, help="0-255, how different a pixel must be from the detected background to count as content (default: 12). Raise this for noisy/gradient backgrounds.")
    parser.add_argument("--crop-padding", type=int, default=0, help="Extra pixels of margin to keep around the detected content bbox (default: 0)")
    parser.add_argument("--fit", choices=["pad", "stretch"], default="pad", help="'pad' (default) preserves aspect ratio and centers on a transparent/solid canvas of exactly --size; 'stretch' fills --size exactly by distorting aspect ratio")
    parser.add_argument("--canvas-color", default=None, help="Background color for padding, e.g. '255,255,255' or 'white'. Default: transparent if the image supports alpha, else the detected/sampled background color.")
    parser.add_argument("--format", default=None, help="Output format: png, jpeg, webp. Default: inferred from --output's extension.")
    parser.add_argument("--quality", type=int, default=90, help="Lossy quality 1-100 for jpeg/webp (default: 90). Ignored for png (lossless).")
    args = parser.parse_args()

    img = Image.open(args.input)
    img.load()
    orig_size = img.size

    if args.no_crop:
        cropped = img
        crop_box = None
    else:
        crop_box = detect_content_bbox(img, tolerance=args.tolerance, pad=args.crop_padding)
        cropped = img.crop(crop_box) if crop_box else img

    canvas_color = args.canvas_color
    if canvas_color is not None and "," in canvas_color:
        canvas_color = tuple(int(c) for c in canvas_color.split(","))
        if len(canvas_color) == 3:
            canvas_color = canvas_color + (255,)
    elif canvas_color is None:
        has_alpha = cropped.mode in ("RGBA", "LA") or "transparency" in cropped.info
        canvas_color = (0, 0, 0, 0) if has_alpha else (255, 255, 255)

    result = resize_high_quality(cropped, args.size, args.fit, canvas_color)

    fmt = (args.format or args.output.suffix.lstrip(".") or "png")
    fmt = "JPEG" if fmt.lower() in ("jpg", "jpeg") else fmt.upper()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    save_optimized(result, args.output, fmt, args.quality)

    in_bytes = args.input.stat().st_size
    out_bytes = args.output.stat().st_size
    print(f"Input:  {args.input}  {orig_size[0]}x{orig_size[1]}  {in_bytes:,} bytes")
    if crop_box:
        print(f"Cropped to content box: {crop_box}  -> {cropped.size[0]}x{cropped.size[1]}")
    elif args.no_crop:
        print("Cropped to content box: (skipped — --no-crop was set)")
    else:
        print("Cropped to content box: (skipped — no distinguishable blank margin found)")
    print(f"Output: {args.output}  {result.size[0]}x{result.size[1]}  {out_bytes:,} bytes  ({fmt}, fit={args.fit})")
    if in_bytes:
        print(f"Size reduction: {100 * (1 - out_bytes / in_bytes):.1f}%")


if __name__ == "__main__":
    sys.exit(main())
