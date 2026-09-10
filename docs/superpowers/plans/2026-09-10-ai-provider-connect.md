# AI Provider Connect Plan (goose-native, Codex/OpenRouter)

> Replace `.env`/environment-variable AI wiring with goose's programmatic provider
> connect, user-owned credentials, and a hard three-model readiness gate for skills.

**Goal:** Connect the assistant through goose's provider API (no `GOOSE_PROVIDER`/`GOOSE_MODEL`/`OPENROUTER_API_KEY` env wiring), supporting **OpenRouter (API key)** and **Codex (ChatGPT OAuth)** with the user's own credentials — while guaranteeing all three model roles (text, vision, image) are configured and validated, because model-backed skills dead-end without them.
**Architecture:** `bixel-ai` builds one cached `Arc<dyn Provider>` per credential set and hands clones to sessions via `Agent::update_provider` (goose-supported sharing). Credentials live in goose's secret store (Keychain, file fallback) under an app-owned `GOOSE_PATH_ROOT`. Image generation stays in `bixel-ai/src/image_gen.rs` (goose has no image-gen abstraction in this rev).
**Tech Stack:** Rust (`bixel-ai`, `bixel-ffi`), goose rev `13f4d26`, SwiftUI settings UI.

## Current state (verified)

- `AiSettings::from_env` reads `OPENROUTER_API_KEY` + `BIXEL_{TEXT,VISION,IMAGE}_MODEL` (`crates/bixel-ai/src/config.rs:35`); `apply_goose_env` (`config.rs:90`) pushes them into process env; `ensure_extensions_and_provider` (`crates/bixel-ai/src/agent.rs:113`) calls `recreate_provider_for_session` — **rebuilding the provider from env on every chat turn**.
- **Vision model is dead config**: nothing reads `vision_model`; chat image attachments go to the text model (`agent.rs:191`), and `AIPanel.swift:208` falsely claims attachments use the vision model.
- Image model is used only by `image_gen.rs` (direct reqwest to `{base}/images/generations|edits`); 4 skills require it (`generate_art`, `spritesheet`, `next_frame`, `pixel_image_gen`) and fail with `"this skill requires a configured image model"` (`skills.rs:190`).
- No key-entry UI exists; credentials are `.env`-only; the FFI engine is a non-resettable `OnceLock` (`crates/bixel-ffi/src/lib.rs:754`).
- Goose state (`GOOSE_PATH_ROOT`) is under `std::env::temp_dir()` — sessions/OAuth tokens do not survive.

## Goose API facts this plan relies on (rev 13f4d26)

- `Config::global().set_secret("OPENROUTER_API_KEY", …)` / `set_param(...)` work in-process; providers read secrets **at construction time** (`goose/src/config/base.rs:1015`). `Config::global()` is a `OnceCell` — `GOOSE_PATH_ROOT` must be set before its first call.
- `Agent::update_provider(provider: Arc<dyn Provider>, model_config, session_id)` (`agents/agent.rs:3645`) accepts an externally built provider; one `Arc<dyn Provider>` is `Send + Sync` and safely shared across all sessions. `ModelConfig::new(name)` is pure (no global config).
- Registry includes `openrouter` and `chatgpt_codex` (`providers/chatgpt_codex.rs`, OAuth PKCE against `auth.openai.com`, tokens cached at `$GOOSE_PATH_ROOT/config/chatgpt_codex/tokens.json`, refreshed in-process; `Provider::configure_oauth()` trait method at `goose-provider-types/src/base.rs:654`).
- One OpenRouter provider instance serves **any** model (model lives in `ModelConfig`, not the provider); vision is per-model via `ModelConfig.supports_vision`.
- Goose has **no image-generation provider** — image model stays on bixel's own OpenRouter images client. Consequence: **Codex can supply text + vision, but the image role always requires an OpenRouter key.**

## Design

