# Bixel Studio — Native (Rust + Swift + Metal)

A native Apple (macOS-first) port of **Bixel Studio**, the 2D game-asset studio.
The original tool was a Python/FastAPI backend with a zero-dependency browser
frontend; this project reimplements it as a **Rust core + SwiftUI/Metal
frontend**, keeping the headless domain logic in a platform-independent Rust
crate so the same engine can later drive Web (WebGPU), Windows/Linux (Tauri),
or iPadOS.

```
Swift / SwiftUI          Metal                    Rust core
┌──────────────┐    ┌──────────────┐    ┌────────────────────────┐
│ window/menus │    │ MTKView      │    │ document (layers/cels) │
│ gestures     │───▶│ texture blit │◀───│ palette                │
│ Pencil/touch │    │ nearest      │    │ timeline (playback)    │
│ timeline UI  │    │ sampling     │    │ tilemap (paint/fill)   │
└──────────────┘    └──────────────┘    │ atlas / map validation │
             │                           │ projects / sources     │
             │                           │ config / jobs          │
             ▼                           └───────────┬────────────┘
         AI panel (Swift)                             │
                                                       ▼
                                            bixel-ai (goose agent)
                                            └─ OpenRouter (text/vision/image)
```

## Why this split

The browser owns pixels; the engine owns data. In the Rust port the same rule
becomes **"Swift sends a command, Rust processes a whole buffer."**

* The Swift layer never touches individual pixels — it calls
  `Document.composite(frame:)` and hands the returned RGBA buffer to Metal as a
  single texture upload. Drawing gestures become one stroke FFI call, not
  per-pixel calls.
* Undo/redo, compositing, blend modes, brush strokes, tile flood-fill, palette
  math, path jailing, project/config state, and job execution all live in Rust.
* Swift talks to Rust through a small, hand-written `extern "C"` ABI
  (`crates/bixel-ffi`) with a cbindgen-generated header. No codegen runtime, no
  per-pixel FFI traffic.
* The AI assistant (`bixel-ai`) embeds the **full goose agent** (`goose`) — its
  agent loop, tool-calling, extension and skill systems — over the **OpenRouter**
  provider, and exposes Bixel's pixel-art *skills* as goose tools.

## Quick start

The primary interface is the **macOS app** (`app/Bixel`, SwiftUI + Metal). The
AI assistant panel (sparkles button) drives the embedded goose agent directly.

```bash
cp .env.example .env   # add your OPENROUTER_API_KEY
xcodegen generate
open Bixel.xcodeproj
```

Image generation uses OpenRouter's `/api/v1/images` endpoint, while chat and
vision go through the embedded goose agent's OpenRouter provider.

## Repository layout

```
Cargo.toml                 # Cargo workspace
project.yml                # XcodeGen spec (generates Bixel.xcodeproj)
cbindgen.toml              # header generation config
.env.example               # AI model/key template (copy to .env)
crates/
  bixel-core/              # platform-independent domain engine (no UI, no I/O beyond fs)
    src/
      document.rs          # AsepriteDoc: cels, layers, frames, tags, undo, composite, strokes
      palette.rs           # DB32 / PICO-8 / Game Boy presets + color math
      timeline.rs          # playback controller (loop modes, tags, onion skin)
      tilemap.rs           # tile paint math, flood fill, patterns, autotile, minimap
      atlas.rs             # sprite-sheet atlas schema validation
      map_validate.rs      # Tiled map continuity/structural validation (Bonfire)
      paths.rs             # app-home resolution + path jail
      project.rs           # project create/load/list/delete + active state
      sources.rs           # in-place source references
      clipboard.rs         # per-project asset tray
      config.rs            # AI provider config + token storage
      audits.rs            # persisted validation reports
      jobs.rs              # subprocess execution queue (cancel, logs)
    tests/                 # integration tests
  bixel-ai/                # embedded goose agent → OpenRouter + pixel-art skills
    src/
      agent.rs             # GooseAgent: builds goose Agent, drives reply(), event mapping
      config.rs            # .env settings + goose env wiring (OpenRouter provider)
      skill_server.rs      # rmcp extension exposing skills as the `run_skill` tool
      image_gen.rs         # OpenRouter image endpoints (text/image → image)
      skills.rs            # skill registry + prompts + dispatch
      image.rs             # PNG encode/decode, quantize, background removal, slicing
      native_stream.rs     # NativeEvent/NativeRequest FFI contract
  bixel-ffi/               # C ABI over bixel-core + bixel-ai
    src/lib.rs             # extern "C" functions + opaque handles
app/
  Bixel/                   # SwiftUI + Core Animation frontend (Procreate-style)
    BixelApp.swift
    Theme.swift            # dark design system
    Models/                # Document/Timeline wrappers, EditorModel, AIService
    Views/                 # ContentView, TopBar, ToolRail, CanvasView (Core Animation CALayer),
                           #   RightPanel, ColorDisc, TimelineBar, AIPanel
    Support/               # bridging header
skills/                    # skill manifests (JSON)
scripts/
  build-rust.sh            # cargo build + cbindgen + stage artifacts
generated/                 # (gitignored) libbixel.a + bixel.h
```

