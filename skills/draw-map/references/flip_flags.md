# Tiled Flip & Direction Bitmask Reference

Tiled and Bixel store tile orientation in the highest 3 bits of the 32-bit cell integer (raw GID):

```
Bit 31: 0x80000000 (GID_H_FLIP) - Horizontal mirror
Bit 30: 0x40000000 (GID_V_FLIP) - Vertical mirror
Bit 29: 0x20000000 (GID_D_FLIP) - Diagonal mirror (anti-diagonal / transpose)
```

The lower 29 bits store the raw tile ID:
`raw_gid = gid & 0x1FFFFFFF`

## The 8 Canonical Orientations (D4 Symmetry Group)

| Direction Name | Bitmask (Hex) | Flag Combination | Visual Effect |
|---|---|---|---|
| `normal` / `none` | `0x00000000` | None | Original tile unchanged |
| `flip_h` | `0x80000000` | `GID_H_FLIP` | Left ↔ Right mirror |
| `flip_v` | `0x40000000` | `GID_V_FLIP` | Top ↔ Bottom mirror |
| `flip_d` / `transpose` | `0x20000000` | `GID_D_FLIP` | Swap X and Y axes |
| `rot_90` / `90_cw` | `0xA0000000` | `GID_D_FLIP \| GID_H_FLIP` | 90° Clockwise rotation |
| `rot_180` | `0xC0000000` | `GID_H_FLIP \| GID_V_FLIP` | 180° Half-turn |
| `rot_270` / `90_ccw` | `0x60000000` | `GID_D_FLIP \| GID_V_FLIP` | 270° Clockwise (90° CCW) |
| `anti_transpose` | `0xE0000000` | `GID_D_FLIP \| GID_H_FLIP \| GID_V_FLIP` | 90° Clockwise + Horizontal flip |

## Isometric Flipping Rules

- **Horizontal Flip (`flip_h`)**:
  - In an isometric tile, horizontal flip mirrors pixels across the vertical center line.
  - A West-facing wall or slope becomes an East-facing wall or slope.
  - Roof slopes on the left side mirror to roof slopes on the right side.
- **Pattern Flipping**:
  - When stamping a multi-tile structure (e.g. a 3×3 building), flipping the pattern flips both the grid positions of the cells AND the individual tile orientations inside the pattern using `transform_pattern(matrix, direction)`.
