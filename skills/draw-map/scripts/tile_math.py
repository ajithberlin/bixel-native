#!/usr/bin/env python3
"""
tile_math.py - Tiled GID flag encoding/decoding and pattern transformation math.

Supports all 8 orientations (D4 dihedral group) via Tiled flip flag bits:
  - GID_H_FLIP = 0x80000000 (bit 31, horizontal flip)
  - GID_V_FLIP = 0x40000000 (bit 30, vertical flip)
  - GID_D_FLIP = 0x20000000 (bit 29, diagonal flip / transpose)
"""

import sys
import json
import argparse
from typing import List, Tuple, Optional, Dict

GID_H_FLIP = 0x80000000
GID_V_FLIP = 0x40000000
GID_D_FLIP = 0x20000000
GID_FLAGS = GID_H_FLIP | GID_V_FLIP | GID_D_FLIP
GID_MASK = (~GID_FLAGS) & 0xFFFFFFFF

DIRECTIONS = {
    "normal": 0,
    "none": 0,
    "0": 0,
    "flip_h": GID_H_FLIP,
    "h": GID_H_FLIP,
    "flip_v": GID_V_FLIP,
    "v": GID_V_FLIP,
    "flip_d": GID_D_FLIP,
    "d": GID_D_FLIP,
    "transpose": GID_D_FLIP,
    "rot_90": GID_D_FLIP | GID_H_FLIP,
    "90": GID_D_FLIP | GID_H_FLIP,
    "90_cw": GID_D_FLIP | GID_H_FLIP,
    "rot_180": GID_H_FLIP | GID_V_FLIP,
    "180": GID_H_FLIP | GID_V_FLIP,
    "rot_270": GID_D_FLIP | GID_V_FLIP,
    "270": GID_D_FLIP | GID_V_FLIP,
    "90_ccw": GID_D_FLIP | GID_V_FLIP,
    "anti_transpose": GID_D_FLIP | GID_H_FLIP | GID_V_FLIP,
    "rot_90_flip_h": GID_D_FLIP | GID_H_FLIP | GID_V_FLIP,
}

CANONICAL_NAMES = {
    0: "normal",
    GID_H_FLIP: "flip_h",
    GID_V_FLIP: "flip_v",
    GID_D_FLIP: "flip_d",
    GID_D_FLIP | GID_H_FLIP: "rot_90",
    GID_H_FLIP | GID_V_FLIP: "rot_180",
    GID_D_FLIP | GID_V_FLIP: "rot_270",
    GID_D_FLIP | GID_H_FLIP | GID_V_FLIP: "anti_transpose",
}

CANONICAL_STATES = {
    "normal": 0,
    "flip_h": GID_H_FLIP,
    "flip_v": GID_V_FLIP,
    "flip_d": GID_D_FLIP,
    "rot_90": GID_D_FLIP | GID_H_FLIP,
    "rot_180": GID_H_FLIP | GID_V_FLIP,
    "rot_270": GID_D_FLIP | GID_V_FLIP,
    "anti_transpose": GID_D_FLIP | GID_H_FLIP | GID_V_FLIP,
}


def _transform_point(pt: Tuple[int, int], flags: int) -> Tuple[int, int]:
    """Applies Tiled GID flip flags to a reference 2D vector."""
    x, y = pt
    if flags & GID_D_FLIP:
        x, y = y, x
    if flags & GID_H_FLIP:
        x = -x
    if flags & GID_V_FLIP:
        y = -y
    return (x, y)


def compose_flags(f1: int, f2: int) -> int:
    """Compose two sets of flip flags (f1 followed by f2)."""
    # Reference vector with distinct non-zero coordinates
    test_pt = (1, 2)
    target = _transform_point(_transform_point(test_pt, f1), f2)
    for res_flags in CANONICAL_STATES.values():
        if _transform_point(test_pt, res_flags) == target:
            return res_flags
    return 0


