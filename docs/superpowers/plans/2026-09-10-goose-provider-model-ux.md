# Goose-aligned Provider and Model UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Bixel’s provider/model setup match Goose ACP semantics, expose truthful ChatGPT (Codex) image capability, and route image requests through a first-class `image_gen` skill.

**Architecture:** The Rust connection layer owns provider-scoped model catalogs and effective role routing. The FFI returns structured catalog/capability metadata while preserving legacy model ids. Swift presents one provider-scoped primary model selector, capability status, and OpenRouter-only advanced overrides; direct image requests invoke the registered `image_gen` skill so the developer shell cannot fabricate the asset.

**Tech Stack:** Rust 2021 workspace, serde/serde_json, Goose provider metadata, hand-written C ABI, SwiftUI/AppKit macOS 13+.

**Spec:** `docs/superpowers/specs/2026-09-10-goose-provider-model-ux-design.md`

## Global Constraints

- Keep `bixel-core` free of Goose/network dependencies.
- Keep secrets write-only across FFI; status may expose only masked/effective capability data.
- Keep FFI boundaries thin and transport images in whole PNG buffers.
- Codex image generation uses the authenticated hosted backend; it must never silently use the OpenRouter/Google image default.
- Deterministic skills remain local and usable without a model connection.
- Use test-first changes: write each regression test, run it failing, implement the smallest fix, then rerun the focused and workspace tests.
- Preserve existing connection JSON fields where practical and add structured fields instead of breaking older clients.

### Task 1: Add provider-scoped model option and capability types

**Files:**
- Modify: `crates/bixel-ai/src/connection.rs:1-30,500-553`
- Test: `crates/bixel-ai/src/connection.rs` unit tests
- Modify: `crates/bixel-ai/src/lib.rs:47-53` exports

**Interfaces:**
- Produces `ModelCapability`, `ModelOption`, and `ModelCatalog`.
- Changes `connection::list_models(provider)` to return `Result<ModelCatalog, AiError>`.
- `ModelCatalog.models` contains stable ids/labels/capabilities/recommended flags and `ModelCatalog.default` contains the provider default.

- [ ] **Step 1: Write the failing catalog tests.** Add tests that construct/serialize a Codex catalog and assert that a recommended model carries `chat`, `vision`, and `image`; add an OpenRouter capability parser test with `input_modalities: ["text", "image"]` and `output_modalities: ["text"]` that produces `chat` + `vision` but not `image`.

```rust
#[test]
fn codex_catalog_marks_hosted_image_capability() {
    let catalog = codex_model_catalog();
    let option = catalog.models.iter().find(|m| m.id == "gpt-5.5").unwrap();
    assert!(option.capabilities.contains(&ModelCapability::Chat));
    assert!(option.capabilities.contains(&ModelCapability::Vision));
    assert!(option.capabilities.contains(&ModelCapability::Image));
    assert_eq!(catalog.default.as_deref(), Some("gpt-5.5"));
}

#[test]
fn openrouter_model_capabilities_follow_modalities() {
    let value = serde_json::json!({
        "id": "provider/vision-model",
        "name": "Vision Model",
        "architecture": {
            "input_modalities": ["text", "image"],
            "output_modalities": ["text"]
        }
    });
    let option = openrouter_model_option(&value).unwrap();
    assert_eq!(option.label, "Vision Model");
    assert!(option.capabilities.contains(&ModelCapability::Chat));
    assert!(option.capabilities.contains(&ModelCapability::Vision));
    assert!(!option.capabilities.contains(&ModelCapability::Image));
}
```

- [ ] **Step 2: Run the focused tests and verify the expected failure.**

Run: `cargo test -p bixel-ai connection::tests::codex_catalog_marks_hosted_image_capability connection::tests::openrouter_model_capabilities_follow_modalities`

Expected: compile/test failure because the capability types and catalog helpers do not exist yet.

