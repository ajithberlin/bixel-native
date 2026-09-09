//! Pixel-art skills: a registry of named capabilities the assistant can run.
//!
//! Each skill declares its inputs/outputs and a model role (text, vision, image
//! or none for deterministic/local skills). Model-backed skills delegate to the
//! goose [`Engine`]; deterministic skills run locally against the image crate.

use serde::Serialize;

use crate::error::AiError;
use crate::image::{self, PackAnchor, RgbaImage};
use crate::image_gen::ImageGen;

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
    // -- new pixel-* skills ------------------------------------------------
    PixelImageGen,
    PixelReduceColors,
    PixelFileCompressor,
    PixelRemoveBg,
    PixelEightDirCharacter,
    PixelNineSliceSplitter,
    PixelAnimateText,
    PixelInterpolate,
    PixelSpritesheetGen,
    PixelTilesetGen,
    PixelGameUiGen,
    PixelUiElementsGen,
    PixelUiKitGen,
    PixelGameAssetPrep,
}

impl SkillKind {
    pub fn all() -> Vec<SkillKind> {
        use SkillKind::*;
        vec![
            GenerateArt,
            Spritesheet,
            NextFrame,
            Compress,
            RemoveBackground,
            PixelImageGen,
            PixelReduceColors,
            PixelFileCompressor,
            PixelRemoveBg,
            PixelEightDirCharacter,
            PixelNineSliceSplitter,
            PixelAnimateText,
            PixelInterpolate,
            PixelSpritesheetGen,
            PixelTilesetGen,
            PixelGameUiGen,
            PixelUiElementsGen,
            PixelUiKitGen,
            PixelGameAssetPrep,
        ]
    }

    /// Resolve a skill id string (as returned by [`SkillKind::to_string`]) back
    /// to a variant.
    pub fn from_id(id: &str) -> Option<SkillKind> {
        SkillKind::all().into_iter().find(|k| k.to_string() == id)
    }

