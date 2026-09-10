# Task 2: Floating import lifecycle report

## Summary

Implemented the transient floating-image import lifecycle in `EditorModel`.
Native RGBA source data, source dimensions, target, and transform state now
remain outside `Document` until an explicit commit. New-frame imports retain
the active layer target; dropped PNG assets retain their top-left intent as a
center point. Commit rasterizes exactly once to the document dimensions and
creates one undoable document mutation. Cancel only discards transient state.

The model also now exposes separate floating move, resize, rotation, hit-test,
and nudge methods. Resize operates in the oriented local coordinate system and
keeps the opposite handle edge/corner fixed. Rotation accumulates wrapped
incremental angular deltas in document-space Y-down coordinates.

## Files changed

- `app/Bixel/Models/EditorModel.swift`
  - Added `FloatingImportTarget`, `FloatingImageImport`, published pending
    state, floating gesture state/methods, validation, commit/cancel lifecycle,
    and transient routing for `placeAsset` and `applyImageToNewFrame`.
- `tests/EditorInteractionTests.swift`
  - Replaced immediate-import assertions with lifecycle coverage for source
    retention, active-layer targeting, top-left drop centering, cancellation,
    commit/undo behavior, clipping at commit, and scaled commit placement.

## TDD evidence

### RED

Added lifecycle tests before the production lifecycle implementation, then ran:

```bash
bash scripts/test-interactions.sh
```

The expected initial failure was compilation errors for absent lifecycle APIs,
including:

```text
value of type 'EditorModel' has no member 'floatingImport'
value of type 'EditorModel' has no member 'cancelFloatingImport'
value of type 'EditorModel' has no member 'commitFloatingImport'
value of type 'EditorModel' has no member 'beginFloatingResize'
```

### GREEN / final verification

After the minimal implementation and self-review, reran the required command:

```bash
bash scripts/test-interactions.sh
```

Exact final test line and exit status:

```text
Editor interaction tests passed
exit code: 0
```

The full Swift compile/link also emitted existing environment warnings: one
unused local in `TileMapPanels.swift`, plus linker warnings that objects in
`generated/libbixel.a` target macOS 26.x while the test links for macOS 13.0.

## Self-review

- Pending begin/cancel flows invoke no document snapshot, frame/layer API, or
  pixel write.
- New-frame commit snapshots once before adding a 125 ms frame and writes only
  the captured target layer. New-layer commit relies on the existing
  `placeImageData` single-snapshot contract, preventing a duplicate undo step.
- Both commit targets validate that their captured document destination still
  exists; a validation/rasterization/placement failure retains the pending
  source and sets `operationError`.
- Commit reloads layers and notifies document changes once, after a successful
  operation. Existing current-frame replacement behavior remains unchanged.
- No CanvasView, ContentView, SelectionTransformUI, palette, or cursor changes
  were made. Unrelated working-tree changes in project/publish scripts were
  not staged or modified.

## Commit

Implementation commit: `040fa54f7f0a77b49a829165bbac84800f9c0358`

## Concerns

- The focused test suite passes, but its compile/link phase has the pre-existing
  macOS version and unused-local warnings noted above.
- Task 2 intentionally adds model behavior only; rendering and UI gesture
  routing remain for later tasks.
