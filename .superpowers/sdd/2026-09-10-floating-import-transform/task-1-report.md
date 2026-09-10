# Task 1 report

## Summary

Implemented the Swift-only transform foundation for floating oversized-image
imports. `TransformGeometry` now provides oriented transform-box points,
rotation-handle placement, inverse-rotated containment, and local coordinates.
`AIService.rasterizeNativeImage` performs bulk inverse nearest-neighbour
rasterization into a transparent destination without modifying or pre-cropping
the source.

## Files changed

- `app/Bixel/Models/EditorModel.swift`
  - Added internal `TransformGeometry`.
- `app/Bixel/Models/AIService.swift`
  - Added internal `rasterizeNativeImage`.
- `tests/EditorInteractionTests.swift`
  - Added failing-first geometry, rotation-handle hit-testing, rotation,
    transparency, oversized-source, and scale assertions.

The pre-existing edits in `scripts/publish-appstore.sh` and
`scripts/test-publish-appstore.sh` were preserved and not staged.

## Design decisions

- Kept all geometry in document-space y-down coordinates; positive angles use
  the existing clockwise visual convention.
- Rotated local handle/corner coordinates around `center`; containment and
  `localPoint` inverse-rotate by `-angle`.
- Used the existing tiny-artwork-friendly handle distance:
  `max(18, min(36, size.height * 0.3))`.
- Rasterization scans every destination pixel center, inverse-rotates and
  unscales it, uses source image-center coordinates, and copies complete RGBA
  pixels with nearest-neighbour indexing. Destination storage starts fully
  transparent, and invalid source inputs return that valid transparent buffer.
- No floating-import lifecycle, CanvasView, toolbar, or palette behavior was
  added.

## Exact test command/output

Command:

```bash
bash scripts/test-interactions.sh
```

Output:

```text
app/Bixel/Views/TileMap/TileMapPanels.swift:417:40: warning: value 'local' was defined but never used; consider replacing with boolean test [#no-usage]
 415 |                             let local = slots[mask]
 416 |                             Button {
 417 |                                 if let local {
     |                                        `-` warning: value 'local' was defined but never used; consider replacing with boolean test
 418 |                                     model.setTilesetAutotile(tileset: ts.index, mask: mask, local: nil)
 419 |                                 } else {
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[23](a1edd97dd51cd48d-blake3_neon.o)) was built for newer 'macOS' version (26.5) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[461](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.016.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[587](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.142.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[589](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.144.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[625](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.180.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[626](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.181.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[635](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.190.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[636](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.191.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[638](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.193.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[648](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.203.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
ld: warning: object file (/Users/ajithberlin/Documents/GitHub/bixel-native/generated/libbixel.a[667](compiler_builtins-28935136ed986f39.compiler_builtins.bb8f0d37d096e781-cgu.222.rcgu.o)) was built for newer 'macOS' version (26.0) than being linked (13.0)
Editor interaction tests passed
```

The command exited with status `0`.

## Self-review

- Confirmed the new tests failed before production symbols existed.
- Confirmed the focused script passed after implementation.
- Confirmed `git diff --cached --check` passed before commit.
- Confirmed the implementation commit contains only the three requested source
  and test files.
- Confirmed oversized inputs are read directly and the source array is never
  written by the helper.

## Commit hash

Implementation commit: `8c5534bc44f8691c5e253008bba5fce72736d014`

## Concerns

- The focused script still emits an existing unused-binding Swift warning and
  macOS deployment-version linker warnings from the staged Rust static library.
- Existing EditorModel/CanvasView transform presentation remains axis-aligned;
  integrating the new shared geometry belongs to the later tasks explicitly
  excluded from Task 1.