    /// True for skills that run locally without a model / network.
    pub fn is_deterministic(self) -> bool {
        spec(self).model == ModelRole::None
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
            SkillKind::PixelImageGen => "pixel_image_gen",
            SkillKind::PixelReduceColors => "pixel_reduce_colors",
            SkillKind::PixelFileCompressor => "pixel_file_compressor",
            SkillKind::PixelRemoveBg => "pixel_remove_bg",
            SkillKind::PixelEightDirCharacter => "pixel_8dir_character",
            SkillKind::PixelNineSliceSplitter => "pixel_9slice_splitter",
            SkillKind::PixelAnimateText => "pixel_animate_text",
            SkillKind::PixelInterpolate => "pixel_interpolate",
            SkillKind::PixelSpritesheetGen => "pixel_spritesheet_gen",
            SkillKind::PixelTilesetGen => "pixel_tileset_gen",
            SkillKind::PixelGameUiGen => "pixel_game_ui_gen",
            SkillKind::PixelUiElementsGen => "pixel_ui_elements_gen",
            SkillKind::PixelUiKitGen => "pixel_ui_kit_gen",
            SkillKind::PixelGameAssetPrep => "pixel_game_asset_prep",
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
    /// Additional frames (multi-frame packing skills).
    pub images: Vec<RgbaImage>,
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

    /// Run a skill. Deterministic skills ignore `gen` (pass `None`); model-backed
    /// skills need an [`ImageGen`] client.
    pub fn run(
        gen: Option<&ImageGen>,
        kind: SkillKind,
        input: SkillInput,
    ) -> Result<SkillOutput, AiError> {
        match kind {
            SkillKind::GenerateArt => generate_art(require_gen(gen)?, input),
            SkillKind::Spritesheet => spritesheet(require_gen(gen)?, input),
            SkillKind::NextFrame => next_frame(require_gen(gen)?, input),
            SkillKind::Compress => compress(input),
            SkillKind::RemoveBackground => remove_background(input),
            SkillKind::PixelImageGen => pixel_image_gen(require_gen(gen)?, input),
            SkillKind::PixelReduceColors => pixel_reduce_colors(input),
            SkillKind::PixelFileCompressor => pixel_file_compressor(input),
            SkillKind::PixelRemoveBg => pixel_remove_bg(input),
            SkillKind::PixelEightDirCharacter => pack_frames_skill(input, "8-direction"),
            SkillKind::PixelAnimateText => pack_frames_skill(input, "animation"),
            SkillKind::PixelInterpolate => pack_frames_skill(input, "in-between"),
            SkillKind::PixelNineSliceSplitter => pixel_9slice_splitter(input),
            SkillKind::PixelSpritesheetGen => pixel_spritesheet_gen(input),
            SkillKind::PixelTilesetGen => pixel_tileset_gen(input),
            SkillKind::PixelGameUiGen => pixel_ui_slice(input),
            SkillKind::PixelUiElementsGen => pixel_ui_slice(input),
            SkillKind::PixelUiKitGen => pixel_ui_kit_gen(input),
            SkillKind::PixelGameAssetPrep => pixel_game_asset_prep(input),
        }
    }
}

fn require_gen(gen: Option<&ImageGen>) -> Result<&ImageGen, AiError> {
    gen.ok_or_else(|| AiError::Config("this skill requires a configured image model".into()))
}

fn spec(kind: SkillKind) -> SkillSpec {
    use SkillKind::*;
    match kind {
        GenerateArt => spec_gen(
            kind,
            "Generate art",
            "Generate a piece of pixel art from a text prompt.",
            "generation",
            ModelRole::Image,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "style": { "type": "string", "description": "Art style hint" },
                    "width": { "type": "integer", "description": "Target width in pixels" },
                    "height": { "type": "integer", "description": "Target height in pixels" }
                }
            }),
        ),
        Spritesheet => spec_gen(
            kind,
            "Spritesheet",
            "Generate a spritesheet grid and slice it into frames.",
            "generation",
            ModelRole::Image,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "cols": { "type": "integer", "description": "Number of columns" },
                    "rows": { "type": "integer", "description": "Number of rows" },
                    "frame_width": { "type": "integer" },
                    "frame_height": { "type": "integer" }
                }
            }),
        ),
        NextFrame => spec_gen(
            kind,
            "Predict next frame",
            "Create the next frame of an animation from the current frame.",
            "animation",
            ModelRole::Image,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "action": { "type": "string", "description": "What happens next" }
                }
            }),
        ),
        Compress => spec_gen(
            kind,
            "Compress to bit depth",
            "Reduce an image to a target bit depth (2^bits colors).",
            "utility",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "bits": { "type": "integer", "minimum": 1, "maximum": 8, "default": 4 }
                }
            }),
        ),
        RemoveBackground => spec_gen(
            kind,
            "Remove background",
            "Strip a near-uniform background by flood-filling from the edges.",
            "utility",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "tolerance": { "type": "number", "minimum": 0, "default": 32 }
                }
            }),
        ),
        PixelImageGen => spec_gen(
            kind,
            "Pixel image",
            "Generate a single clean game-ready pixel-art asset from a prompt or reference.",
            "generation",
            ModelRole::Image,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "style": { "type": "string", "description": "Art style" },
                    "resolution": { "type": "string", "description": "e.g. 64x64" },
                    "palette": { "type": "string", "description": "Named palette or family" },
                    "transparent": { "type": "boolean", "description": "Transparent background" }
                }
            }),
        ),
        PixelReduceColors => spec_gen(
            kind,
            "Reduce colors",
            "Reduce a PNG to a fixed color count, preserving alpha.",
            "utility",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "colors": { "type": "integer", "minimum": 2, "maximum": 256, "default": 16 },
                    "dither": { "type": "string", "enum": ["none", "floyd"], "default": "none" }
                }
            }),
        ),
        PixelFileCompressor => spec_gen(
            kind,
            "Compress file",
            "Quantize and optionally downscale a PNG to shrink its file size.",
            "utility",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "colors": { "type": "integer", "minimum": 0, "maximum": 256, "default": 0 },
                    "scale": { "type": "number", "minimum": 0.05, "maximum": 1.0, "default": 1.0 }
                }
            }),
        ),
        PixelRemoveBg => spec_gen(
            kind,
            "Remove background (keyed)",
            "Remove a flat, white or chroma-key background from a PNG.",
            "utility",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "mode": { "type": "string", "enum": ["auto", "key", "white"], "default": "auto" },
                    "tolerance": { "type": "integer", "minimum": 1, "maximum": 441, "default": 32 }
                }
            }),
        ),
        PixelEightDirCharacter => spec_gen(
            kind,
            "8-direction character",
            "Pack 8 direction frames into one canonical-order spritesheet.",
            "animation",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "layout": { "type": "string", "enum": ["8x1", "4x2", "2x4"], "default": "8x1" },
                    "pad": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 }
                }
            }),
        ),
        PixelNineSliceSplitter => spec_gen(
            kind,
            "9-slice splitter",
            "Split an image into 9-slice panels, a grid, or scattered objects.",
            "spritesheet",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "mode": { "type": "string", "enum": ["auto", "grid", "nineslice", "scatter"], "default": "auto" },
                    "cols": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 },
                    "rows": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 },
                    "insets": { "type": "string", "description": "comma-separated top,right,bottom,left" }
                }
            }),
        ),
        PixelAnimateText => spec_gen(
            kind,
            "Animate / pack frames",
            "Pack generated frames into a uniform anti-jitter spritesheet.",
            "animation",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "anchor": { "type": "string", "enum": ["bottom", "center"], "default": "bottom" },
                    "cols": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 },
                    "pad": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 }
                }
            }),
        ),
        PixelInterpolate => spec_gen(
            kind,
            "Interpolate / pack frames",
            "Pack endpoint + in-between frames into a uniform spritesheet.",
            "animation",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "anchor": { "type": "string", "enum": ["bottom", "center"], "default": "bottom" },
                    "cols": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 },
                    "pad": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 }
                }
            }),
        ),
        PixelSpritesheetGen => spec_gen(
            kind,
            "Spritesheet extractor",
            "Extract sprites from an irregular spritesheet into a uniform atlas.",
            "spritesheet",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "tol": { "type": "integer", "minimum": 1, "maximum": 441, "default": 45 },
                    "min_area": { "type": "integer", "minimum": 0, "default": 0 },
                    "padding": { "type": "integer", "minimum": 0, "maximum": 32, "default": 0 }
                }
            }),
        ),
        PixelTilesetGen => spec_gen(
            kind,
            "Tileset slicer",
            "Verify seamlessness and slice a tileset into individual tiles.",
            "spritesheet",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "tile": { "type": "integer", "minimum": 4, "maximum": 512 },
                    "cols": { "type": "integer", "minimum": 0, "maximum": 64, "default": 0 },
                    "rows": { "type": "integer", "minimum": 0, "maximum": 64, "default": 0 }
                }
            }),
        ),
        PixelGameUiGen => spec_gen(
            kind,
            "Game UI slicer",
            "Slice a UI image into components by connected alpha regions.",
            "ui",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "dilate": { "type": "integer", "minimum": 0, "maximum": 32, "default": 2 },
                    "min_area": { "type": "integer", "minimum": 1, "default": 32 },
                    "pad": { "type": "integer", "minimum": 0, "maximum": 64, "default": 2 }
                }
            }),
        ),
        PixelUiElementsGen => spec_gen(
            kind,
            "UI elements slicer",
            "Slice UI elements out of an image by connected alpha regions.",
            "ui",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "dilate": { "type": "integer", "minimum": 0, "maximum": 32, "default": 2 },
                    "min_area": { "type": "integer", "minimum": 1, "default": 32 },
                    "pad": { "type": "integer", "minimum": 0, "maximum": 64, "default": 2 }
                }
            }),
        ),
        PixelUiKitGen => spec_gen(
            kind,
            "UI kit splitter",
            "Split a batch UI sheet into component/state crops by projection bands.",
            "ui",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "bg": { "type": "string", "default": "FF00FF" },
                    "tol": { "type": "integer", "minimum": 1, "maximum": 441, "default": 60 },
                    "bridge": { "type": "integer", "minimum": 0, "maximum": 256, "default": 24 }
                }
            }),
        ),
        PixelGameAssetPrep => spec_gen(
            kind,
            "Asset prep (shadow)",
            "Convert a chroma-green shadow placeholder into a soft drop shadow.",
            "utility",
            ModelRole::None,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "max_alpha": { "type": "integer", "minimum": 0, "maximum": 255, "default": 150 },
                    "min_alpha": { "type": "integer", "minimum": 0, "maximum": 255, "default": 0 }
                }
            }),
        ),
    }
}

