#!/usr/bin/env python3
"""Build the structured manifest for a finished UI asset set.

Scans a directory of verified PNGs (category subfolders recommended) and emits
manifest.json (+ optional manifest.csv) with, per asset:
  component name, category, state, dimensions, suggested filename,
  nine-slice compatibility, recommended padding, scaling mode
  (none = fixed size | stretch = 9-slice/scale | tile = repeat).

Component/state are parsed from snake_case filenames by longest-suffix match
against a state list; category comes from the parent folder. Defaults for
nine-slice/padding/scaling come from keyword rules; override any entry with
--overrides overrides.json:  {"quest_card": {"nine_slice": true, ...}}.

Example:
  python3 build_manifest.py assets/ --out-json manifest.json --out-csv manifest.csv \
      --theme "Nihongo Town"
"""
import argparse
import csv
import json
import os
import re
import sys
from datetime import date

from PIL import Image

STATES = [
    "drop_target", "unavailable", "increment", "decrement", "completed",
    "collapsed", "expanded", "unlocked", "selected", "pressed", "clicked",
    "focused", "disabled", "default", "warning", "success", "loading",
    "mastered", "available", "hover", "active", "locked", "error", "empty",
    "filled", "cooldown", "drag", "open", "closed", "on", "off",
    "up", "down", "left", "right", "new",
]
STATE_ALIASES = {"lod": "loading"}  # catalog abbreviations -> canonical state
FRAME_RE = re.compile(r"^(?P<stem>.+)_(?P<frame>\d+)$")

# Ordered: first keyword group found in the component name wins.
RULES = [
    (("divider",), {"nine_slice": False, "recommended_padding": 0, "scaling": "tile"}),
    (("background", "overlay_tile", "grid_cell", "grid_container"),
     {"nine_slice": False, "recommended_padding": 0, "scaling": "tile"}),
    (("thumb",), {"nine_slice": False, "recommended_padding": 2, "scaling": "stretch"}),
    (("track",), {"nine_slice": True, "recommended_padding": 4, "scaling": "stretch"}),
    (("bar", "meter", "loader"), {"nine_slice": True, "recommended_padding": 4, "scaling": "stretch"}),
    (("panel", "dialog", "modal", "window", "card", "banner", "toast", "snackbar",
      "tooltip", "sheet", "container", "box", "frame", "nameplate", "entry", "row",
      "header", "quest_log", "stepper_container"),
     {"nine_slice": True, "recommended_padding": 8, "scaling": "stretch"}),
    (("button", "tab", "chip", "input", "field", "select", "dropdown",
      "switch", "counter"),
     {"nine_slice": True, "recommended_padding": 8, "scaling": "stretch"}),
    (("slot", "node", "cell", "junction", "connector", "segment", "arrow", "dot"),
     {"nine_slice": False, "recommended_padding": 2, "scaling": "none"}),
    (("icon", "marker", "badge", "indicator", "spinner", "joystick", "dpad",
      "checkbox", "radio", "portrait"),
     {"nine_slice": False, "recommended_padding": 2, "scaling": "none"}),
]
DEFAULT = {"nine_slice": False, "recommended_padding": 4, "scaling": "none"}


def parse_name(stem):
    """Parse `{component}_{state}` and `{component}_{state}_{frame}` filenames."""
    candidates = [stem]
    m = FRAME_RE.match(stem)
    if m:  # animation frame: try the stem before the trailing frame number
        candidates.append(m.group("stem"))
    for cand in candidates:
        for state in STATES + list(STATE_ALIASES):  # longest first
            suffix = "_" + state
            if cand.endswith(suffix) and len(cand) > len(suffix):
                canonical = STATE_ALIASES.get(state, state)
                return cand[: -len(suffix)], canonical
    return stem, "default"


def defaults_for(component):
    if component.startswith("tile_"):  # e.g. tile_overlay_dimmed
        return {"nine_slice": False, "recommended_padding": 0, "scaling": "tile"}
    for keywords, rule in RULES:
        if any(k in component for k in keywords):
            return dict(rule)
    return dict(DEFAULT)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("assets_dir")
    p.add_argument("--out-json", required=True)
    p.add_argument("--out-csv")
    p.add_argument("--theme", default="")
    p.add_argument("--overrides", help="JSON: per-component field overrides")
    args = p.parse_args()

    overrides = {}
    if args.overrides:
        with open(args.overrides) as f:
            overrides = json.load(f)

    files = []
    for root, _, names in os.walk(args.assets_dir):
        files += [os.path.join(root, f) for f in sorted(names) if f.lower().endswith(".png")]
    files.sort()
    if not files:
        sys.exit(f"error: no PNG files under {args.assets_dir}")

    assets = []
    for path in files:
        rel = os.path.relpath(path, args.assets_dir)
        parent = os.path.dirname(rel)
        category = parent.replace(os.sep, "/") if parent else "uncategorized"
        stem = os.path.splitext(os.path.basename(path))[0]
        component, state = parse_name(stem)
        with Image.open(path) as im:
            w, h = im.size
        entry = {
            "component": component,
            "category": category,
            "state": state,
            "file": rel,
            "width": w,
            "height": h,
            "dimensions": f"{w}x{h}",
            "suggested_filename": f"{component}_{state}.png",
        }
        entry.update(defaults_for(component))
        if component in overrides:
            entry.update(overrides[component])
        assets.append(entry)

    per_category = {}
    for a in assets:
        per_category[a["category"]] = per_category.get(a["category"], 0) + 1
    manifest = {
        "theme": args.theme,
        "generated": date.today().isoformat(),
        "tile_grid": 32,
        "background": "#FF00FF",
        "transparent": False,
        "asset_count": len(assets),
        "categories": per_category,
        "assets": assets,
    }
    with open(args.out_json, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote {args.out_json}: {len(assets)} assets in {len(per_category)} categories")

    if args.out_csv:
        cols = ["component", "category", "state", "width", "height", "dimensions",
                "suggested_filename", "nine_slice", "recommended_padding", "scaling", "file"]
        with open(args.out_csv, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=cols)
            writer.writeheader()
            for a in assets:
                writer.writerow({c: a[c] for c in cols})
        print(f"wrote {args.out_csv}")


if __name__ == "__main__":
    main()
