//! # bixel-ai
//!
//! AI assistant engine for Bixel Studio. Wraps the [goose SDK](https://goose-docs.ai)
//! (`goose-sdk`) to talk to OpenRouter — a single OpenAI-compatible endpoint
//! that routes *text*, *vision* and *image* models — and exposes a set of
//! pixel-art **skills**:
//!
//! * `generate_art` — text-to-image generation.
//! * `spritesheet` — text-to-spritesheet generation + grid slicing.
//! * `next_frame` — predict/create the next animation frame from the current one.
//! * `compress` — reduce an image to a target bit depth (color count).
//! * `remove_background` — strip a near-uniform background.
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
//! Deterministic skills (compress, remove background) run locally and are
//! unit-tested; model-backed skills require a valid key and network.

pub mod config;
pub mod engine;
pub mod error;
pub mod image;
pub mod skills;

pub use config::AiSettings;
pub use engine::Engine;
pub use error::AiError;
pub use image::RgbaImage;