fn spec_gen(
    kind: SkillKind,
    name: &str,
    description: &str,
    category: &'static str,
    model: ModelRole,
    params_schema: serde_json::Value,
) -> SkillSpec {
    SkillSpec {
        id: kind.to_string(),
        name: name.into(),
        description: description.into(),
        category,
        model,
        params_schema,
    }
}

// ------------------------------------------------------------- skill bodies

fn require_image(input: &SkillInput) -> Result<&RgbaImage, AiError> {
    input.image.as_ref().ok_or(AiError::Image("skill requires an input image".into()))
}

fn require_frames(input: &SkillInput) -> Result<Vec<RgbaImage>, AiError> {
    let mut frames = Vec::new();
    if let Some(img) = &input.image {
        frames.push(img.clone());
    }
    frames.extend(input.images.iter().cloned());
    if frames.is_empty() {
        return Err(AiError::Image("skill requires at least one input image".into()));
    }
    Ok(frames)
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

fn param_usize(input: &SkillInput, key: &str, default: usize) -> usize {
    input
        .params
        .get(key)
        .and_then(|v| v.as_u64())
        .map(|v| v as usize)
        .unwrap_or(default)
}

fn generate_art(gen: &ImageGen, input: SkillInput) -> Result<SkillOutput, AiError> {
    let prompt = build_art_prompt(&input);
    let image = gen.generate_image(&prompt, None)?;
    Ok(SkillOutput { image: Some(image), ..Default::default() })
}

fn spritesheet(gen: &ImageGen, input: SkillInput) -> Result<SkillOutput, AiError> {
    let cols = param_usize(&input, "cols", 4).max(1);
    let rows = param_usize(&input, "rows", 1).max(1);
    let prompt = build_spritesheet_prompt(&input, cols, rows);
    let sheet = gen.generate_image(&prompt, None)?;
    let frames = image::slice_grid(&sheet, cols.max(1), rows.max(1));
    Ok(SkillOutput {
        image: Some(sheet),
        frames,
        ..Default::default()
    })
}

fn next_frame(gen: &ImageGen, input: SkillInput) -> Result<SkillOutput, AiError> {
    let current = require_image(&input)?;
    let prompt = build_next_frame_prompt(&input);
    let frame = gen.generate_image(&prompt, Some(current))?;
    Ok(SkillOutput { image: Some(frame), ..Default::default() })
}

fn pixel_image_gen(gen: &ImageGen, input: SkillInput) -> Result<SkillOutput, AiError> {
    let prompt = build_pixel_image_prompt(&input);
    let reference = if let Some(img) = &input.image {
        Some(img.clone())
    } else {
        None
    };
    let image = gen.generate_image(&prompt, reference.as_ref())?;
    Ok(SkillOutput { image: Some(image), ..Default::default() })
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

fn pixel_reduce_colors(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let colors = input
        .params
        .get("colors")
        .and_then(|v| v.as_u64())
        .map(|v| v.clamp(2, 256) as usize)
        .unwrap_or(16);
    let out = image::quantize(img, colors);
    Ok(SkillOutput {
        text: format!("reduced to {colors} colors"),
        image: Some(out),
        ..Default::default()
    })
}

fn pixel_file_compressor(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let colors = param_usize(&input, "colors", 0);
    let scale = input
        .params
        .get("scale")
        .and_then(|v| v.as_f64())
        .map(|v| v.clamp(0.05, 1.0) as f32)
        .unwrap_or(1.0);
    let mut out = image::downscale_nearest(img, scale);
    if colors > 0 {
        out = image::quantize(&out, colors.clamp(2, 256));
    }
    Ok(SkillOutput {
        text: format!("compressed (scale {scale}, {} colors)", if colors > 0 { colors.to_string() } else { "auto".into() }),
        image: Some(out),
        ..Default::default()
    })
}

fn pixel_remove_bg(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let tolerance = input
        .params
        .get("tolerance")
        .and_then(|v| v.as_u64())
        .map(|v| v.clamp(1, 441) as f32)
        .unwrap_or(32.0);
    let out = image::remove_background(img, tolerance);
    Ok(SkillOutput {
        text: format!("removed background (tolerance {tolerance})"),
        image: Some(out),
        ..Default::default()
    })
}

fn pack_frames_skill(input: SkillInput, label: &str) -> Result<SkillOutput, AiError> {
    let frames = require_frames(&input)?;
    let cols = param_usize(&input, "cols", 0);
    let pad = param_usize(&input, "pad", 0);
    let anchor = match input.params.get("anchor").and_then(|v| v.as_str()) {
        Some("center") => PackAnchor::Center,
        _ => PackAnchor::Bottom,
    };
    let cols = if cols > 0 { cols } else { frames.len().max(1) };
    let sheet = image::pack_frames(&frames, cols, pad, anchor);
    Ok(SkillOutput {
        text: format!("packed {label}: {} frames into a {}×{} sheet", frames.len(), sheet.width, sheet.height),
        image: Some(sheet),
        frames,
        ..Default::default()
    })
}

fn pixel_9slice_splitter(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let mode = input.params.get("mode").and_then(|v| v.as_str()).unwrap_or("auto");
    let cols = param_usize(&input, "cols", 0);
    let rows = param_usize(&input, "rows", 0);

    let frames = match mode {
        "grid" => image::slice_grid(img, cols.max(1), rows.max(1)),
        "nineslice" => {
            let insets = parse_insets(input.params.get("insets").and_then(|v| v.as_str()));
            image::slice_nineslice(img, insets)
        }
        "scatter" => {
            let min_area = param_usize(&input, "min_area", 32);
            let dilate = param_usize(&input, "dilate", 2);
            let pad = param_usize(&input, "pad", 2);
            crop_components(img, min_area, dilate, pad)
        }
        _ => {
            // auto: use insets if given, else grid if cols/rows given, else scatter
            if let Some(insets) = input.params.get("insets").and_then(|v| v.as_str()) {
                image::slice_nineslice(img, parse_insets(Some(insets)))
            } else if cols > 0 || rows > 0 {
                image::slice_grid(img, cols.max(1), rows.max(1))
            } else {
                crop_components(img, 32, 2, 2)
            }
        }
    };

    Ok(SkillOutput {
        text: format!("split into {} pieces", frames.len()),
        frames,
        ..Default::default()
    })
}

fn pixel_spritesheet_gen(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let min_area = param_usize(&input, "min_area", 0);
    let pad = param_usize(&input, "padding", 0);
    let frames = crop_components(img, min_area, 1, pad);
    Ok(SkillOutput {
        text: format!("extracted {} sprites", frames.len()),
        frames,
        ..Default::default()
    })
}

fn pixel_tileset_gen(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let tile = param_usize(&input, "tile", 16).max(1);
    let cols = param_usize(&input, "cols", 0);
    let rows = param_usize(&input, "rows", 0);
    let frames = image::slice_tiles(img, tile, cols, rows);
    let cols = if cols > 0 { cols } else { (img.width / tile).max(1) };
    let rows = if rows > 0 { rows } else { (img.height / tile).max(1) };
    Ok(SkillOutput {
        text: format!("sliced {cols}x{rows} tileset into {} tiles of {tile}px", frames.len()),
        frames,
        ..Default::default()
    })
}

fn pixel_ui_slice(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let min_area = param_usize(&input, "min_area", 32);
    let dilate = param_usize(&input, "dilate", 2);
    let pad = param_usize(&input, "pad", 2);
    let frames = crop_components(img, min_area, dilate, pad);
    Ok(SkillOutput {
        text: format!("sliced into {} components", frames.len()),
        frames,
        ..Default::default()
    })
}

fn pixel_ui_kit_gen(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let bg = input
        .params
        .get("bg")
        .and_then(|v| v.as_str())
        .and_then(|s| parse_hex_rgb(s))
        .unwrap_or([0xFF, 0x00, 0xFF]);
    let tol = input
        .params
        .get("tol")
        .and_then(|v| v.as_u64())
        .map(|v| v.clamp(1, 441) as u32)
        .unwrap_or(60);
    let bridge = param_usize(&input, "bridge", 24);
    let bands = image::split_bands(img, bg, tol, bridge);
    let frames: Vec<RgbaImage> = bands
        .iter()
        .map(|b| image::crop(img, b.x, b.y, b.width, b.height))
        .collect();
    Ok(SkillOutput {
        text: format!("split into {} pieces", frames.len()),
        frames,
        ..Default::default()
    })
}

fn pixel_game_asset_prep(input: SkillInput) -> Result<SkillOutput, AiError> {
    let img = require_image(&input)?;
    let max_alpha = input
        .params
        .get("max_alpha")
        .and_then(|v| v.as_u64())
        .map(|v| v.clamp(0, 255) as u8)
        .unwrap_or(150);
    let min_alpha = input
        .params
        .get("min_alpha")
        .and_then(|v| v.as_u64())
        .map(|v| v.clamp(0, 255) as u8)
        .unwrap_or(0);
    let out = image::chroma_to_shadow(img, min_alpha, max_alpha);
    Ok(SkillOutput {
        text: "converted chroma-green placeholder to drop shadow".into(),
        image: Some(out),
        ..Default::default()
    })
}

// ------------------------------------------------------------------ helpers

fn crop_components(img: &RgbaImage, min_area: usize, dilate: usize, pad: usize) -> Vec<RgbaImage> {
    image::find_components(img, min_area, dilate)
        .into_iter()
        .map(|b| {
            let x = b.x.saturating_sub(pad);
            let y = b.y.saturating_sub(pad);
            let w = b.width + pad * 2;
            let h = b.height + pad * 2;
            image::crop(img, x, y, w, h)
        })
        .collect()
}

fn parse_insets(s: Option<&str>) -> [usize; 4] {
    let mut out = [0usize; 4];
    if let Some(s) = s {
        for (i, part) in s.split(',').map(|p| p.trim()).take(4).enumerate() {
            out[i] = part.parse::<usize>().unwrap_or(0);
        }
    }
    out
}

fn parse_hex_rgb(s: &str) -> Option<[u8; 3]> {
    let s = s.trim_start_matches('#');
    if s.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&s[0..2], 16).ok()?;
    let g = u8::from_str_radix(&s[2..4], 16).ok()?;
    let b = u8::from_str_radix(&s[4..6], 16).ok()?;
    Some([r, g, b])
}

// ---------------------------------------------------------------- prompts

fn build_art_prompt(input: &SkillInput) -> String {
    let style = input.params.get("style").and_then(|v| v.as_str()).unwrap_or("pixel art");
    format!(
        "Create a single {style} image. {}\nClean pixels, crisp edges, no text or watermark.",
        input.prompt
    )
}

fn build_pixel_image_prompt(input: &SkillInput) -> String {
    let style = input.params.get("style").and_then(|v| v.as_str()).unwrap_or("pixel art");
    let mut extra = String::new();
    if let Some(res) = input.params.get("resolution").and_then(|v| v.as_str()) {
        extra.push_str(&format!(" Resolution: {res}. "));
    }
    if let Some(pal) = input.params.get("palette").and_then(|v| v.as_str()) {
        extra.push_str(&format!(" Palette: {pal}. "));
    }
    if input.params.get("transparent").and_then(|v| v.as_bool()).unwrap_or(false) {
        extra.push_str(" Fully transparent background. ");
    }
    format!(
        "Create a single {style} game-ready asset. {extra} {}\nOne asset per image. \
         Crisp pixels, no blur, no anti-aliasing, no text or watermark.",
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

// ------------------------------------------------------ output -> JSON (FFI)

/// Encode a skill output as a JSON string (`text`, base64 `image`, base64
/// `frames`) for transport across the FFI boundary.
pub fn skill_output_to_json(output: &SkillOutput) -> String {
    use base64::Engine as _;
    let b64 = |img: &RgbaImage| -> String {
        match image::encode_png(img) {
            Ok(png) => base64::engine::general_purpose::STANDARD.encode(&png),
            Err(_) => String::new(),
        }
    };
    let image = output.image.as_ref().map(b64);
    let frames: Vec<String> = output.frames.iter().map(b64).collect();
    serde_json::json!({
        "text": output.text,
        "image": image,
        "frames": frames,
    })
    .to_string()
}