def parse_direction(dir_name: str) -> int:
    """Parse a direction name or alias into its Tiled flag bitmask."""
    key = str(dir_name).strip().lower()
    if key in DIRECTIONS:
        return DIRECTIONS[key]
    try:
        val = int(key, 0)
        return val & GID_FLAGS
    except ValueError:
        raise ValueError(f"Unknown direction '{dir_name}'. Valid options: {list(DIRECTIONS.keys())}")


def encode_gid(local_id: int, first_gid: int = 1, direction: str = "normal", flags: int = 0) -> int:
    """Encode a local tile ID (0-indexed) into a raw Tiled GID with flip flags."""
    dir_flags = parse_direction(direction) if direction else 0
    total_flags = (flags | dir_flags) & GID_FLAGS
    raw_gid = (first_gid + local_id) & GID_MASK
    return (raw_gid | total_flags) & 0xFFFFFFFF


def decode_gid(gid: int, first_gid: int = 1) -> Tuple[int, int, str]:
    """
    Decode a raw Tiled GID into (local_id, flags, canonical_direction_name).
    Returns (-1, 0, 'empty') if gid == 0.
    """
    if gid == 0:
        return -1, 0, "empty"
    flags = gid & GID_FLAGS
    raw = gid & GID_MASK
    local_id = raw - first_gid
    dir_name = CANONICAL_NAMES.get(flags, f"custom_0x{flags:08x}")
    return local_id, flags, dir_name


def transform_tile(gid: int, op_name: str) -> int:
    """Transform a single GID with an operation, updating its flip flags."""
    if gid == 0:
        return 0
    raw = gid & GID_MASK
    flags = gid & GID_FLAGS
    op_flags = parse_direction(op_name)
    new_flags = compose_flags(flags, op_flags)
    return (raw | new_flags) & 0xFFFFFFFF


def transform_pattern(matrix: List[List[int]], direction: str = "normal") -> List[List[int]]:
    """
    Transforms a 2D tile matrix (both position arrangement AND individual tile flags)
    so stamped multi-tile structures orient correctly in all 8 directions.
    """
    if not matrix or not matrix[0]:
        return matrix

    dir_key = direction.lower().strip()
    if dir_key in ("normal", "none", "0"):
        return [row[:] for row in matrix]

    rows = len(matrix)
    cols = len(matrix[0])

    if dir_key in ("flip_h", "h"):
        return [[transform_tile(matrix[r][cols - 1 - c], "flip_h") for c in range(cols)] for r in range(rows)]

    if dir_key in ("flip_v", "v"):
        return [[transform_tile(matrix[rows - 1 - r][c], "flip_v") for c in range(cols)] for r in range(rows)]

    if dir_key in ("rot_90", "90", "90_cw"):
        # 90 deg clockwise: rotated element at (c, rows - 1 - r)
        return [[transform_tile(matrix[rows - 1 - r][c], "rot_90") for r in range(rows)] for c in range(cols)]

    if dir_key in ("rot_180", "180"):
        return [[transform_tile(matrix[rows - 1 - r][cols - 1 - c], "rot_180") for c in range(cols)] for r in range(rows)]

    if dir_key in ("rot_270", "270", "90_ccw"):
        # 270 deg clockwise: rotated element at (cols - 1 - c, r)
        return [[transform_tile(matrix[r][cols - 1 - c], "rot_270") for r in range(rows)] for c in reversed(range(cols))]

    if dir_key in ("flip_d", "d", "transpose"):
        res = [[0] * rows for _ in range(cols)]
        for r in range(rows):
            for c in range(cols):
                res[c][r] = transform_tile(matrix[r][c], "flip_d")
        return res

    raise ValueError(f"Unsupported pattern transformation direction: '{direction}'")


