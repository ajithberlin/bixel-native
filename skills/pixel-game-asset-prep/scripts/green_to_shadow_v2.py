"""
green_to_shadow.py  (v2)

Converts a chroma-green placeholder (any shade of green -- pure bright
green, dark green, pale anti-aliased green near the edges, etc.) into a
soft, semi-transparent drop shadow like you'd see in a top-down RPG
(Stardew Valley / RPG Maker style).

Key idea (v2 update):
    Pixel art often already encodes the shadow's soft edge as a GRADIENT
    of green shades -- solid/bright green in the core of the ellipse,
    fading to darker or paler green near the rim (anti-aliasing against
    the background). Rather than blurring a flat-alpha shadow, we read
    that gradient directly from each pixel's brightness (HSV "V") and
    use it to drive the shadow's opacity:

        darker green  -> more shadow (higher alpha, closer to shadow_rgb)
        lighter green -> less shadow (lower alpha, fades toward transparent)

    This also generalizes to ANY chroma-green variant (e.g. (0,255,0),
    (0,177,64) chroma key green, olive-ish greens, etc.) because
    detection is done by HUE, not by matching one exact RGB value.

Usage:
    python3 green_to_shadow.py input.png output.png

Requires: pillow, numpy, matplotlib (for the vectorized rgb_to_hsv helper)
    pip install pillow numpy matplotlib
"""

import sys
import numpy as np
from PIL import Image
from matplotlib.colors import rgb_to_hsv


def green_to_shadow(
    in_path,
    out_path,
    shadow_rgb=(20, 20, 20),   # near-black shadow tint
    max_alpha=150,             # opacity of the darkest ("most shadowed") green
    min_alpha=0,               # opacity of the lightest green (near edge/rim)
    hue_range=(0.20, 0.47),    # normalized hue (0-1) window covering green variants
    sat_min=0.15,              # ignore near-gray/near-white pixels (anti-alias noise)
):
    img = Image.open(in_path).convert("RGBA")
    arr = np.array(img).astype(np.float64)

    rgb = arr[..., :3] / 255.0
    hsv = rgb_to_hsv(rgb)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    a = arr[..., 3]

    # 1. Detect ANY chroma-green variant by hue + saturation (not exact RGB match).
    green_mask = (h > hue_range[0]) & (h < hue_range[1]) & (s > sat_min) & (a > 0)

    # 2. Normalize brightness (V) of just the green pixels to 0-1, so the
    #    mapping adapts to whatever range of greens this particular image uses.
    v_green = v[green_mask]
    v_min, v_max = v_green.min(), v_green.max()
    v_norm = (v_green - v_min) / max(v_max - v_min, 1e-6)

    # 3. Darker green (v_norm -> 0) = more shadow = higher alpha.
    #    Lighter green (v_norm -> 1) = less shadow = lower alpha.
    alpha_values = max_alpha - v_norm * (max_alpha - min_alpha)

    out = arr.copy()
    out[green_mask, 0] = shadow_rgb[0]
    out[green_mask, 1] = shadow_rgb[1]
    out[green_mask, 2] = shadow_rgb[2]
    out[green_mask, 3] = alpha_values

    Image.fromarray(out.astype(np.uint8), "RGBA").save(out_path)
    print(f"Green-ish pixels replaced: {green_mask.sum()}")
    print(f"Saved: {out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 green_to_shadow.py input.png output.png")
        sys.exit(1)
    green_to_shadow(sys.argv[1], sys.argv[2])
