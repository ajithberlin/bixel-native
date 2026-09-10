# Unified Normal and Map Workspace Design

## Goal

Simplify Bixel's workspace model to two user-facing modes:

- **Normal** — one pixel editor for images, sprites, animations, tiles, and
  other raster work. The same brush, selection, transform, layers, and
  animation tools are available regardless of the document's content.
- **Map** — the Tilemap Designer for tile stamping, map layers, map selection,
  terrain/wand tools, and map export.

At the same time, fix the reported editor-state bugs and finish the
Procreate-inspired selection and asset-panel interaction.

## Current root causes

The current code uses `AssetKind` as both metadata and a routing switch. This
causes normal documents such as images, sprites, animations, and tilesets to
present different creation and editor affordances. `ContentView` and
`TopBar` correctly route maps separately, but normal documents are still
filtered by kind in several controls.

The reported bugs have concrete causes:

1. `CanvasView` only creates the pixel grid when `viewport.zoom >= 6`, making
   the grid invisible on large canvases at fit-to-window zoom.
2. `EditorModel.selectTool` ends an active resize but leaves
   `selectionRect`/`transformRect` intact when switching to a non-selection
   tool.
3. Animation Assist is gated behind a local `showTimeline` state that defaults
   to `false` and is only exposed through the Actions popover. Its rendering is
   also coupled to the old document-kind eligibility property.
4. `ProjectAssetsPanel` is permanently mounted as a left sibling of the
   editor, so it cannot collapse like the AI pane.

## Data model and migration

Introduce a small persisted `WorkspaceMode` enum with `.normal` and `.map`.
`WorkspaceDocument` will store `mode` instead of the functional `AssetKind`
split. Normal documents use pixel width/height; map documents use columns,
rows, and cell dimensions.

Existing workspace files remain readable through a custom `Decodable` path:

- an existing `kind == "map"` becomes `.map`;
- every other old kind (`sprite`, `image`, `animation`, `spritesheet`, or
  `tileset`) becomes `.normal`;
- new writes encode only the two-mode representation;
- the workspace catalog schema advances to `2`, while schema `1` is accepted
  during load and rewritten on the next save.

Remove `AssetKind` from project creation, recent-project badges, AI mode chips,
template metadata, and editor routing. Existing content-specific names and
descriptions may remain as ordinary project/document names. Animation Assist is
eligible for every normal document and never for maps.

The `ProjectStore` API will accept `WorkspaceMode` instead of `AssetKind`.
Normal project creation will not ask whether the project is a sprite,
animation, image, or tileset. It will offer dimensions and optional presets;
frames are added from the normal editor's Animation Assist. Map creation will
offer map dimensions and cell size.

AI creation will infer only the workspace mode: prompts that clearly request a
map open a map project, and all other prompts open a normal project. Sample
art generation will continue to use names and dimensions to choose preview
content, not a project type.

## Editor routing and bug fixes

`ContentView` will route only on `projects.isMapActive`:

- normal mode always mounts `CanvasView`, the brush dock, layers/color
  controls, selection/transform controls, Animation Assist, and the normal
  asset drawer;
- map mode always mounts `TileMapCanvasView`, map tools, tileset palette, map
  layers, and map commands.

Selection state will be treated as one tool family. Switching between
Selection and Transform preserves the active marquee. Switching from either to
any normal drawing/tool action clears the marquee and pending resize state.
The Escape key continues to clear it explicitly. This prevents stale overlay
boxes after changing tools while retaining the expected selection-to-transform
handoff.

The grid will use adaptive spacing. At high zoom it remains a per-pixel grid;
at lower zoom it switches to a legible guide grid with a bounded number of
lines, so the Drawing Guide / Grid toggle has visible feedback at fit-to-canvas
scale without attempting to draw thousands of sub-pixel lines. The pure grid
spacing calculation will be isolated so it can be tested without AppKit.

Animation Assist will get a direct film-strip button in the normal top bar.
Normal documents will show the timeline when enabled; animation-like content
is represented by frame count rather than a project type. Opening an animation
document with multiple frames will enable the timeline by default, while the
button remains available for all normal documents. The timeline will stay in a
dedicated bottom chrome region above the ad, so selection controls and ads
cannot overlap or push it off-screen.

## Selection and transform visual design

The selection HUD keeps Bixel's dark workspace and blue accent, with one
purposeful secondary accent: a warm gold rotation handle, matching the
reference image and making rotation distinct from resizing.

```text
             │
             ●  gold rotation handle
             │
      ○──────┼──────○
      │      │      │
      ○──────┼──────○
```

- blue dashed boundary with a subtle translucent selection wash;
- four corner handles plus four midpoint handles with larger invisible hit
  regions;
- gold circular rotation handle above the top midpoint, connected by a short
  stem;
- dragging the gold handle snaps to the nearest quarter turn because the
  current Rust document transform is intentionally pixel-art-safe and supports
  rotations `0...3` only;
- move and resize continue to commit on mouse-up; there are no Cancel or Apply
  buttons;
- the floating toolbar keeps grouped controls for Selection/Transform,
  Freeform/Uniform, Snapping, Rotate 90°, Fit, and Reset, with compact labels,
  active blue states, and keyboard/tooltips.

The overlay is deliberately sparse: the gold rotation affordance is the one
new visual signature, while the rest uses existing `StudioTheme` surfaces and
hairlines.

## Collapsible project assets drawer

The project asset library becomes a sibling pane that is hidden by default.
The normal and map top bars receive an asset-library button using the existing
stacked-squares visual language, placed beside the AI control. Its state is
owned by `ContentView`, just like `showAI`.

```text
┌──────────────┐  ┌──────────────────────────────┐
│ Project      │  │                              │
│ Assets       │  │        editor / map          │
│ documents    │  │                              │
│ generated    │  │                              │
└──────────────┘  └──────────────────────────────┘
       ▲
       └── toolbar stack button toggles the drawer
```

When opened, the drawer uses the current 292-point panel, project/document
search, asset filters, previews, and existing drag/drop actions. It transitions
from the leading edge and reserves layout width rather than covering the
canvas. Closing it keeps the selected asset state local to the panel instance.
The map's tileset panel remains part of the map editor; the project drawer is
for project documents and reusable/generated files.

## Testing and verification

Add or update focused tests for:

- legacy `AssetKind` values decoding into the correct two-mode representation;
- normal documents all being Animation Assist eligible and maps not being
  eligible;
- selection state clearing on tool-family exit while preserving
  Selection-to-Transform handoff;
- adaptive grid spacing at fit zoom and per-pixel spacing at high zoom;
- normal and map project creation producing the correct workspace mode and
  loading old catalogs without data loss.

Run the Rust baseline and full `bixel-core` suite, the focused Swift metadata
and interaction harnesses, `git diff --check`, and an Xcode build when the
local Apple toolchain is available. Manual verification should cover: grid
toggle at fit zoom, selecting then switching to pencil, opening Animation
Assist on a normal image, dragging the gold rotation handle, and opening /
closing the asset drawer in both normal and map workspaces.