## Prerequisites

* **Rust** toolchain (`rustup` recommended, or `brew install rust`).
* **cbindgen** — `cargo install cbindgen` (or `brew install cbindgen`).
* **XcodeGen** — `brew install xcodegen`.

## AI assistant (goose + OpenRouter)

The AI engine (`crates/bixel-ai`) embeds the goose agent and points it at
OpenRouter's OpenAI-compatible gateway via the environment. Configure it with a
`.env` file:

```bash
cp .env.example .env   # then edit and add your key
```

```dotenv
OPENROUTER_API_KEY=sk-or-...
BIXEL_TEXT_MODEL=meta/muse-spark-1.3
BIXEL_VISION_MODEL=deepseek/deepseek-v4-flash-vision-exp
BIXEL_IMAGE_MODEL=google/gemini-3-pro-image
```

The built-in **skills**:

| Skill | Model | What it does |
|-------|-------|--------------|
| `generate_art` | image | text → pixel art |
| `spritesheet` | image | text → spritesheet grid, sliced into frames |
| `next_frame` | image | current frame → predicted next frame |
| `compress` | *local* | reduce to `2^bits` colors (median-cut) |
| `remove_background` | *local* | strip a near-uniform background |

Local skills need no network and run on-device; model skills require the key.
The AI panel (sparkles button) exposes all of them in the UI.

## Build & run

```bash
# 1. Generate the Xcode project
xcodegen generate

# 2. Open and run (or build from the CLI)
open Bixel.xcodeproj
#    …or…
xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug \
  -destination 'platform=macOS' build

# 3. Package DMG installer
scripts/package-dmg.sh --version v1.0.0 --build
```

The DMG is written to `build/dist/Bixel-v1.0.0.dmg` with an accompanying `.sha256` checksum.
You can also trigger builds and GitHub Releases automatically using the `.github/workflows/release.yml`
workflow (via GitHub Actions `workflow_dispatch` or by pushing a `v*` tag).

The Xcode build runs `scripts/build-rust.sh` as a pre-build phase, which builds
the Rust core (`cargo build --release -p bixel-ffi`), generates `generated/bixel.h`
via cbindgen, and stages `generated/libbixel.a`. The app links the static
library (plus `Security`/`CoreFoundation`, needed by rustls) and imports the
header through `app/Bixel/Support/Bixel-Bridging-Header.h`.

Build the Rust pieces directly without Xcode:

```bash
scripts/build-rust.sh              # build + stage
scripts/build-rust.sh --universal  # fat arm64+x86_64 lib (macOS)
```

## Testing

```bash
# Rust core (headless domain logic)
cargo test -p bixel-core

# AI engine (local skills + provider construction)
cargo test -p bixel-ai
```

Swift types can be checked against the generated header without a full app build:

```bash
SDK=$(xcrun --sdk macosx --show-sdk-path)
swiftc -typecheck -sdk "$SDK" -target arm64-apple-macosx13.0 \
  -import-objc-header app/Bixel/Support/Bixel-Bridging-Header.h \
  -I generated app/Bixel/**/*.swift
```

## FFI design

`crates/bixel-ffi/src/lib.rs` exposes opaque handles
(`BixelDoc`, `BixelTileLayer`, `BixelTimeline`) backed by `Arc<Mutex<_>>`, so
they are thread-safe and shareable between the document and its timeline. The
rules that keep the boundary cheap:

1. **Bulk buffers, not per-pixel calls** — `bixel_doc_composite` writes a whole
   frame into a caller-owned buffer; a brush stroke is one
   `bixel_doc_stroke` call with a point array.
2. **Strings are caller-freed** — `bixel_string_free` releases any returned
   `char*`.
3. **No secrets cross the boundary** — config/keys live in `config.rs` and are
   exposed only via masked status (see `masked_config`).

## Status / roadmap

* ✅ Implemented and tested: document model (incl. brush strokes + flood fill),
  palette, timeline, tilemap, atlas/map validation, path jail, projects, sources,
  clipboard, config, audits, jobs, the full FFI, the Procreate-style SwiftUI/Metal
  app, and the embedded goose agent with pixel-art skills exposed as goose tools.
* 🔮 Future: iPadOS/iOS targets (the Rust core and Metal renderer are already
  platform-neutral), Web/WebGPU and Tauri shells reusing `bixel-core`.

## Security notes

The original "server owns disk, processes, and secrets" rule carries over:
* `paths::safe_resolve` strictly jails every path within its base (project or
  workspace), rejecting `..` traversal, absolute paths and symlink escapes.
* API keys live in `.env` (gitignored) and are resolved by the goose agent's
  config (env-var precedence); the frontend only ever sees masked key status.
* Snapshot/backup semantics (write-backups under `.studio/backups/`) are the
  intended next addition on top of the existing in-place source model.

