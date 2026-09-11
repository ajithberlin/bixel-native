//! Provider-backed pixel-art skills exposed as the goose `bixel` tool extension.
//!
//! goose has no image-generation API, so the image skills live here and are
//! dispatched through an [`ImageGenerator`]. Everything deterministic is a
//! bundled `SKILL.md` package handled by goose's native skills extension.

use serde::{Deserialize, Serialize};

use crate::error::AiError;
use crate::image::{self, RgbaImage};
use crate::image_gen::ImageGenerator;

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
///
/// Only the provider-backed image skills live here: goose has no image
/// generation API, so these are exposed as the `bixel` tool extension. Every
/// other (deterministic / local) skill is a bundled `SKILL.md` package that
/// goose's native skills extension discovers and runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillKind {
    ImageGen,
    GenerateArt,
    Spritesheet,
    NextFrame,
    PixelImageGen,
}

impl SkillKind {
    pub fn all() -> Vec<SkillKind> {
        use SkillKind::*;
        vec![ImageGen, GenerateArt, Spritesheet, NextFrame, PixelImageGen]
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
            SkillKind::ImageGen => "image_gen",
            SkillKind::GenerateArt => "generate_art",
            SkillKind::Spritesheet => "spritesheet",
            SkillKind::NextFrame => "next_frame",
            SkillKind::PixelImageGen => "pixel_image_gen",
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

/// Per-frame timeline metadata produced alongside sliced `frames`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrameMeta {
    #[serde(default)]
    pub duration_ms: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
}

impl FrameMeta {
    pub fn new(duration_ms: u32, tag: Option<String>) -> Self {
        FrameMeta { duration_ms: duration_ms.max(1), tag }
    }
}

/// Output of a skill run: optional text, single image, and/or sliced frames.
#[derive(Debug, Clone, Default)]
pub struct SkillOutput {
    /// Unmodified model output, kept separately from the prepared asset.
    pub source_image: Option<RgbaImage>,
    pub text: String,
    pub image: Option<RgbaImage>,
    pub frames: Vec<RgbaImage>,
    /// Timeline metadata aligned with `frames` (durations + tag/action names).
    pub frame_meta: Vec<FrameMeta>,
    /// Optional atlas/sheet manifest (JSON) describing the frames so the result
    /// can be re-imported as a project or animation.
    pub atlas: Option<String>,
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
    /// skills need an [`ImageGenerator`] backend.
    pub fn run(
        gen: Option<&dyn ImageGenerator>,
        kind: SkillKind,
        input: SkillInput,
    ) -> Result<SkillOutput, AiError> {
        match kind {
            SkillKind::ImageGen => image_gen(require_gen(gen)?, input),
            SkillKind::GenerateArt => generate_art(require_gen(gen)?, input),
            SkillKind::Spritesheet => spritesheet(require_gen(gen)?, input),
            SkillKind::NextFrame => next_frame(require_gen(gen)?, input),
            SkillKind::PixelImageGen => pixel_image_gen(require_gen(gen)?, input),
        }
        .map(normalize_frame_meta)
    }
}

/// Ensure every frame has aligned metadata so downstream importers can rely on
/// `frame_meta.len() == frames.len()`.
fn normalize_frame_meta(mut output: SkillOutput) -> SkillOutput {
    if output.frame_meta.len() != output.frames.len() {
        output.frame_meta = vec![FrameMeta::new(100, None); output.frames.len()];
    }
    output
}

fn require_gen(gen: Option<&dyn ImageGenerator>) -> Result<&dyn ImageGenerator, AiError> {
    gen.ok_or_else(|| {
        AiError::Config(
            "this skill needs the image model role, which is not ready — \
             connect a provider with image generation enabled in the AI settings"
                .into(),
        )
    })
}

fn spec(kind: SkillKind) -> SkillSpec {
    use SkillKind::*;
    match kind {
        ImageGen => spec_gen(
            kind,
            "Image generation",
            "Generate an image or edit a reference image through the configured provider image backend.",
            "generation",
            ModelRole::Image,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "style": { "type": "string", "description": "Optional visual style" },
                    "transparent": { "type": "boolean", "default": false }
                }
            }),
        ),
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
            "Create the next animation frame from the current frame. The current \
             frame is sent as an image-to-image reference so the pose, palette, \
             background, and canvas stay consistent with the sequence.",
            "animation",
            ModelRole::Image,
            serde_json::json!({
                "type": "object",
                "properties": {
                    "action": { "type": "string", "description": "The motion to advance, e.g. 'walk forward one step' or 'swing the sword'. Keep it a small increment." }
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
    }
}

fn spec_gen(
    kind: SkillKind,
    name: &str,
    description: &str,
    category: &'static str,
    model: ModelRole,
    mut params_schema: serde_json::Value,
) -> SkillSpec {
    if model == ModelRole::Image {
        let props = params_schema["properties"].as_object_mut().unwrap();
        let dimensions = if kind == SkillKind::Spritesheet { ["frame_width", "frame_height"] } else { ["width", "height"] };
        for key in dimensions {
            props.insert(key.into(), serde_json::json!({"type":"integer","minimum":1,"maximum":4096,"description":"Explicit output pixels per asset/frame; supply both dimensions together. Omit both to retain source size."}));
        }
        if kind == SkillKind::Spritesheet {
            for key in ["cols", "rows"] {
                props.insert(key.into(), serde_json::json!({"type":"integer","minimum":1,"maximum":64,"description":"Grid count; at most 256 total cells, prepared sheet at most 4096 pixels per side"}));
            }
        }
        props.insert("transparent".into(), serde_json::json!({"type":"boolean","default":true,"description":"Sprite background transparency; false for opaque backgrounds/terrain."}));
        props.insert("palette".into(), serde_json::json!({"type":"string","description":"Palette colors/style guidance for generation"}));
    }
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

fn image_gen(gen: &dyn ImageGenerator, mut input: SkillInput) -> Result<SkillOutput, AiError> {
    // General image generation is opaque by default. Pixel-specific skills
    // retain their transparent-sprite default.
    if !input.params.is_object() {
        input.params = serde_json::json!({});
    }
    if input.params.get("transparent").is_none() {
        input.params["transparent"] = serde_json::Value::Bool(false);
    }
    generation_target(&input, None)?;
    let style = input.params.get("style").and_then(|v| v.as_str()).unwrap_or("");
    let style_hint = if style.trim().is_empty() {
        String::new()
    } else {
        format!(" Visual style: {style}.")
    };
    let prompt = format!(
        "Create one finished image. {}{} {}",
        input.prompt.trim(),
        style_hint,
        generation_guidance(&input)
    );
    let image = gen.generate_image(&prompt, input.image.as_ref())?;
    prepare_generated(image, &input, None)
}

fn generate_art(gen: &dyn ImageGenerator, input: SkillInput) -> Result<SkillOutput, AiError> {
    generation_target(&input, None)?;
    let prompt = format!("{} {}", build_art_prompt(&input), generation_guidance(&input));
    let image = gen.generate_image(&prompt, None)?;
    prepare_generated(image, &input, None)
}

fn spritesheet(gen: &dyn ImageGenerator, input: SkillInput) -> Result<SkillOutput, AiError> {
    let (cols, rows) = generation_grid(&input)?;
    generation_target(&input, Some((cols, rows)))?;
    let prompt = format!("{} {}", build_spritesheet_prompt(&input, cols, rows), generation_guidance(&input));
    let sheet = gen.generate_image(&prompt, None)?;
    prepare_generated(sheet, &input, Some((cols, rows)))
}

fn next_frame(gen: &dyn ImageGenerator, mut input: SkillInput) -> Result<SkillOutput, AiError> {
    let current = require_image(&input)?.clone();
    if !input.params.is_object() {
        input.params = serde_json::json!({});
    }
    // The next frame has to line up with the frame it came from, so pin the
    // output to the source dimensions unless the caller asked for a target.
    if input.params.get("width").is_none() && input.params.get("height").is_none() {
        input.params["width"] = serde_json::json!(current.width);
        input.params["height"] = serde_json::json!(current.height);
    }
    // Match the source's alpha policy: transparent sprite frames stay
    // transparent, opaque scenes stay opaque so no matte is invented.
    if input.params.get("transparent").is_none() {
        let has_alpha = current.data.chunks_exact(4).any(|p| p[3] < 255);
        input.params["transparent"] = serde_json::Value::Bool(has_alpha);
    }
    generation_target(&input, None)?;
    let prompt = format!("{} {}", build_next_frame_prompt(&input), generation_guidance(&input));
    let frame = gen.generate_image(&prompt, Some(&current))?;
    let mut output = prepare_generated(frame, &input, None)?;
    output.text = format!(
        "Predicted the next frame from the {} × {} source frame.",
        current.width, current.height
    );
    Ok(output)
}

fn pixel_image_gen(gen: &dyn ImageGenerator, input: SkillInput) -> Result<SkillOutput, AiError> {
    generation_target(&input, None)?;
    let prompt = format!("{} {}", build_pixel_image_prompt(&input), generation_guidance(&input));
    let reference = if let Some(img) = &input.image {
        Some(img.clone())
    } else {
        None
    };
    let image = gen.generate_image(&prompt, reference.as_ref())?;
    prepare_generated(image, &input, None)
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
    if input.params.get("transparent").and_then(|v| v.as_bool()).unwrap_or(true) {
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
         the grid, with consistent empty margins and no gutters. No text or watermark.",
        input.prompt
    )
}

fn build_next_frame_prompt(input: &SkillInput) -> String {
    let action = input
        .params
        .get("action")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("continue the motion");
    format!(
        "You are given the CURRENT frame of a 2D pixel-art animation. Produce exactly ONE image: the NEXT frame in the sequence.\n\
         Hard requirements:\n\
         - Same canvas size, camera, framing, palette, outline weight, and pixel density as the input frame.\n\
         - Keep every non-moving part identical to the input: background, props, lighting, outlines, and the character's still limbs.\n\
         - Advance only the motion: {action}. Move by a small, plausible increment (about one sixth to one third of the full action) so consecutive frames read smoothly as an animation — not a large pose change.\n\
         - Preserve the input's transparent regions exactly. Never paint a checkerboard or backdrop, and add no text, border, shadow, or watermark.\n\
         - Do not zoom, crop, re-frame, recolor, or restyle the scene. Output only the single next frame."
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
        "source_image": output.source_image.as_ref().map(b64),
        "frames": frames,
        "frame_meta": output.frame_meta,
        "atlas": output.atlas,
    })
    .to_string()
}

#[cfg(test)]
mod preparation_tests {
    use super::*;
    fn input(params: serde_json::Value) -> SkillInput {
        SkillInput {
            params,
            ..Default::default()
        }
    }
    #[test]
    fn explicit_size_fits_and_retains_source() {
        let mut source = RgbaImage::new(80, 40);
        source.data.fill(255);
        let output = prepare_generated(
            source.clone(),
            &input(serde_json::json!({"width":16,"height":16,"transparent":false})),
            None,
        )
        .unwrap();
        let image = output.image.unwrap();
        assert_eq!((image.width, image.height), (16, 16));
        // Opaque assets use a cover fit, so preparation does not invent
        // transparent margins when the source and target aspect ratios differ.
        assert_eq!(image.pixel(0, 0)[3], 255);
        assert_eq!(image.pixel(8, 8)[3], 255);
        assert_eq!(output.source_image.unwrap().data, source.data);
    }
    #[test]
    fn no_target_keeps_original_and_reports_alpha() {
        let mut source = RgbaImage::new(4, 4);
        source.data.fill(255);
        let output =
            prepare_generated(source.clone(), &input(serde_json::json!({})), None).unwrap();
        assert_eq!(output.source_image.unwrap().data, source.data);
        assert!(output.text.contains("opaque"));
    }

    #[test]
    fn transparent_target_crops_subject_before_fitting() {
        let mut source = RgbaImage::new(16, 16);
        for y in 6..10 {
            for x in 5..9 {
                source.set_pixel(x, y, [220, 90, 40, 255]);
            }
        }
        let output = prepare_generated(
            source,
            &input(serde_json::json!({"width": 4, "height": 4, "transparent": true})),
            None,
        )
        .unwrap();
        let image = output.image.unwrap();

        assert_eq!((image.width, image.height), (4, 4));
        assert!(image.data.chunks_exact(4).all(|p| p == [220, 90, 40, 255]));
    }
    #[test]
    fn uniform_backdrop_removed_without_erasing_enclosed_same_color() {
        let mut source = RgbaImage::new(5, 5);
        source.data.fill(255);
        for y in 1..4 {
            for x in 1..4 {
                source.set_pixel(x, y, [255, 0, 0, 255]);
            }
        }
        source.set_pixel(2, 2, [255, 255, 255, 255]);
        let output = prepare_generated(
            source.clone(),
            &input(serde_json::json!({"width":5,"height":5})),
            None,
        )
        .unwrap();
        let image = output.image.unwrap();
        assert_eq!(image.pixel(0, 0)[3], 0);
        assert_eq!(image.pixel(2, 2), [255, 255, 255, 255]);
        assert_eq!(output.source_image.unwrap(), source);
    }
    #[test]
    fn mixed_border_and_existing_alpha_are_preserved() {
        let mut source = RgbaImage::new(3, 3);
        source.data.fill(255);
        source.set_pixel(0, 0, [20, 30, 40, 255]);
        assert_eq!(prepare_matte(&source), source);
        source.set_pixel(0, 0, [20, 30, 40, 0]);
        assert_eq!(prepare_matte(&source), source);
    }
    #[test]
    fn invalid_targets_rejected() {
        for params in [
            serde_json::json!({"width":16}),
            serde_json::json!({"width":0,"height":16}),
            serde_json::json!({"width":"16","height":16}),
            serde_json::json!({"width":999999,"height":16}),
        ] {
            assert!(generation_target(&input(params), None).is_err());
        }
    }
    #[test]
    fn invalid_sheet_keeps_source_for_review() {
        let source = RgbaImage::new(7, 5);
        let output = prepare_generated(
            source.clone(),
            &input(serde_json::json!({"frame_width":8,"frame_height":8})),
            Some((2, 1)),
        )
        .unwrap();
        assert!(output.frames.is_empty());
        assert_eq!(output.source_image.unwrap(), source);
        assert!(output.text.contains("No frames prepared"));
        assert!(generation_grid(&input(serde_json::json!({"cols":0}))).is_err());
        assert!(generation_grid(&input(serde_json::json!({"cols":64,"rows":64}))).is_err());
        assert!(generation_target(
            &input(serde_json::json!({"frame_width":4096,"frame_height":32})),
            Some((2, 1))
        )
        .is_err());
    }
    #[test]
    fn sheet_cells_use_explicit_frame_budget() {
        let output = prepare_generated(
            RgbaImage::new(80, 40),
            &input(serde_json::json!({"frame_width":8,"frame_height":12})),
            Some((2, 1)),
        )
        .unwrap();
        assert_eq!(output.frames.len(), 2);
        assert!(output.frames.iter().all(|f| f.width == 8 && f.height == 12));
        let sheet = output.image.unwrap();
        assert_eq!((sheet.width, sheet.height), (16, 12));
    }
}

fn generation_grid(input: &SkillInput) -> Result<(usize, usize), AiError> {
    let read = |key: &str, default| -> Result<usize, AiError> {
        match input.params.get(key) {
            None => Ok(default),
            Some(v) => v
                .as_u64()
                .filter(|n| (1..=64).contains(n))
                .map(|n| n as usize)
                .ok_or_else(|| AiError::Image(format!("{key} must be an integer from 1 to 64"))),
        }
    };
    let grid = (read("cols", 4)?, read("rows", 1)?);
    if grid.0 * grid.1 > 256 {
        return Err(AiError::Image(
            "At most 256 sheet cells are supported".into(),
        ));
    }
    Ok(grid)
}

fn generation_target(
    input: &SkillInput,
    grid: Option<(usize, usize)>,
) -> Result<Option<(usize, usize)>, AiError> {
    if input
        .params
        .get("transparent")
        .is_some_and(|v| !v.is_boolean())
    {
        return Err(AiError::Image("transparent must be a boolean".into()));
    }
    let (wk, hk) = if grid.is_some() {
        ("frame_width", "frame_height")
    } else {
        ("width", "height")
    };
    if grid.is_some()
        && (input.params.get("width").is_some() || input.params.get("height").is_some())
    {
        return Err(AiError::Image(
            "Sheets require frame_width and frame_height, not whole-image width/height".into(),
        ));
    }
    let (w, h) = (input.params.get(wk), input.params.get(hk));
    if w.is_none() && h.is_none() {
        return Ok(None);
    }
    let read = |v: Option<&serde_json::Value>| {
        v.and_then(|v| v.as_u64())
            .filter(|n| (1..=4096).contains(n))
            .map(|n| n as usize)
    };
    let (Some(w), Some(h)) = (read(w), read(h)) else {
        return Err(AiError::Image(format!(
            "Supply both {wk} and {hk} as integers from 1 to 4096"
        )));
    };
    let (cols, rows) = grid.unwrap_or((1, 1));
    if w * cols > 4096 || h * rows > 4096 {
        return Err(AiError::Image(
            "Prepared image must fit within 4096 × 4096 pixels".into(),
        ));
    }
    Ok(Some((w, h)))
}

fn generation_guidance(input: &SkillInput) -> String {
    let mut guidance = if input
        .params
        .get("transparent")
        .and_then(|v| v.as_bool())
        .unwrap_or(true)
    {
        "Use a truly transparent background, never a painted checkerboard. If alpha is unavailable, use a single flat contrasting backdrop with clear margins; keep the subject away from all edges.".to_owned()
    } else {
        "Create an opaque background as requested.".to_owned()
    };
    let w = input
        .params
        .get("frame_width")
        .or_else(|| input.params.get("width"));
    let h = input
        .params
        .get("frame_height")
        .or_else(|| input.params.get("height"));
    if let (Some(w), Some(h)) = (w, h) {
        guidance.push_str(&format!(" Final pixel budget per asset/frame is {w} × {h}: use a readable silhouette and large pixel clusters; avoid fine detail that disappears at this size."));
    }
    if let Some(palette) = input.params.get("palette").and_then(|v| v.as_str()) {
        guidance.push_str(&format!(" Palette: {palette}."));
    }
    guidance
}

/// Fit using nearest-neighbor sampling and transparent, centered padding.
fn fit_generated(source: &RgbaImage, width: usize, height: usize) -> RgbaImage {
    let scale = (width as f64 / source.width as f64).min(height as f64 / source.height as f64);
    let w = ((source.width as f64 * scale).round() as usize).clamp(1, width);
    let h = ((source.height as f64 * scale).round() as usize).clamp(1, height);
    let mut out = RgbaImage::new(width, height);
    for y in 0..h {
        for x in 0..w {
            out.set_pixel(
                x + (width - w) / 2,
                y + (height - h) / 2,
                source.pixel(x * source.width / w, y * source.height / h),
            );
        }
    }
    out
}

/// Fit an opaque asset without introducing transparent margins. The source is
/// scaled to cover the target and the centered excess is cropped.
fn fit_generated_opaque(source: &RgbaImage, width: usize, height: usize) -> RgbaImage {
    let scale = (width as f64 / source.width as f64).max(height as f64 / source.height as f64);
    let w = ((source.width as f64 * scale).round() as usize).max(width);
    let h = ((source.height as f64 * scale).round() as usize).max(height);
    let crop_x = w.saturating_sub(width) / 2;
    let crop_y = h.saturating_sub(height) / 2;
    let mut out = RgbaImage::new(width, height);
    for y in 0..height {
        for x in 0..width {
            let sx = ((x + crop_x) * source.width / w).min(source.width - 1);
            let sy = ((y + crop_y) * source.height / h).min(source.height - 1);
            out.set_pixel(x, y, source.pixel(sx, sy));
        }
    }
    out
}

/// Only remove a uniform edge-connected backdrop. Mixed edges can contain
/// subject colors; preserving those pixels is safer than guessing a matte.
fn prepare_matte(source: &RgbaImage) -> RgbaImage {
    if source.data.chunks_exact(4).any(|p| p[3] < 255) {
        return source.clone();
    }
    let color = source.pixel(0, 0);
    let uniform = (0..source.width)
        .all(|x| source.pixel(x, 0) == color && source.pixel(x, source.height - 1) == color)
        && (0..source.height)
            .all(|y| source.pixel(0, y) == color && source.pixel(source.width - 1, y) == color);
    if !uniform {
        return source.clone();
    }
    let result = image::remove_background(source, 0.0);
    if result.data.chunks_exact(4).all(|p| p[3] == 0) {
        source.clone()
    } else {
        result
    }
}

/// Trim transparent padding only when the requested target would actually
/// reduce the source. A smaller subject should not be enlarged just because
/// transparent margins were removed.
fn trim_for_target(source: &RgbaImage, width: usize, height: usize) -> RgbaImage {
    if source.width > width || source.height > height {
        image::crop_to_content(source, 0, 0)
    } else {
        source.clone()
    }
}

fn prepare_generated(
    source: RgbaImage,
    input: &SkillInput,
    grid: Option<(usize, usize)>,
) -> Result<SkillOutput, AiError> {
    let target = generation_target(input, grid)?;
    if source.width == 0 || source.height == 0 {
        return Err(AiError::Image("Model returned an empty image".into()));
    }
    if let Some((cols, rows)) = grid {
        if cols == 0 || rows == 0 || source.width % cols != 0 || source.height % rows != 0 {
            return Ok(SkillOutput {
                text: "Source retained unchanged: generated sheet dimensions do not divide evenly into the requested grid. No frames prepared; regenerate or crop before slicing.".into(),
                image: Some(source.clone()), source_image: Some(source), ..Default::default()
            });
        }
    }
    let transparent = input
        .params
        .get("transparent")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    let working = if target.is_some() && transparent {
        prepare_matte(&source)
    } else {
        source.clone()
    };
    let mut frames = Vec::new();
    let prepared = if let Some((cols, rows)) = grid {
        frames = image::slice_grid(&working, cols, rows);
        if let Some((w, h)) = target {
            frames = frames.iter().map(|f| {
                if transparent {
                    let cropped = trim_for_target(f, w, h);
                    fit_generated(&cropped, w, h)
                } else {
                    fit_generated_opaque(f, w, h)
                }
            }).collect();
            let mut sheet = RgbaImage::new(w * cols, h * rows);
            for (i, f) in frames.iter().enumerate() {
                for y in 0..h {
                    for x in 0..w {
                        sheet.set_pixel((i % cols) * w + x, (i / cols) * h + y, f.pixel(x, y));
                    }
                }
            }
            sheet
        } else {
            working.clone()
        }
    } else if let Some((w, h)) = target {
        if transparent {
            let cropped = trim_for_target(&working, w, h);
            fit_generated(&cropped, w, h)
        } else {
            fit_generated_opaque(&working, w, h)
        }
    } else {
        working.clone()
    };
    let clear = working.data.chunks_exact(4).filter(|p| p[3] == 0).count();
    let visible = working.data.chunks_exact(4).filter(|p| p[3] > 0).count();
    let alpha = if visible == 0 {
        "empty alpha: no visible subject"
    } else if clear == 0 {
        "opaque: no fully transparent background pixels"
    } else {
        "alpha present; inspect subject edges"
    };
    let text = format!(
        "Source retained at {} × {}. Output {} × {}. Alpha validation before padding: {alpha}. {}",
        source.width,
        source.height,
        prepared.width,
        prepared.height,
        if target.is_none() {
            "No explicit target: source pixels unchanged."
        } else {
            "Prepared with aspect fit and transparent padding."
        }
    );
    let frame_meta = vec![FrameMeta::new(100, None); frames.len()];
    // Emit a Bixel-export manifest for grid sheets so the prepared sheet can be
    // re-imported as an animation with the exact frame geometry.
    let atlas = grid.and_then(|(cols, rows)| {
        if frames.is_empty() || cols == 0 || rows == 0 {
            return None;
        }
        let frame_w = prepared.width / cols;
        let frame_h = prepared.height / rows;
        if frame_w == 0 || frame_h == 0 {
            return None;
        }
        let rects: Vec<serde_json::Value> = (0..frames.len())
            .map(|i| {
                serde_json::json!({
                    "x": (i % cols) * frame_w,
                    "y": (i / cols) * frame_h,
                    "width": frame_w,
                    "height": frame_h,
                    "duration_ms": 100,
                })
            })
            .collect();
        Some(
            serde_json::json!({
                "frame_width": frame_w,
                "frame_height": frame_h,
                "columns": cols,
                "frames": rects,
            })
            .to_string(),
        )
    });
    Ok(SkillOutput {
        text,
        image: Some(prepared),
        source_image: Some(source),
        frames,
        frame_meta,
        atlas,
    })
}
