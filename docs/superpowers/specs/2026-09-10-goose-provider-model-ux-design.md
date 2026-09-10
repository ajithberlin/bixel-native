# Goose-aligned provider and model UX

## Problem

Bixel currently models AI connections as one provider plus three independent
model strings: text, vision, and image. That does not match the embedded Goose
provider contract. Goose selects a provider-scoped chat model; ChatGPT (Codex)
exposes Codex chat models through OAuth and image generation is a hosted
capability of that authenticated backend, not a Google/OpenRouter image-model
selection. The current UI therefore displays `google/gemini-3-pro-image` while
Codex is connected and permits the assistant to choose shell/Python for image
requests instead of the Bixel image skill.

## Goals

- Make provider setup and model selection follow Goose ACP semantics.
- Show only models belonging to the selected provider.
- Represent chat, vision, and image generation as verified capabilities with
  truthful backend/model labels.
- Keep OpenRouter's optional separate image model support without making it the
  primary mental model for Codex.
- Add a first-class image-generation skill and route natural-language image
  requests to it instead of developer shell/Python fabrication.
- Migrate existing Codex connections without retaining the stale Google image
  model value.
- Preserve secret handling and the existing FFI ownership rules.

## Non-goals

- Replacing Goose's provider implementation or ACP protocol.
- Adding a second OAuth system.
- Removing existing deterministic pixel-art preparation skills.
- Building a general-purpose model marketplace or model metadata service.

## Architecture

### Provider-scoped model catalog

The Rust connection layer will expose model options rather than a bare list of
strings. Each option contains a stable id, display label, capability flags,
and whether it is recommended. ChatGPT (Codex) options come from Goose's
provider metadata. OpenRouter options come from its `/models` response and
derive capabilities from the response's architecture/modalities fields where
available.

The FFI JSON remains backwards-compatible at the top level (`models` and
`default` remain present), while adding structured model entries and capability
metadata. Swift consumes the structured entries and falls back to the legacy
ids only when an older Rust library is present.

### Connection roles and effective routing

The selected provider and primary chat model are authoritative. Codex uses the
same selected model for chat and vision, and its image capability is backed by
the authenticated hosted `image_generation` tool. The displayed image source
must therefore be the selected Codex model, never the OpenRouter default.

OpenRouter retains separate role overrides for compatibility and flexibility:
the primary model is used for chat, an optional vision override can be used for
image input, and an optional image override is used for generation. The UI
places those overrides under Advanced routing and does not show them for
Codex.

Connection status/readiness will expose both the role readiness and the
effective model/source. Status presentation must be derived from effective
readiness, not from an unused configured image string.

### Image skill and routing

Add `image_gen` as a model-backed skill. It accepts a text prompt, optional
reference image, transparent/opaque background preference, optional dimensions,
style, and palette guidance. It uses the active `ImageGenerator`, which is
already provider-polymorphic: OpenRouter uses the configured image override;
Codex uses its hosted Responses API image-generation tool.

The assistant system instructions and the Bixel MCP tool description will state
that image creation/editing requests must call `run_skill` with `image_gen` and
must not use the developer shell or Python to synthesize an image. Existing
explicitly selected skills retain priority. The existing `pixel_image_gen`
skill remains available for stricter game-asset/pixel-art preparation.

### Swift settings flow

`AISettingsView` becomes a provider-scoped workspace:

1. Provider cards show ChatGPT (Codex) and OpenRouter with authentication and
   connection state.
2. Selecting a provider loads its model catalog and reveals only relevant
   authentication controls.
3. A single primary model picker shows the selected provider's models and
   capability badges.
4. A capability summary shows Chat, Vision, and Image generation readiness and
   the actual source for each.
5. Advanced routing is collapsed by default and only exposes OpenRouter role
   overrides.
6. Connect/reconnect is explicit and saves one coherent provider/model state.

The visual treatment remains native to the existing dark Bixel macOS UI: quiet
charcoal surfaces, blue selected provider/model states, green readiness dots,
and monospace model identifiers. Labels use user-facing capability language,
not internal role jargon.

## Migration and errors

- When connecting Codex, normalize the effective image role to the selected
  Codex model and ignore any stale configured OpenRouter image model.
- When an existing Codex connection is displayed, derive image status from the
  hosted backend and show the selected model as its source.
- If the provider catalog cannot load, preserve the current selection as a
  temporary option and show a recoverable error; do not silently substitute a
  model from another provider.
- If image capability is unavailable, the capability row names the missing
  authentication/backend requirement and the assistant blocks only image
  skills, while deterministic skills remain usable.

## Testing

- Rust unit tests for Codex effective model normalization and readiness/status
  labels.
- Rust unit tests for structured provider model catalog parsing and stable
  capability flags.
- Rust skill tests for `image_gen` registration, metadata, reference-image
  forwarding, and output preparation.
- FFI status/catalog tests asserting no secrets and no cross-provider image
  model leakage.
- Swift compilation/build verification for the redesigned settings view and
  catalog decoding.

