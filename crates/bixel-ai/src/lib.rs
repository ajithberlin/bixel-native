//! # bixel-ai
//!
//! AI assistant engine for Bixel Studio. Wraps the [goose SDK](https://goose-docs.ai)
//! (`goose-sdk`) to talk to OpenRouter — a single OpenAI-compatible endpoint
//! that routes *text*, *vision* and *image* models — and exposes a set of
//! pixel-art **skills**:
//!
//! * `generate_art` / `pixel_image_gen` — text-to-image generation.
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
//! Model routing and credentials come from the environment (`.env`):
//!
//! ```dotenv
//! OPENROUTER_API_KEY=sk-or-...
//! BIXEL_TEXT_MODEL=meta/muse-spark-1.3
//! BIXEL_VISION_MODEL=deepseek/deepseek-v4-flash-vision-exp
//! BIXEL_IMAGE_MODEL=google/gemini-3-pro-image
//! ```
//!
//! Deterministic skills (compress, reduce colors, remove background, slicing,
//! packing) run locally and are unit-tested; model-backed skills require a
//! valid key and network.

pub mod config;
pub mod engine;
pub mod error;
pub mod image;
pub mod skills;

pub use config::AiSettings;
pub use engine::Engine;
pub use error::AiError;
pub use image::RgbaImage;
