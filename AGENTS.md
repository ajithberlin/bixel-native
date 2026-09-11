# AGENTS.md

Context file for AI coding agents working on **Bixel Studio (native)** — the
Rust + Swift/Metal port of the web studio. Read this first.

## What this is

A native Apple (macOS-first) reimplementation of Bixel Studio, the 2D game-asset
studio. The original was a Python/FastAPI backend + zero-dependency browser
frontend in `tools/studio/`; this project moves the *headless* domain logic into
a platform-independent Rust crate and the UI into SwiftUI + Metal.

Architecture contract:

```
Swift / SwiftUI  →  Metal (MTKView)  →  Rust core (bixel-core)
                                        ↑
                                   cbindgen C ABI (bixel-ffi)
```

- **Swift sends a command; Rust processes a whole buffer.** Never move pixels
  across the FFI boundary one at a time — composite whole frames, upload once.
- **The Rust core is UI-free and I/O-free except the filesystem.** It must stay
  testable under `cargo test` with no Apple SDK.

## Stack

- **Rust** (`crates/bixel-core`, `crates/bixel-ai`, `crates/bixel-ffi`) — edition
  2021, Cargo workspace. `bixel-core` is the domain engine; `bixel-ai` embeds the
  **full goose agent** (`goose` crate, git dep on `aaif-goose/goose`) over the
  OpenRouter provider and exposes pixel-art skills as a goose tool extension;
  `bixel-ffi` is the hand-written `extern "C"` ABI over both.
- **Swift** (`app/Bixel/`) — SwiftUI + MetalKit, macOS 13+, Procreate-style dark
  UI. No package manager beyond the Xcode project (generated from `project.yml`
  via XcodeGen).
- **XcodeGen** — `project.yml` is the source of truth; `Bixel.xcodeproj` is
  generated (gitignored). A pre-build phase runs `scripts/build-rust.sh`.
- **goose** requires linking `Security` + `CoreFoundation` frameworks
  (rustls-platform-verifier); already wired in `project.yml`. `goose` is built
  with `default-features = false, features = ["rustls-tls"]` (aws-lc-rs → cmake).

## Repo map

```
project.yml          # XcodeGen spec (generates the .xcodeproj)
cbindgen.toml        # header generation
scripts/build-rust.sh  # cargo build --release + cbindgen + stage into generated/
crates/bixel-core/   # platform-independent domain logic (+ tests/)
crates/bixel-ai/     # embedded goose agent → OpenRouter + skills (+ tests/)
crates/bixel-ffi/    # C ABI layer (core + ai)
app/Bixel/           # SwiftUI + Metal frontend
skills/              # agent skill packages (SKILL.md + scripts) + image-skill JSON mirrors
generated/           # (gitignored) staged libbixel.a + bixel.h
```

Module → original Python/JS source (porting reference):

| Rust | Original |
|------|----------|
| `document.rs` | `web/aseprite/document.js` |
| `palette.rs` | `web/aseprite/palette.js` |
| `timeline.rs` | `web/aseprite/timeline.js` |
| `tilemap.rs` | `web/mapcore.js` |
| `map.rs` | *(new — Tilemap Designer: Tiled JSON editor engine, no web origin)* |
| `atlas.rs` | `core/atlases.py` |
| `sheet.rs` | *(new — spritesheet import planner: Bixel-export / atlas / grid manifests → frames + tags)* |
| `map_validate.rs` | `core/maps.py` |
| `paths.rs` | `core/paths.py` |
| `project.rs` | `core/projects.py` |
| `sources.rs` | `core/sources.py` |
| `clipboard.rs` | `core/clipboard.py` |
| `config.rs` | `core/config.py` |
| `audits.rs` | `core/audits.py` |
| `jobs.rs` | `core/jobs.py` |
| `bixel-ai/*` | `core/ai.py` + `core/agent.py` + `skills/` |

## AI / skills

The AI engine (`bixel-ai`) embeds the full goose agent (`goose` crate): it builds
a `goose::agents::Agent`, connects a provider through goose's provider API
(`connection.rs` — `ConnectionConfig` + cached `ProviderHandle`, shared across
sessions via `Agent::update_provider`), and drives `Agent::reply` while mapping
`AgentEvent`s to FFI `NativeEvent`s (`agent.rs`). Providers: **OpenRouter (API
key)** and **ChatGPT Codex (OAuth PKCE)**; goose state lives under an
app-owned `GOOSE_PATH_ROOT` (`~/Library/Application Support/Bixel/goose`).
Credentials are write-only across the FFI and stored in goose's secret store
(Keychain, file fallback); status is masked (`…last4`). A three-model
readiness gate (`ModelReadiness`: text/vision/image) is computed at connect
and blocks model-backed skills with the precise missing role. Image
generation has no goose abstraction and stays on bixel's own OpenRouter
client (`image_gen.rs`); vision (attachment descriptions) uses `vision.rs`.
The app does not read `.env` — connection config is UI-owned (the
`ConnectionConfig::from_env` path remains for headless examples only).

Two skill layers cooperate:

- **goose native skills.** The workspace `skills/` packages (`SKILL.md` +
  `scripts/` + `requirements.txt`) are embedded in the binary with
  `include_dir!` (`skill_install.rs`) and staged into goose's global skills dir
  (`~/.agents/skills`) at startup. goose's `skills` platform extension lists
  them to the agent and serves `load_skill`, so the agent runs the
  deterministic work itself with its shell tool: color reduce, background
  removal, slicing/packing, tilesets, UI kits, asset prep, spritesheet import,
  and `skill-creator` (which writes new skills back into `~/.agents/skills`).
  Python dependencies are auto-installed once into a managed venv
  (`~/Library/Application Support/Bixel/skill-venv`) built with the newest
  available Python. goose's shell tool overrides `PATH` with the user's
  login-shell PATH, so the assistant system prompt (`AssistantSession`) tells
  the agent to run skill scripts with that venv interpreter explicitly.
- **`bixel` tool extension.** goose has no image-generation API, so the
  provider-backed image skills stay in Rust (`skills.rs`) and are exposed as an
  in-process `rmcp` builtin extension (`skill_server.rs`) under **individually
  named tools** — `image_gen`, `generate_art`, `pixel_image_gen`, `spritesheet`,
  `next_frame` — not a generic `run_skill`, so the model never confuses them
  with `load_skill`. They call the OpenRouter/Codex image backends
  (`image_gen.rs`, `codex_image.rs`).

The legacy `Agent::reply` path does not inject the discovered-skill catalog into
the system prompt (only goose's state machine does), so `agent.rs` appends
goose's own `slash_commands::skill_slash_command::format_installed_skills`
listing each turn. `commands.rs` re-exports goose's slash-command API
(`list_commands`, `resolve_command`) over the FFI (`bixel_ai_list_commands`,
`bixel_ai_resolve_command`); the AI panel shows those commands and expands an
explicitly invoked `/skill` into its loaded `SKILL.md` context via goose's own
resolver.

The top-level `skills/*.json` files are documentation mirrors of the Rust image
skill specs (not read at runtime); the `skills/pixel-*/skill.json` files are the
packages' own manifests, unused by goose.

Spritesheet import is shared between the file importer and the `import_spritesheet`
skill: both build a `bixel_core::sheet::SheetPlan` (Bixel-export / atlas-actions /
grid) and either `AsepriteDoc::from_sheet` (project) or `append_sheet_frames`
(timeline). Skill outputs carry `frame_meta` (durations + tags) and an optional
`atlas` manifest so generated sheets can be added to the timeline in one click.

Rules: keep `bixel-core` free of goose/network deps; all AI/network code stays in
`bixel-ai`. FFI for AI is in `crates/bixel-ffi/src/lib.rs` (search `bixel_ai_`).
The Tilemap Designer's whole `bixel_map_*` FFI family also lives there (map.rs →
`BixelMap` opaque handle); its Swift model is `Models/TileMapModel.swift` with the
CALayer canvas and chrome under `Views/TileMap/`.


## Commands

```bash
# Rust
cargo build                    # whole workspace
cargo test -p bixel-core       # domain-logic tests
scripts/build-rust.sh          # build FFI staticlib + header into generated/
cbindgen --config cbindgen.toml --crate bixel-ffi --output generated/bixel.h

# Apple
xcodegen generate              # regenerate Bixel.xcodeproj from project.yml
xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug \
  -destination 'platform=macOS' build
scripts/package-dmg.sh --version v1.0.0 --build  # build release & package DMG
```

## Conventions & rules

1. **No UI/Apple imports in `bixel-core`.** Keep it pure Rust (serde/serde_json/
   thiserror/regex; `libc` only under `cfg(unix)` for job process-group kill).
2. **FFI boundaries are thin.** New `bixel_*` functions go in
   `crates/bixel-ffi/src/lib.rs`; opaque handles use the `#[repr(C)]` zero-size
   token struct pattern (see `BixelDoc`). Regenerate `generated/bixel.h` and
   mirror the call in `app/Bixel/Models/BixelEngine.swift`.
3. **Bulk data via caller buffers** (e.g. `bixel_doc_composite`) — never
   per-pixel FFI, never allocate-and-return large buffers without a free fn.
4. **Secrets never leave the core.** Config keys are exposed only through
   `config::masked_config` / `key_status`.
5. **Path safety is `paths::safe_resolve`.** Every disk access goes through it
   with an explicit `base` (no thread-local "current project" like the Python
   version — the host owns that state).
6. **Tests live next to the logic** under `crates/bixel-core/tests/` (integration)
   or `#[cfg(test)]` modules. Match the original JS/Python test semantics where
   they exist.

## Known environment gotchas

- Xcode build scripts run with a minimal `PATH`; `scripts/build-rust.sh` already
  prepends `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
- Metal shader compilation needs the Metal toolchain component:
  `xcodebuild -downloadComponent MetalToolchain`.
- `cbindgen` emits two harmless `WARN: Cannot find a mangling for generic path`
  lines for the private `Real*` type aliases; the generated header is unaffected.
- The embedded `goose` agent pulls `aws-lc-rs` (needs `cmake`), `sqlx`/SQLite
  (bundled), and `tree-sitter` ×8 (bundled C parsers) — the release staticlib is
  large (~80 MB) and `scripts/build-rust.sh` takes several minutes with LTO.
  The app links `SystemConfiguration` (reqwest system-proxy) in addition to
  `Security`/`CoreFoundation`.
- `idna_adapter` is pinned to `=1.2.1` in `bixel-ai` (goose pins `icu_locale` to
  2.1.1; `idna_adapter` 1.2.2 bumps `icu_normalizer` to 2.2+ and conflicts).