def run_tests():
    """Unit tests for tile_math operations."""
    print("Running tile_math self-tests...")

    # Test 1: GID encode & decode
    gid_normal = encode_gid(local_id=5, first_gid=1, direction="normal")
    assert gid_normal == 6, f"Expected 6, got {gid_normal}"
    loc, flags, name = decode_gid(gid_normal)
    assert loc == 5 and flags == 0 and name == "normal"

    gid_h = encode_gid(local_id=5, first_gid=1, direction="flip_h")
    assert gid_h == (6 | GID_H_FLIP)
    loc, flags, name = decode_gid(gid_h)
    assert loc == 5 and flags == GID_H_FLIP and name == "flip_h"

    gid_90 = encode_gid(local_id=5, first_gid=1, direction="rot_90")
    assert gid_90 == (6 | GID_D_FLIP | GID_H_FLIP)
    loc, flags, name = decode_gid(gid_90)
    assert loc == 5 and name == "rot_90"

    # Test 2: Sequential rotations
    flags = 0
    flags = compose_flags(flags, GID_D_FLIP | GID_H_FLIP)  # rot_90
    assert flags == (GID_D_FLIP | GID_H_FLIP), f"Expected rot_90, got 0x{flags:08x}"
    flags = compose_flags(flags, GID_D_FLIP | GID_H_FLIP)  # rot_90
    assert flags == (GID_H_FLIP | GID_V_FLIP), f"Expected rot_180, got 0x{flags:08x}"
    flags = compose_flags(flags, GID_D_FLIP | GID_H_FLIP)  # rot_90
    assert flags == (GID_D_FLIP | GID_V_FLIP), f"Expected rot_270, got 0x{flags:08x}"
    flags = compose_flags(flags, GID_D_FLIP | GID_H_FLIP)  # rot_90
    assert flags == 0, f"Expected 0 (360 deg), got 0x{flags:08x}"

    # Test 3: Pattern transform 2x3 matrix
    # [ [1, 2, 3],
    #   [4, 5, 6] ]
    pattern = [[1, 2, 3], [4, 5, 6]]
    flipped_h = transform_pattern(pattern, "flip_h")
    assert len(flipped_h) == 2 and len(flipped_h[0]) == 3
    assert (flipped_h[0][0] & GID_MASK) == 3
    assert (flipped_h[0][0] & GID_H_FLIP) != 0
    assert (flipped_h[0][2] & GID_MASK) == 1

    rot90 = transform_pattern(pattern, "rot_90")
    assert len(rot90) == 3 and len(rot90[0]) == 2
    assert (rot90[0][0] & GID_MASK) == 4
    assert (rot90[0][0] & GID_FLAGS) == (GID_D_FLIP | GID_H_FLIP)
    assert (rot90[2][1] & GID_MASK) == 3

    print("All tile_math tests passed successfully! ✓")


def main():
    parser = argparse.ArgumentParser(description="Tiled GID flag encoding/decoding and pattern math.")
    parser.add_argument("--test", action="store_true", help="Run internal unit tests")
    parser.add_argument("--encode", type=int, help="Local tile ID to encode")
    parser.add_argument("--first-gid", type=int, default=1, help="First GID of the tileset (default 1)")
    parser.add_argument("--dir", type=str, default="normal", help="Direction: normal, flip_h, flip_v, rot_90, rot_180, rot_270")
    parser.add_argument("--decode", type=lambda s: int(s, 0), help="Raw GID (decimal or 0xhex) to decode")
    parser.add_argument("--transform-pattern", type=str, help="JSON 2D array of GIDs to transform")
    args = parser.parse_args()

    if args.test:
        run_tests()
        sys.exit(0)

    if args.encode is not None:
        gid = encode_gid(args.encode, first_gid=args.first_gid, direction=args.dir)
        print(json.dumps({
            "local_id": args.encode,
            "direction": args.dir,
            "gid": gid,
            "gid_hex": f"0x{gid:08x}"
        }, indent=2))
        return

    if args.decode is not None:
        loc, flags, name = decode_gid(args.decode, first_gid=args.first_gid)
        print(json.dumps({
            "raw_gid": args.decode,
            "raw_gid_hex": f"0x{args.decode:08x}",
            "local_id": loc,
            "direction": name,
            "flags_hex": f"0x{flags:08x}"
        }, indent=2))
        return

    if args.transform_pattern:
        mat = json.loads(args.transform_pattern)
        res = transform_pattern(mat, args.dir)
        print(json.dumps(res))
        return

    parser.print_help()


if __name__ == "__main__":
    main()