**Connection model** — new `ConnectionConfig { provider: openrouter|chatgpt_codex, api_key?, models: { text, vision, image }, base_url }`:
1. Set `GOOSE_PATH_ROOT` to `~/Library/Application Support/Bixel/goose` before first `Config::global()` (persists sessions + OAuth tokens; fixes temp-dir loss).
2. OpenRouter: `set_secret("OPENROUTER_API_KEY", key)` then `providers::create("openrouter", vec![])` once; cache the `Arc`. Codex: `providers::create("chatgpt_codex", vec![])` then `configure_oauth()` (browser PKCE; callable from the app, localhost:1455 callback).
3. Per session: `agent.update_provider(cached.clone(), ModelConfig::new(text_model), session_id)` — replaces per-turn `recreate_provider_for_session`.
4. Image role: `ImageGen` unchanged mechanically, but built from the same `ConnectionConfig` and validated at connect time. With `provider = chatgpt_codex`, image role still needs an OpenRouter key (secondary key field) or image skills report not-ready.

**Three-model readiness gate** (the "skills won't work" guard):
- `ModelReadiness { text, vision, image }` each `{ model, ready, reason }`, computed at connect and re-checkable on demand. Text = provider reachable + model listed; vision = model supports image input (canonical catalog / `supports_vision`); image = OpenRouter key present + image model id set.
- Wire the vision role for real: add a direct vision call (chat-completions with image input, same pattern as `image_gen.rs`) used for attachment/description paths, so `vision_model` is no longer dead config.
- FFI exposes readiness; Swift blocks model-backed skills with the precise missing role instead of failing at HTTP time. Deterministic skills stay available offline.

**Credentials:** secrets enter via new write-only FFI (never returned — `AGENTS.md` rule 4); storage is goose's secret store with Keychain enabled (drop `GOOSE_DISABLE_KEYRING` for app builds; keep it for tests/CI → `secrets.yaml` under `GOOSE_PATH_ROOT`). `.env` remains as lowest-precedence dev fallback. Status is reported masked (`…last4`).

## Tasks

- [x] `bixel-ai`: introduce `ConnectionConfig` + `ProviderHandle` (cached `Arc<dyn Provider>` + `ImageGen` + readiness); set `GOOSE_PATH_ROOT` to app-support dir before `Config::global()`; delete `apply_goose_env`'s provider/key env writes.
- [x] `bixel-ai`: connect flow — `connect(cfg)` builds/caches provider via `providers::create` (+ `set_secret` for OpenRouter key, + `configure_oauth()` for Codex), validates all three roles, returns `ModelReadiness`; `disconnect` clears secrets + cache.
- [x] `bixel-ai`: switch sessions to `agent.update_provider(cached, ModelConfig::new(text_model), …)`; remove `get_goose_provider/model` + `recreate_provider_for_session` path.
- [x] `bixel-ai`: implement real vision usage (direct vision call helper) or route image attachments through it; skill failures name the missing role.
- [x] `bixel-ffi`: replace `OnceLock` engine with reconfigurable holder; add write-only `bixel_ai_connect(json)`, `bixel_ai_disconnect`, `bixel_ai_connection_status` (masked, per-role readiness), `bixel_ai_start_codex_oauth`. Regenerate `generated/bixel.h`.
- [x] Swift: AI settings UI — provider picker (OpenRouter key paste / "Sign in with ChatGPT"), three model fields with defaults, per-role ready indicators; `AIService` + `AssistantSession` gating on readiness; fix `AIPanel.swift:208` copy.
- [x] Keep `.env` as dev fallback (precedence: UI/stored config > env > built-in defaults); update `.env.example`, `README.md`, `AGENTS.md`.
- [x] Tests: config precedence, readiness logic (no network), FFI JSON shapes + never-returns-secret invariant, connect/disconnect re-entry. Then `cargo test -p bixel-ai`, `scripts/build-rust.sh`, Xcode build.

## Decisions

- "Codex" = goose's `chatgpt_codex` **OAuth** provider (user's ChatGPT creds, no API key). The CLI-wrapping `codex` provider is rejected: it needs a local Codex CLI install, unsuitable for an embedded app.
- Image generation stays on OpenRouter regardless of chat provider — goose has no image-gen API, so a Codex-only setup shows the image role (and its 4 skills) as not-ready until an OpenRouter key is added.
- Provider instance is built once and shared via `update_provider`; no per-turn rebuilds.
- Keychain on for app builds (goose auto-falls back to file on keyring failure); `GOOSE_DISABLE_KEYRING=1` only in tests.
