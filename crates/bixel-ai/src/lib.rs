//! # bixel-ai
//!
//! AI assistant engine for Bixel Studio. Embeds the **full goose agent**
//! (`goose`) — its agent loop, tool-calling, extension and skill systems — over
//! the OpenRouter provider.
//!
//! Two skill layers cooperate:
//!
//! * **goose native skills** — the workspace `skills/` packages (`SKILL.md` +
//!   scripts) are embedded and installed into `~/.agents/skills` by
//!   [`skill_install`]. goose's `skills` platform extension lists them and
//!   serves `load_skill`, so the agent runs deterministic work (color reduce,
//!   background removal, slicing, packing, tilesets, UI kits, asset prep,
//!   spritesheet import, and `skill-creator`) itself.
//! * **`bixel` tool extension** — the provider-backed image skills goose cannot
//!   do natively: `image_gen` / `generate_art` / `pixel_image_gen` (image
//!   generation), `spritesheet` (grid + slice) and `next_frame` (image-to-image
//!   next animation frame).
//!
//! Headless examples can use environment defaults (`.env`); the app owns
//! provider selection and credentials through the connection UI:
//!
//! ```dotenv
//! OPENROUTER_API_KEY=sk-or-...
//! BIXEL_TEXT_MODEL=meta/muse-spark-1.3
//! BIXEL_VISION_MODEL=deepseek/deepseek-v4-flash-vision-exp
//! BIXEL_IMAGE_MODEL=google/gemini-3-pro-image
//! ```
//!
//! Deterministic skills run locally (no network); model-backed skills call the
//! connected provider image backend. Codex uses its hosted image-generation
//! tool with the selected Goose chat model. The goose agent handles the chat
//! loop, tool execution and session state.

pub mod agent;
pub mod codex_image;
pub mod commands;
pub mod config;
pub mod connection;
pub mod editor_bridge;
pub mod error;
pub mod image;
pub mod image_gen;
pub mod native_stream;
pub mod settings;
pub mod skill_install;
pub mod skill_server;
pub mod skills;
pub mod vision;

pub use agent::GooseAgent;
pub use config::AiSettings;
pub use connection::{
    ConnectionConfig, ModelCapability, ModelCatalog, ModelOption, ModelReadiness, ModelRoles,
    ProviderChoice, ProviderHandle, RoleReadiness,
};
pub use error::AiError;
pub use image::RgbaImage;
