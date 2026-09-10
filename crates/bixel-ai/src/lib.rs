//! # bixel-ai
//!
//! AI assistant engine for Bixel Studio. Embeds the **full goose agent**
//! (`goose`) — its agent loop, tool-calling, extension and skill systems — over
//! the OpenRouter provider, and exposes Bixel's pixel-art **skills** as a goose
//! tool extension:
//!
//! * `image_gen` / `generate_art` / `pixel_image_gen` — provider-backed image generation.
//! * `spritesheet` — text-to-spritesheet generation + grid slicing.
//! * `next_frame` — predict/create the next animation frame from the current one.
//! * `compress` / `pixel_reduce_colors` / `pixel_file_compressor` — color
//!   quantization / bit-depth / file-size reduction.
//! * `remove_background` / `pixel_remove_bg` — strip a background.
//! * `pixel_8dir_character` / `pixel_animate_text` / `pixel_interpolate` —
//!   pack frames into a uniform spritesheet.
//! * `pixel_9slice_splitter` / `pixel_spritesheet_gen` / `pixel_tileset_gen` —
//!   slice images into panels, sprites or tiles.
//! * `pixel_game_ui_gen` / `pixel_ui_elements_gen` / `pixel_ui_kit_gen` — slice
//!   UI images into components.
//! * `pixel_game_asset_prep` — chroma-green shadow placeholder → drop shadow.
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
pub mod config;
pub mod connection;
pub mod error;
pub mod image;
pub mod image_gen;
pub mod native_stream;
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
