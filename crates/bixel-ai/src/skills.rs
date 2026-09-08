//! Pixel-art skills: a registry of named capabilities the assistant can run.
//!
//! Each skill declares its inputs/outputs and a model role (text, vision, image
//! or none for deterministic/local skills). Model-backed skills delegate to the
//! goose [`Engine`]; deterministic skills run locally against the image crate.

use serde::Serialize;

use crate::engine::Engine;
use crate::error::AiError;
use crate::image::{self, RgbaImage};

/// The model role a skill needs (or `None` for local/deterministic skills).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelRole {
    Text,
    Vision,
    Image,
    None,
}

/// A skill's stable identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillKind {
    GenerateArt,
    Spritesheet,
    NextFrame,
    Compress,
    RemoveBackground,
}

impl SkillKind {
    pub fn all() -> [SkillKind; 5] {
        [
            SkillKind::GenerateArt,
            SkillKind::Spritesheet,
            SkillKind::NextFrame,
            SkillKind::Compress,
            SkillKind::RemoveBackground,
        ]
    }
}

impl std::fmt::Display for SkillKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            SkillKind::GenerateArt => "generate_art",
            SkillKind::Spritesheet => "spritesheet",
            SkillKind::NextFrame => "next_frame",
            SkillKind::Compress => "compress",
            SkillKind::RemoveBackground => "remove_background",
        };
        f.write_str(s)
    }
}

/// Descriptive metadata for a skill (surfaced to the UI / assistant).
#[derive(Debug, Clone, Serialize)]
pub struct SkillSpec {
    pub id: String,
    pub name: String,
    pub description: String,
    pub category: &'static str,
    pub model: ModelRole,
    /// JSON Schema describing the `params` object the skill accepts.
    pub params_schema: serde_json::Value,
}

/// Input to a skill run.
#[derive(Debug, Clone, Default)]
pub struct SkillInput {
    pub prompt: String,
    pub image: Option<RgbaImage>,
    pub params: serde_json::Value,
}

/// Output of a skill run: optional text, single image, and/or sliced frames.
#[derive(Debug, Clone, Default)]
pub struct SkillOutput {
    pub text: String,
    pub image: Option<RgbaImage>,
    pub frames: Vec<RgbaImage>,
}

/// The skill registry. Immutable metadata + a dispatcher.
#[derive(Debug, Default)]
pub struct Skills;

impl Skills {
    pub fn specs() -> Vec<SkillSpec> {
        SkillKind::all().iter().map(|k| spec(*k)).collect()
    }

    pub fn spec(kind: SkillKind) -> SkillSpec {
        spec(kind)
    }

    /// Run a skill. Deterministic skills ignore `engine` (pass `None`).
    pub fn run(
        engine: Option<&Engine>,
        kind: SkillKind,
        input: SkillInput,
    ) -> Result<SkillOutput, AiError> {
        match kind {
            SkillKind::GenerateArt => generate_art(require_engine(engine)?, input),
            SkillKind::Spritesheet => spritesheet(require_engine(engine)?, input),
            SkillKind::NextFrame => next_frame(require_engine(engine)?, input),
            SkillKind::Compress => compress(input),
            SkillKind::RemoveBackground => remove_background(input),
        }
    }
}

fn require_engine(engine: Option<&Engine>) -> Result<&Engine, AiError> {
    engine.ok_or_else(|| AiError::Config("this skill requires a configured AI engine".into()))
}

fn spec(kind: SkillKind) -> SkillSpec {
    match kind {
        SkillKind::GenerateArt => SkillSpec {
            id: kind.to_string(),
            name: "Generate art".into(),
            description: "Generate a piece of pixel art from a text prompt.".into(),
            category: "generation",
            model: ModelRole::Image,
            params_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "style": { "type": "string", "description": "Art style hint" },
                    "width": { "type": "integer", "description": "Target width in pixels" },
                    "height": { "type": "integer", "description": "Target height in pixels" }
                }
            }),
        },
        SkillKind::Spritesheet => SkillSpec {
            id: kind.to_string(),
            name: "Spritesheet".into(),
            description: "Generate a spritesheet grid and slice it into frames.".into(),
            category: "generation",
            model: ModelRole::Image,
            params_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "cols": { "type": "integer", "description": "Number of columns" },
                    "rows": { "type": "integer", "description": "Number of rows" },
                    "frame_width": { "type": "integer" },
                    "frame_height": { "type": "integer" }
                }
            }),
        },
        SkillKind::NextFrame => SkillSpec {
            id: kind.to_string(),
            name: "Predict next frame".into(),
            description: "Create the next frame of an animation from the current frame.".into(),
            category: "animation",
            model: ModelRole::Image,
            params_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "action": { "type": "string", "description": "What happens next" }
                }
            }),
        },
        SkillKind::Compress => SkillSpec {
            id: kind.to_string(),
            name: "Compress to bit depth".into(),
            description: "Reduce an image to a target bit depth (2^bits colors).".into(),
            category: "utility",
            model: ModelRole::None,
            params_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "bits": { "type": "integer", "minimum": 1, "maximum": 8, "default": 4 }
                }
            }),
        },
        SkillKind::RemoveBackground => SkillSpec {
            id: kind.to_string(),
            name: "Remove background".into(),
            description: "Strip a near-uniform background by flood-filling from the edges.".into(),
            category: "utility",
            model: ModelRole::None,
            params_schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "tolerance": { "type": "number", "minimum": 0, "default": 32 }
                }
            }),
        },
    }
}

