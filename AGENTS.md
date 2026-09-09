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
skills/              # skill manifests (JSON; mirror of bixel-ai::skills)
generated/           # (gitignored) staged libbixel.a + bixel.h
```

Module → original Python/JS source (porting reference):

| Rust | Original |
|------|----------|
| `document.rs` | `web/aseprite/document.js` |
| `palette.rs` | `web/aseprite/palette.js` |
| `timeline.rs` | `web/aseprite/timeline.js` |
| `tilemap.rs` | `web/mapcore.js` |
| `atlas.rs` | `core/atlases.py` |
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
a `goose::agents::Agent`, points it at the `openrouter` provider via env
(`GOOSE_PROVIDER`, `GOOSE_MODEL`, `OPENROUTER_API_KEY`, `OPENROUTER_HOST`), and
drives `Agent::reply` while mapping `AgentEvent`s to FFI `NativeEvent`s
(`agent.rs`). Models come from `.env`
(`BIXEL_TEXT_MODEL`/`BIXEL_VISION_MODEL`/`BIXEL_IMAGE_MODEL`).

Pixel-art skills are exposed to the agent as an in-process `rmcp` builtin
extension (`skill_server.rs` → `run_skill` tool) that dispatches to the skill
registry (`skills.rs`). Deterministic skills run locally; model-backed skills
call the OpenRouter image endpoints (`image_gen.rs`).

Rules: keep `bixel-core` free of goose/network deps; all AI/network code stays in
`bixel-ai`. FFI for AI is in `crates/bixel-ffi/src/lib.rs` (search `bixel_ai_`).


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
