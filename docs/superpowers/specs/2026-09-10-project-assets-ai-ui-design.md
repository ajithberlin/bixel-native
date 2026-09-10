# Project Assets, AI Control, and Animation Assist Design

**Date:** 2026-09-10  
**Status:** Approved for implementation  
**Scope:** Native SwiftUI workspace shell and project-cache persistence

## Goal

Make generated images durable and discoverable in the active project, restore a reliable Animation Assist presentation after the ad banner was introduced, and add a left-docked project asset browser with drag-and-drop placement.

## Architecture

The Rust storage gateway remains the only filesystem boundary. `AssistantSession` owns the lifecycle of generated artifacts and writes them below the active project’s `.studio/cache/ai/<conversation-id>/` directory; `ProjectStore` continues to enumerate `.studio/cache` and `assets` and publishes the combined inventory. SwiftUI owns the new left asset dock and its visual states, while the existing AppKit canvas continues to receive whole PNG payloads and place them through `EditorModel.placeAsset`.

The workspace becomes a three-region horizontal shell when a project is open:

```text
┌────────────── Project Assets ──────────────┬──────────── editor ────────────┬──── AI Agent ────┐
│ search / filters                            │ top chrome                     │ transcript       │
│ Documents                                   │ canvas                         │                  │
│ Project assets                              │ timeline + ad-safe footer      │ composer         │
└─────────────────────────────────────────────┴────────────────────────────────┴──────────────────┘
```

The asset dock is always visible while a project is open. It is not a floating overlay and does not hide the existing map tileset palette or sprite tool dock. It uses a fixed width with a minimum workspace width already guaranteed by `ContentView`.

## Storage behavior

1. Direct local-skill outputs continue to write into the conversation cache.
2. Streamed/model-backed `artifact` events are written into the same conversation cache before the assistant session finishes.
3. Artifact names are sanitized and made collision-safe with a generated prefix. Existing cache files are never overwritten.
4. The persisted relative path is used for the asset inventory and for later reads; the chat transcript retains the artifact data for immediate rendering.
5. The asset inventory refreshes after artifact persistence completes. A persistence failure is surfaced as a project error and does not silently claim that the asset was saved.

## Asset dock behavior

The dock contains:

- A header with the project name, item count, and refresh action.
- Search plus source filters for `All`, `Images`, and `Files`.
- A Documents section. Clicking a document opens it; its kind symbol and summary remain visible.
- An Assets section. Accepted `assets/` content and generated `.studio/cache` content appear together. Cache items show a generated badge; accepted items show a project badge.
- A compact image grid/list with nearest-neighbor thumbnails. Selecting an item reveals a preview and actions: open as image, add as layer, use as assistant reference, slice as animation frames when dimensions allow, and promote a generated file into `assets/`.

Image entries provide a PNG drag provider. The existing sprite canvas accepts this provider and places the whole decoded image at the pointer location. Text/code files remain selectable and previewable but are not draggable onto the pixel canvas.

## AI control

The AI button moves after the color palette control in the sprite right tool cluster. It uses an animated sparkle icon: a slow, subtle rotation/pulse while the panel is closed, a brighter green/blue treatment while open, and a static accessible label/tooltip. Motion is limited to this single focal control and is disabled when the system requests reduced motion.

## Animation Assist

The timeline remains controlled by `showTimeline` and the Actions popover. The bottom chrome is split into independent layers so an ad cannot consume or cover the timeline’s presentation region. The timeline keeps its current frame controls and is shown for sprite, animation, spritesheet, and image documents; maps and tilesets do not expose Animation Assist. The ad is placed in a separate safe-area footer below it.

## Error handling

- Missing or unreadable assets use the existing project error alert.
- Oversized files keep the current 32 MB project read limit and 5 MB assistant attachment limit.
- A failed cache write emits an assistant error event and leaves the in-memory artifact visible, but the item is not added to the asset inventory.
- Dragging a non-image asset is rejected without changing the document.

## Testing

- Add a Swift test helper/coverage for the canonical generated-artifact cache path and filename sanitization/collision behavior where the existing lightweight test harness can exercise it.
- Add a Swift regression assertion that the Animation Assist eligibility predicate is true for animation-capable documents and false for maps/tilesets.
- Run the targeted Swift assistant/interaction harnesses, Rust core tests, and a native Debug build where the environment permits. Existing unrelated baseline failures must be reported separately from regressions introduced by this work.