- [ ] **Step 3: Implement the catalog types and parsers.** Add serde enums with snake-case values:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelCapability { Chat, Vision, Image }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelOption {
    pub id: String,
    pub label: String,
    pub capabilities: Vec<ModelCapability>,
    pub recommended: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelCatalog {
    pub models: Vec<ModelOption>,
    pub default: Option<String>,
}
```

Build the Codex catalog from Goose’s registry metadata, marking every known Codex model as `Chat`, `Vision`, and hosted `Image`. Parse OpenRouter `data` entries from `architecture.input_modalities` and `architecture.output_modalities`; all non-empty models get `Chat`, image input adds `Vision`, and image output adds `Image`. Keep the model id as the fallback label.

- [ ] **Step 4: Update `list_models` and exports.** Return `ModelCatalog` for both providers, preserve sorting, and re-export the new public types from `bixel-ai`.

- [ ] **Step 5: Run focused and existing connection tests.**

Run: `cargo test -p bixel-ai connection::tests`

Expected: PASS with the new catalog assertions and all existing credential/readiness tests.

- [ ] **Step 6: Commit.**

```bash
git add crates/bixel-ai/src/connection.rs crates/bixel-ai/src/lib.rs
git commit -m "feat: expose provider-scoped model capabilities"
```

### Task 2: Normalize Codex effective routing and FFI status/catalog JSON

**Files:**
- Modify: `crates/bixel-ai/src/connection.rs:64-135,190-230,390-448`
- Modify: `crates/bixel-ffi/src/lib.rs:795-830,901-919,1854-1902`
- Test: `crates/bixel-ai/src/connection.rs` and `crates/bixel-ffi/src/lib.rs` unit tests

**Interfaces:**
- Produces `ConnectionConfig::normalize_provider_roles()`.
- Codex’s effective `models.image` and `readiness.image.model` equal the selected text model after normalization.
- `bixel_ai_list_models` returns `{models: [ids], model_options: [...], default: ...}`.
- Connection status adds an `image_source` string and uses effective readiness for connected role labels.

- [ ] **Step 1: Write failing normalization/status tests.** Assert that a Codex config with text `gpt-5.5` and image `google/gemini-3-pro-image` normalizes image to `gpt-5.5`, and that serialized connected-role data cannot report the Google model as the Codex image source.

```rust
#[test]
fn codex_normalization_replaces_stale_image_model() {
    let mut cfg = cfg(ProviderChoice::ChatgptCodex, None, None);
    cfg.models.text = "gpt-5.5".into();
    cfg.models.image = "google/gemini-3-pro-image".into();
    cfg.normalize_provider_roles();
    assert_eq!(cfg.models.image, "gpt-5.5");
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail.**

Run: `cargo test -p bixel-ai connection::tests::codex_normalization_replaces_stale_image_model`

Expected: compile failure because the normalization method is absent.

- [ ] **Step 3: Implement normalization at the connection boundary.** Add `normalize_provider_roles`, call it at the start of `connection::connect` after deserialization and before readiness/image generator creation, and leave OpenRouter role values unchanged. Update comments and `require_gen` errors so they say “image generation backend” rather than assuming an OpenRouter key.

- [ ] **Step 4: Update FFI model catalog JSON.** Keep legacy ids in `models`, add `model_options` from `ModelCatalog.models`, and pass through `default`. Do not include API keys or OAuth token fields.

- [ ] **Step 5: Update connection status JSON.** For a connected Codex handle, set the image model display to `readiness.image.model`, add:

```json
"image_source": "ChatGPT hosted image generation"
```

For OpenRouter use `"OpenRouter image model"`; for disconnected status use null. Add a test that the status schema still contains the three role keys and no secret strings.

- [ ] **Step 6: Run FFI and AI tests.**

Run: `cargo test -p bixel-ai && cargo test -p bixel-ffi`

Expected: PASS; the Codex lifecycle test still reports an image generator and no status test reports a Google image model for a normalized Codex handle.

- [ ] **Step 7: Commit.**

```bash
git add crates/bixel-ai/src/connection.rs crates/bixel-ffi/src/lib.rs
git commit -m "fix: make Codex image routing provider truthful"
```

### Task 3: Add the first-class `image_gen` skill

**Files:**
- Modify: `crates/bixel-ai/src/skills.rs:23-112,150-205,270-310,560-600`
- Modify: `crates/bixel-ai/src/skill_server.rs:75-115,204-210`
- Test: `crates/bixel-ai/tests/skills_test.rs` and `crates/bixel-ai/src/skills.rs` tests

**Interfaces:**
- Adds `SkillKind::ImageGen`, stable id `image_gen`, `ModelRole::Image`.
- `Skills::run(Some(generator), SkillKind::ImageGen, input)` forwards prompt/reference and returns a prepared PNG output.
- MCP `run_skill` accepts `skill: "image_gen"` and uses the active provider-polymorphic `ImageGenerator`.

- [ ] **Step 1: Write failing registration and forwarding tests.** Add a fake `ImageGenerator` that records the prompt and whether an input image was supplied, then assert the new skill is listed, requires the image role, forwards a reference image, and returns the fake image.

```rust
#[test]
fn image_gen_skill_forwards_prompt_and_reference() {
    let generator = RecordingGenerator::new(RgbaImage::new(3, 2));
    let reference = RgbaImage::new(2, 2);
    let output = Skills::run(
        Some(&generator),
        SkillKind::ImageGen,
        SkillInput {
            prompt: "a 32x32 hon kanji sprite".into(),
            image: Some(reference),
            params: serde_json::json!({"width": 32, "height": 32, "transparent": true}),
            ..Default::default()
        },
    ).unwrap();
    assert!(generator.last_prompt().contains("hon kanji"));
    assert!(generator.received_reference());
    assert_eq!((output.image.unwrap().width, output.image.unwrap().height), (32, 32));
}
```

- [ ] **Step 2: Run the focused skill tests and confirm they fail.**

Run: `cargo test -p bixel-ai --test skills_test image_gen_skill_forwards_prompt_and_reference`

Expected: compile failure because `SkillKind::ImageGen` and the recording test helper do not exist.

- [ ] **Step 3: Implement the new skill.** Add the enum variant to `all`, `Display`, `from_id` behavior, dispatch, and `spec`. The prompt builder must preserve exact user text, permit requested text/labels, add transparent/opaque guidance, and add style/palette/size constraints. Use `prepare_generated` so source and prepared image behavior matches existing generation skills.

- [ ] **Step 4: Update the MCP schema/instructions.** Add `image_gen` to the tool description and explicitly state: “For any request to create, draw, generate, render, or edit an image, call `image_gen`; never use developer shell/Python to synthesize the image.” Keep the existing pixel-specific skill list and parameter rules.

- [ ] **Step 5: Run all skill tests.**

Run: `cargo test -p bixel-ai --test skills_test && cargo test -p bixel-ai`

Expected: PASS with the new image skill and all existing preparation tests.

- [ ] **Step 6: Commit.**

```bash
git add crates/bixel-ai/src/skills.rs crates/bixel-ai/src/skill_server.rs crates/bixel-ai/tests/skills_test.rs
git commit -m "feat: add provider-backed image generation skill"
```

### Task 4: Pass prompts through generic FFI skill execution and hard-route image requests

**Files:**
- Modify: `crates/bixel-ffi/src/lib.rs:1146-1194`
- Modify: `app/Bixel/Models/AIService.swift:116-148`
- Modify: `app/Bixel/Models/AssistantSession.swift:180-265`
- Test: `crates/bixel-ffi/src/lib.rs` unit tests; Swift build verification

**Interfaces:**
- `AIService.runSkill(id:params:prompt:png:)` accepts an optional prompt while preserving existing call sites through a default parameter.
- The FFI reads `params.prompt` into `SkillInput.prompt` and removes it from the user-facing params only when building schema options is necessary.
- Natural image requests invoke `image_gen` directly on the worker queue, emit tool/artifact/result events, and do not invoke the developer shell extension.

- [ ] **Step 1: Write a failing FFI prompt propagation test.** Add a test-only helper around the params-to-`SkillInput` conversion and assert `{"prompt":"draw a lantern"}` becomes `SkillInput.prompt == "draw a lantern"`.

- [ ] **Step 2: Run the focused FFI test and verify failure.**

Run: `cargo test -p bixel-ffi prompt_param_reaches_skill_input`

Expected: FAIL because generic FFI skill input currently hardcodes an empty prompt.

- [ ] **Step 3: Implement prompt propagation.** Read `params["prompt"]` as a string, use it to populate `SkillInput.prompt`, and keep all other params intact for generation settings.

- [ ] **Step 4: Update Swift’s skill wrapper.** Add `prompt: String = ""` to `AIService.runSkill`, inject it into the JSON params only when non-empty, and leave deterministic callers unchanged.

- [ ] **Step 5: Add the image-intent route in `AssistantSession`.** Add a private `isImageGenerationRequest(_:)` helper for phrases containing an image noun (`image`, `picture`, `illustration`, `sprite`, `icon`, `art`) and a creation verb (`create`, `generate`, `draw`, `make`, `render`, `paint`, `edit`). If no explicit skill is selected and the helper matches, or if `image_gen` is explicitly selected, run `AIService.runSkill(id: "image_gen", params: ..., prompt: text, png: first image attachment)` on the worker queue. Emit the same `tool_call`, `artifact`, and `tool_result` event shapes as local skills. The streamed Goose path remains for chat, deterministic selected skills, and non-image requests.

- [ ] **Step 6: Strengthen the streamed assistant system prompt.** State that image requests must use `image_gen`, that image results are only valid after an image-tool result, and that Python/shell drawing is prohibited for image assets.

- [ ] **Step 7: Run Rust tests and build the Swift target.**

Run: `cargo test -p bixel-ffi && xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build`

Expected: PASS; the Swift build consumes the regenerated header from the pre-build Rust phase.

- [ ] **Step 8: Commit.**

```bash
git add crates/bixel-ffi/src/lib.rs app/Bixel/Models/AIService.swift app/Bixel/Models/AssistantSession.swift
git commit -m "feat: route image requests through the image skill"
```

### Task 5: Decode structured model catalogs in Swift

**Files:**
- Modify: `app/Bixel/Models/AIService.swift:25-114,305-323`
- Test: Swift build; if the target has no unit-test target, add decoding assertions to the existing model layer test target rather than production code

**Interfaces:**
- `AIService.AIModelOption`: `Identifiable`, `Decodable`, `id`, `label`, `capabilities: Set<String>`, `recommended`.
- `AIService.AIModelCatalog`: `options`, `models` compatibility projection, `defaultModel`, optional `error`.
- `AIConnectionStatus.imageSource` decodes the new FFI status field.

- [ ] **Step 1: Add a decoding test fixture.** Use the FFI JSON shape with `models`, `model_options`, and `default`; assert options decode capability badges and legacy `models` remains available.

- [ ] **Step 2: Run the Swift test/build and confirm the missing decoder/types failure.**

Run: `xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build`

Expected: failure until the new Swift types and decoder are implemented if the fixture is in the test target; otherwise record the current target’s lack of unit-test support and use compile-time verification.

- [ ] **Step 3: Implement the model/status types.** Decode `model_options` with `JSONDecoder` and fall back to the string `models` array by constructing chat-only options. Parse `image_source` into `AIConnectionStatus`.

- [ ] **Step 4: Update `AIService.listModels` to return structured options.** Preserve `catalog.models` as a computed `[String]` for any existing non-UI callers.

- [ ] **Step 5: Build and commit.**

```bash
xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build
git add app/Bixel/Models/AIService.swift
git commit -m "feat: decode provider model capabilities in Swift"
```

### Task 6: Redesign `AISettingsView` around provider cards and capabilities

**Files:**
- Replace: `app/Bixel/Views/AISettingsView.swift`
- Modify: `app/Bixel/Models/AIService.swift` only if a view-facing status helper is needed

**Interfaces:**
- Provider selection is a local `ProviderChoice` enum (`openrouter`, `chatgpt_codex`) and never changes the active connection until Connect/Reconnect is pressed.
- ChatGPT view shows OAuth controls, Goose Codex model options, and hosted image capability; it has no image-model field or OpenRouter key field.
- OpenRouter view shows API key, primary model, capability summary, and collapsed Advanced routing with vision/image overrides.
- The view uses `AIModelOption.capabilities` for badges and never infers provider membership from a model id.

- [ ] **Step 1: Build the view shell from the existing design tokens.** Add provider cards with selected state, connection dot, provider description, and a single clear Connect/Reconnect action. Keep the existing sheet width but allow enough height for capabilities and advanced routing.

- [ ] **Step 2: Add async provider-scoped catalog loading.** On provider selection, load `AIService.listModels(provider:)` on a user-initiated queue; keep the current selected model as a temporary row if loading fails; show a recoverable inline error instead of borrowing another provider’s model.

- [ ] **Step 3: Add the primary model picker.** Use a popover list showing model label/id, recommended marker, and capability chips. For Codex, selecting a model updates text and vision to that model and treats image as hosted capability. For OpenRouter, selecting a model updates the primary text model only.

- [ ] **Step 4: Add capability/readiness rows.** Display Chat, Vision, and Image generation with green/orange/gray status, effective model/source, and precise readiness reason. Use `status.imageSource` for the image row; never display a stale configured Google value for Codex.

- [ ] **Step 5: Add OpenRouter-only Advanced routing.** Provide optional vision and image override pickers from the same OpenRouter catalog, with explanatory copy. Hide the disclosure entirely for Codex.

- [ ] **Step 6: Update connect/migration behavior.** For Codex send the selected model as text and vision, and send the selected model as the image placeholder so backend normalization is explicit. For OpenRouter send primary/override values. Remove the old provider-change default mutation and old “image skills stay offline” copy.

- [ ] **Step 7: Build and inspect the settings screen.**

Run: `xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build`

Verify manually: switching providers never leaves a model from the other provider; Codex shows only Goose model ids; Codex capability rows show hosted image generation; OpenRouter alone shows advanced overrides.

- [ ] **Step 8: Commit.**

```bash
git add app/Bixel/Views/AISettingsView.swift app/Bixel/Models/AIService.swift
git commit -m "feat: redesign AI settings around Goose capabilities"
```

### Task 7: Final verification and requirement audit

**Files:**
- Modify only if verification exposes a defect; otherwise no new files.

- [ ] **Step 1: Run formatting and Rust tests.**

Run: `cargo fmt --all -- --check && cargo test -p bixel-core && cargo test -p bixel-ai && cargo test -p bixel-ffi`

- [ ] **Step 2: Regenerate the C header and build the app.**

Run: `scripts/build-rust.sh && xcodebuild -project Bixel.xcodeproj -scheme Bixel -configuration Debug -destination 'platform=macOS' build`

- [ ] **Step 3: Audit the status/catalog JSON.** Confirm disconnected status contains no secrets, Codex status never reports `google/gemini-3-pro-image`, and model catalog options are provider-scoped.

- [ ] **Step 4: Audit assistant behavior.** Confirm a natural request such as “create a 32×32 hon/book kanji image” emits `image_gen` tool/artifact events and never emits a developer shell/Python tool call; confirm deterministic skills still run offline.

- [ ] **Step 5: Review the final diff and working tree.**

Run: `git diff --check && git status --short && git diff --stat HEAD~7..HEAD`

- [ ] **Step 6: Commit any final correction separately with a focused message.**