// ------------------------------------------------------------- skill bodies

fn require_image(input: &SkillInput) -> Result<&RgbaImage, AiError> {
    input.image.as_ref().ok_or(AiError::Image("skill requires an input image".into()))
}

fn param_bits(input: &SkillInput) -> u8 {
    input
        .params
        .get("bits")
        .and_then(|v| v.as_u64())
        .map(|v| v.clamp(1, 8) as u8)
        .unwrap_or(4)
}

fn param_tolerance(input: &SkillInput) -> f32 {
    input
        .params
        .get("tolerance")
        .and_then(|v| v.as_f64())
        .map(|v| v as f32)
        .unwrap_or(32.0)
}

fn generate_art(engine: &Engine, input: SkillInput) -> Result<SkillOutput, AiError> {
    let prompt = build_art_prompt(&input);
    let image = engine.generate_image(&prompt, None)?;
    Ok(SkillOutput { image: Some(image), ..Default::default() })
}

fn spritesheet(engine: &Engine, input: SkillInput) -> Result<SkillOutput, AiError> {
    let cols = input.params.get("cols").and_then(|v| v.as_u64()).unwrap_or(4) as usize;
    let rows = input.params.get("rows").and_then(|v| v.as_u64()).unwrap_or(1) as usize;
    let prompt = build_spritesheet_prompt(&input, cols, rows);
    let sheet = engine.generate_image(&prompt, None)?;
    let frames = image::slice_grid(&sheet, cols.max(1), rows.max(1));
    Ok(SkillOutput {
        image: Some(sheet),
        frames,
        ..Default::default()
    })
}

fn next_frame(engine: &Engine, input: SkillInput) -> Result<SkillOutput, AiError> {
    let current = require_image(&input)?;
    let prompt = build_next_frame_prompt(&input);
    let frame = engine.generate_image(&prompt, Some(current))?;
    Ok(SkillOutput { image: Some(frame), ..Default::default() })
}

fn compress(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let bits = param_bits(&input);
    let out = image::compress_to_bits(img, bits);
    Ok(SkillOutput {
        text: format!("compressed to {}-bit ({} colors)", bits, 1usize << bits),
        image: Some(out),
        ..Default::default()
    })
}

fn remove_background(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let tolerance = param_tolerance(&input);
    let out = image::remove_background(img, tolerance);
    Ok(SkillOutput {
        text: format!("removed background (tolerance {tolerance})"),
        image: Some(out),
        ..Default::default()
    })
}

// ---------------------------------------------------------------- prompts

fn build_art_prompt(input: &SkillInput) -> String {
    let style = input.params.get("style").and_then(|v| v.as_str()).unwrap_or("pixel art");
    format!(
        "Create a single {style} image. {}\nClean pixels, crisp edges, no text or watermark.",
        input.prompt
    )
}

fn build_spritesheet_prompt(input: &SkillInput, cols: usize, rows: usize) -> String {
    format!(
        "Create a sprite sheet arranged on a uniform grid of {cols} columns by {rows} rows. \
         Every cell holds one animation frame of: {}\nKeep each frame the same size, aligned to \
         the grid, with a solid background color for easy slicing. No text or watermark.",
        input.prompt
    )
}

fn build_next_frame_prompt(input: &SkillInput) -> String {
    let action = input.params.get("action").and_then(|v| v.as_str()).unwrap_or("continue the motion");
    format!(
        "This is one frame of a pixel-art animation. Generate the NEXT frame, keeping the same \
         palette, character, and style, where the action is: {action}. Return only the next frame.",
    )
}

// ---------------------------------------------------------------- grid slice
