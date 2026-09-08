//! The goose-backed engine: a thin, synchronous facade over the goose SDK's
//! OpenRouter provider for text, vision and image generation.

use std::sync::{Arc, Mutex};

use base64::Engine as _;
use goose_sdk::bindings::{
    self, MessageContent, MessageRole, ProviderMessage, ProviderModelConfig, ProviderTool,
};

use crate::config::{openrouter_provider_json, AiSettings};
use crate::error::AiError;
use crate::image::{encode_png, RgbaImage};
use crate::skills::{SkillInput, SkillKind, SkillOutput, Skills};

/// Upper bound on tool-call rounds before the agent gives up.
const MAX_TOOL_ROUNDS: usize = 6;

/// A single chat conversation: its system prompt plus the full message history.
///
/// The goose SDK exposes a *provider* primitive (`complete`/`stream`/`compact`),
/// not an agent loop — session state is the caller's responsibility. Keeping the
/// history here and replaying it verbatim on every turn is what makes goose's
/// context windowing and prompt caching actually work (a stable prefix is what
/// the provider's token cache keys on).
#[derive(Debug, Clone)]
pub struct Session {
    system: String,
    messages: Vec<ProviderMessage>,
}

impl Session {
    fn new() -> Self {
        Session { system: String::new(), messages: Vec::new() }
    }

    /// Re-arm the session for a new conversation (or clear it).
    fn reset(&mut self, system: &str) {
        self.system = system.to_string();
        self.messages.clear();
    }

    /// Number of messages currently in the history.
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    pub fn system(&self) -> &str {
        &self.system
    }
}

/// A synchronous wrapper around an OpenRouter provider constructed through the
/// goose SDK. Holds its own tokio runtime so the FFI / UI layer can call it
/// without an async context.
pub struct Engine {
    provider: Arc<bindings::Provider>,
    settings: AiSettings,
    runtime: tokio::runtime::Runtime,
    session: Mutex<Session>,
}

impl Engine {
    pub fn new(settings: AiSettings) -> Result<Self, AiError> {
        if !settings.has_key() {
            return Err(AiError::Config(
                "OPENROUTER_API_KEY is not set (see .env.example)".into(),
            ));
        }
        let json = openrouter_provider_json(&settings);
        let provider = bindings::declarative_provider_from_json(json)
            .map_err(|e| AiError::Provider(e.to_string()))?;
        let runtime = tokio::runtime::Runtime::new()
            .map_err(|e| AiError::Provider(format!("failed to start runtime: {e}")))?;
        // The blocking reqwest client uses rustls without a default provider;
        // install the ring backend once (idempotent).
        let _ = rustls::crypto::ring::default_provider().install_default();
        Ok(Engine { provider, settings, runtime, session: Mutex::new(Session::new()) })
    }

    pub fn settings(&self) -> &AiSettings {
        &self.settings
    }

    fn model_config(&self, name: &str) -> ProviderModelConfig {
        ProviderModelConfig {
            model_name: name.to_string(),
            context_limit: None,
            temperature: Some(0.8),
            max_tokens: None,
            toolshim: false,
            toolshim_model: None,
            request_params_json: None,
            provider_params_json: None,
            reasoning: None,
            timeout_ms: None,
            request_headers: None,
        }
    }

    fn user(content: Vec<MessageContent>) -> ProviderMessage {
        ProviderMessage { role: MessageRole::User, content }
    }

    fn text(content: &str) -> MessageContent {
        MessageContent::Text { text: content.to_string() }
    }

    fn image(mime: &str, data: Vec<u8>) -> MessageContent {
        MessageContent::Image { mime_type: mime.to_string(), data }
    }

    async fn complete(
        &self,
        model: &str,
        system: &str,
        messages: Vec<ProviderMessage>,
        tools: Vec<ProviderTool>,
    ) -> Result<bindings::ProviderCompletion, AiError> {
        self.provider
            .complete(self.model_config(model), system.to_string(), messages, tools)
            .await
            .map_err(|e| AiError::Provider(e.to_string()))
    }

    // ---------------------------------------------------------- public API

    /// Text completion with the configured text model.
    pub fn complete_text(&self, prompt: &str, system: &str) -> Result<String, AiError> {
        let messages = vec![Self::user(vec![Self::text(prompt)])];
        let model = self.settings.text_model.clone();
        let completion = self.runtime.block_on(self.complete(&model, system, messages, vec![]))?;
        Ok(concat_text(&completion.content))
    }

    /// Vision completion: describe/transform an image with the vision model.
    pub fn describe(&self, prompt: &str, image: &RgbaImage) -> Result<String, AiError> {
        let png = encode_png(image)?;
        let messages = vec![Self::user(vec![
            Self::image("image/png", png),
            Self::text(prompt),
        ])];
        let model = self.settings.vision_model.clone();
        let completion = self.runtime.block_on(self.complete(&model, prompt, messages, vec![]))?;
        Ok(concat_text(&completion.content))
    }

    /// Image generation (optionally conditioned on an input image for edits).
    ///
    /// OpenRouter image models live behind the `/api/v1/images/*` endpoints, not
    /// `/chat/completions`, so this talks to them directly rather than through
    /// the goose provider (which only does chat completions).
    pub fn generate_image(&self, prompt: &str, input: Option<&RgbaImage>) -> Result<RgbaImage, AiError> {
        match input {
            None => self.image_generations(prompt),
            Some(img) => self.image_edits(prompt, img),
        }
    }

    /// Raw text from an image model call — useful for diagnostics.
    pub fn generate_image_raw(&self, prompt: &str, input: Option<&RgbaImage>) -> Result<String, AiError> {
        let mut content = Vec::new();
        if let Some(input) = input {
            content.push(Self::image("image/png", encode_png(input)?));
        }
        content.push(Self::text(prompt));
        let messages = vec![Self::user(content)];
        let model = self.settings.image_model.clone();
        let completion = self.runtime.block_on(self.complete(&model, prompt, messages, vec![]))?;
        Ok(concat_text(&completion.content))
    }

    // ---------------------------------------------------------- tool agent

    /// Chat with tool use: the text model may call the pixel-art skills as
    /// tools; their results are fed back until it produces a final answer.
    ///
    /// The conversation is stateful: each call appends to the engine's session
    /// and replays the full history to the provider, so the model keeps the
    /// context of previous turns (and the provider's token cache stays warm).
    /// A change of `system` prompt starts a fresh conversation.
    pub fn chat(&self, prompt: &str, system: &str) -> Result<String, AiError> {
        let tools = self.skill_tools();
        let model = self.settings.text_model.clone();
        let mut session = self
            .session
            .lock()
            .map_err(|_| AiError::Provider("session lock poisoned".into()))?;

        if session.system != system {
            session.reset(system);
        }

        session.messages.push(Self::user(vec![Self::text(prompt)]));

        for _ in 0..MAX_TOOL_ROUNDS {
            let completion = self.runtime.block_on(self.complete(
                &model,
                &session.system,
                session.messages.clone(),
                tools.clone(),
            ))?;

            let requests: Vec<(String, String, String)> = completion
                .content
                .iter()
                .filter_map(|c| match c {
                    MessageContent::ToolRequest { id, name, arguments_json, .. } => {
                        Some((id.clone(), name.clone(), arguments_json.clone()))
                    }
                    _ => None,
                })
                .collect();

            if requests.is_empty() {
                let text = concat_text(&completion.content);
                if text.trim().is_empty() {
                    return Err(AiError::NoText);
                }
                session.messages.push(ProviderMessage {
                    role: MessageRole::Assistant,
                    content: completion.content.clone(),
                });
                return Ok(text);
            }

            session.messages.push(ProviderMessage {
                role: MessageRole::Assistant,
                content: completion.content.clone(),
            });

            let results: Vec<MessageContent> = requests
                .into_iter()
                .map(|(id, name, args)| {
                    let (success, text) = match self.execute_tool(&name, &args) {
                        Ok(t) => (true, t),
                        Err(e) => (false, e),
                    };
                    tool_result(id, success, text)
                })
                .collect();
            session.messages.push(ProviderMessage { role: MessageRole::Tool, content: results });
        }

        Err(AiError::Provider("assistant kept calling tools without finishing".into()))
    }

    /// Forget the current conversation so the next `chat` starts fresh.
    pub fn reset_chat(&self) {
        if let Ok(mut session) = self.session.lock() {
            session.reset("");
        }
    }

    /// Current chat history length (for diagnostics / tests).
    pub fn session_len(&self) -> usize {
        self.session.lock().map(|s| s.len()).unwrap_or(0)
    }

    /// Declare the pixel-art skills as goose tools for the chat model.
    fn skill_tools(&self) -> Vec<ProviderTool> {
        use serde_json::json;
        vec![
            tool(
                "generate_art",
                "Generate a piece of pixel art from a text prompt and save it to a PNG file. Returns the saved filename.",
                json!({
                    "type": "object",
                    "properties": {
                        "prompt": { "type": "string", "description": "What to draw" },
                        "style": { "type": "string", "description": "Art style hint (default: pixel art)" }
                    },
                    "required": ["prompt"]
                }),
            ),
            tool(
                "spritesheet",
                "Generate a sprite sheet arranged on a uniform grid and slice it into individual animation frames, each saved as a PNG. Returns the list of saved files.",
                json!({
                    "type": "object",
                    "properties": {
                        "prompt": { "type": "string", "description": "The character / action to draw" },
                        "cols": { "type": "integer", "description": "Columns of frames (default 4)" },
                        "rows": { "type": "integer", "description": "Rows of frames (default 1)" }
                    },
                    "required": ["prompt"]
                }),
            ),
            tool(
                "next_frame",
                "Given a current animation frame (PNG path), generate the next frame and save it as a PNG.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the current frame PNG" },
                        "prompt": { "type": "string", "description": "What happens next (e.g. 'continue walking')" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "compress",
                "Reduce a PNG to a target bit depth (2^bits colors) and save the result.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "bits": { "type": "integer", "description": "Bit depth 1-8 (default 4)" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "remove_background",
                "Strip a near-uniform background from a PNG and save the result.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "tolerance": { "type": "number", "description": "Color tolerance (default 32)" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_image_gen",
                "Generate a single clean game-ready pixel-art asset from a prompt and save it as a PNG.",
                json!({
                    "type": "object",
                    "properties": {
                        "prompt": { "type": "string", "description": "What to draw" },
                        "style": { "type": "string", "description": "Art style hint" },
                        "resolution": { "type": "string", "description": "e.g. 64x64" },
                        "palette": { "type": "string", "description": "Named palette or family" }
                    },
                    "required": ["prompt"]
                }),
            ),
            tool(
                "pixel_reduce_colors",
                "Reduce a PNG to a fixed color count and save the result.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "colors": { "type": "integer", "description": "Color count (default 16)" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_remove_bg",
                "Remove a flat, white or chroma-key background from a PNG and save the result.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "tolerance": { "type": "integer", "description": "Color tolerance (default 32)" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_file_compressor",
                "Quantize and optionally downscale a PNG to shrink its file size.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "colors": { "type": "integer", "description": "Target color count (0 = auto)" },
                        "scale": { "type": "number", "description": "Downscale factor 0.05-1.0" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_9slice_splitter",
                "Split an image into 9-slice panels, a grid, or scattered objects and save each piece.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "mode": { "type": "string", "description": "auto, grid, nineslice or scatter" },
                        "cols": { "type": "integer", "description": "Grid columns" },
                        "rows": { "type": "integer", "description": "Grid rows" },
                        "insets": { "type": "string", "description": "top,right,bottom,left" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_spritesheet_gen",
                "Extract sprites from an irregular spritesheet and save each as a PNG.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "min_area": { "type": "integer", "description": "Minimum sprite area" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_tileset_gen",
                "Slice a tileset image into individual square tiles and save each as a PNG.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "tile": { "type": "integer", "description": "Tile size in pixels" }
                    },
                    "required": ["image", "tile"]
                }),
            ),
            tool(
                "pixel_game_ui_gen",
                "Slice a UI image into components by connected alpha regions and save each.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_ui_elements_gen",
                "Slice UI elements out of an image by connected alpha regions and save each.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_ui_kit_gen",
                "Split a batch UI sheet into component crops by projection bands and save each.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "bg": { "type": "string", "description": "Background hex (default FF00FF)" }
                    },
                    "required": ["image"]
                }),
            ),
            tool(
                "pixel_game_asset_prep",
                "Convert a chroma-green shadow placeholder into a soft drop shadow and save the result.",
                json!({
                    "type": "object",
                    "properties": {
                        "image": { "type": "string", "description": "Path to the input PNG" },
                        "max_alpha": { "type": "integer", "description": "Max shadow alpha (default 150)" }
                    },
                    "required": ["image"]
                }),
            ),
        ]
    }

    /// Execute a skill tool call and save any produced images to disk.
    fn execute_tool(&self, name: &str, args: &str) -> Result<String, String> {
        let params: serde_json::Value =
            serde_json::from_str(args).unwrap_or_else(|_| serde_json::json!({}));

        let prompt = params.get("prompt").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let image_path = params.get("image").and_then(|v| v.as_str()).map(str::to_string);

        let kind = SkillKind::from_id(name).ok_or_else(|| format!("unknown tool {name}"))?;

        let image = match &image_path {
            Some(path) => Some(load_image_file(path)?),
            None => None,
        };

        let input = SkillInput { prompt, image, images: vec![], params };
        let output = Skills::run(Some(self), kind, input).map_err(|e| e.to_string())?;
        self.save_skill_output(kind, output, image_path.as_deref())
    }

    fn save_skill_output(
        &self,
        kind: SkillKind,
        output: SkillOutput,
        source: Option<&str>,
    ) -> Result<String, String> {
        let save = |img: &RgbaImage, path: &str| -> Result<String, String> {
            let png = encode_png(img).map_err(|e| e.to_string())?;
            std::fs::write(path, png).map_err(|e| e.to_string())?;
            Ok(format!("{path} ({}×{})", img.width, img.height))
        };

        match kind {
            SkillKind::Spritesheet => {
                let mut saved = Vec::new();
                if let Some(sheet) = &output.image {
                    let path = format!("sheet_{}.png", counter());
                    saved.push(save(sheet, &path)?);
                }
                for (i, frame) in output.frames.iter().enumerate() {
                    let path = format!("sheet_{}_f{}.png", counter(), i);
                    saved.push(save(frame, &path)?);
                }
                Ok(format!("sliced into {} frames: {}", saved.len(), saved.join(", ")))
            }
            SkillKind::Compress => {
                let img = output.image.ok_or("compress produced no image")?;
                let base = stem(source.unwrap_or("image"));
                let path = format!("{base}_compressed.png");
                save(&img, &path)
            }
            SkillKind::RemoveBackground => {
                let img = output.image.ok_or("remove_background produced no image")?;
                let base = stem(source.unwrap_or("image"));
                let path = format!("{base}_nobg.png");
                save(&img, &path)
            }
            SkillKind::GenerateArt => {
                let img = output.image.ok_or("generate_art produced no image")?;
                let path = format!("art_{}.png", counter());
                save(&img, &path)
            }
            SkillKind::NextFrame => {
                let img = output.image.ok_or("next_frame produced no image")?;
                let path = format!("next_{}.png", counter());
                save(&img, &path)
            }
            other => self.save_generic_output(other, output, source),
        }
    }

    /// Save the image(s) produced by a skill under deterministic names derived
    /// from the skill id, returning a human-readable summary.
    fn save_generic_output(
        &self,
        kind: SkillKind,
        output: SkillOutput,
        source: Option<&str>,
    ) -> Result<String, String> {
        let save = |img: &RgbaImage, path: &str| -> Result<String, String> {
            let png = encode_png(img).map_err(|e| e.to_string())?;
            std::fs::write(path, png).map_err(|e| e.to_string())?;
            Ok(format!("{path} ({}×{})", img.width, img.height))
        };
        let id = kind.to_string();
        let base = stem(source.unwrap_or("image"));

        let mut saved = Vec::new();
        if let Some(img) = &output.image {
            let path = format!("{base}_{id}.png");
            saved.push(save(img, &path)?);
        }
        if output.image.is_none() {
            for (i, frame) in output.frames.iter().enumerate() {
                let path = format!("{base}_{id}_{i}.png");
                saved.push(save(frame, &path)?);
            }
        } else {
            for (i, frame) in output.frames.iter().enumerate() {
                let path = format!("{base}_{id}_f{i}.png");
                saved.push(save(frame, &path)?);
            }
        }

        if saved.is_empty() {
            return Ok(output.text);
        }
        let mut text = output.text.clone();
        if !text.is_empty() {
            text.push_str(": ");
        }
        text.push_str(&saved.join(", "));
        Ok(text)
    }

    // ------------------------------------------------------ images endpoint

    fn image_client(&self) -> reqwest::blocking::Client {
        reqwest::blocking::Client::new()
    }

    fn image_auth(&self) -> String {
        format!("Bearer {}", self.settings.api_key)
    }

    /// Text → image via `POST {base}/images/generations`.
    fn image_generations(&self, prompt: &str) -> Result<RgbaImage, AiError> {
        let base = self.settings.base_url.trim_end_matches('/');
        let url = format!("{base}/images/generations");
        let body = serde_json::json!({
            "model": self.settings.image_model,
            "prompt": prompt,
            "n": 1,
            "response_format": "b64_json",
        });
        let resp = self
            .image_client()
            .post(&url)
            .header("Authorization", self.image_auth())
            .json(&body)
            .send()
            .map_err(|e| AiError::Provider(e.to_string()))?;
        parse_image_response(resp)
    }

    /// Image → image via `POST {base}/images/edits` (multipart).
    fn image_edits(&self, prompt: &str, image: &RgbaImage) -> Result<RgbaImage, AiError> {
        let base = self.settings.base_url.trim_end_matches('/');
        let url = format!("{base}/images/edits");
        let png = encode_png(image)?;
        let part = reqwest::blocking::multipart::Part::bytes(png)
            .file_name("image.png")
            .mime_str("image/png")
            .map_err(|e| AiError::Image(e.to_string()))?;
        let form = reqwest::blocking::multipart::Form::new()
            .text("model", self.settings.image_model.clone())
            .text("prompt", prompt.to_string())
            .text("n", "1")
            .text("response_format", "b64_json")
            .part("image", part);
        let resp = self
            .image_client()
            .post(&url)
            .header("Authorization", self.image_auth())
            .multipart(form)
            .send()
            .map_err(|e| AiError::Provider(e.to_string()))?;
        parse_image_response(resp)
    }
}

/// Parse an OpenAI-compatible images response: `data[0].b64_json` or
/// `data[0].url`, decoded to RGBA.
fn parse_image_response(resp: reqwest::blocking::Response) -> Result<RgbaImage, AiError> {
    let status = resp.status();
    let text = resp.text().map_err(|e| AiError::Provider(e.to_string()))?;
    if !status.is_success() {
        return Err(AiError::Provider(format!("images endpoint {status}: {}", text.trim())));
    }
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| AiError::Provider(format!("bad response: {e}")))?;
    let data = v
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|a| a.first())
        .ok_or_else(|| AiError::NoImage)?;

    if let Some(b64) = data.get("b64_json").and_then(|b| b.as_str()) {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| AiError::Image(format!("bad base64: {e}")))?;
        return decode_model_image(&bytes);
    }
    if let Some(url) = data.get("url").and_then(|u| u.as_str()) {
        let bytes = reqwest::blocking::get(url)
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.bytes())
            .map_err(|e| AiError::Provider(format!("failed to fetch image url: {e}")))?;
        return decode_model_image(&bytes);
    }
    Err(AiError::NoImage)
}

fn concat_text(content: &[MessageContent]) -> String {
    let mut out = String::new();
    for c in content {
        if let MessageContent::Text { text } = c {
            out.push_str(text);
        }
    }
    out
}

fn tool(name: &str, description: &str, schema: serde_json::Value) -> ProviderTool {
    ProviderTool {
        name: name.to_string(),
        description: description.to_string(),
        input_schema_json: schema.to_string(),
        annotations_json: None,
    }
}

fn tool_result(id: String, success: bool, text: String) -> MessageContent {
    MessageContent::ToolResult {
        id,
        success,
        content_json: serde_json::json!({ "type": "text", "text": text }).to_string(),
    }
}

fn counter() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static C: AtomicU32 = AtomicU32::new(1);
    C.fetch_add(1, Ordering::Relaxed)
}

fn stem(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".to_string())
}

fn load_image_file(path: &str) -> Result<RgbaImage, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    crate::image::decode_any(&bytes).map_err(|e| e.to_string())
}

/// Decode arbitrary image bytes (PNG/JPEG/WebP) into RGBA.
fn decode_model_image(bytes: &[u8]) -> Result<RgbaImage, AiError> {
    let img = image::load_from_memory(bytes)
        .map_err(|e| AiError::Image(format!("undecodable image: {e}")))?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Ok(RgbaImage::from_rgba(w as usize, h as usize, rgba.into_raw()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn user(text: &str) -> ProviderMessage {
        ProviderMessage {
            role: MessageRole::User,
            content: vec![MessageContent::Text { text: text.to_string() }],
        }
    }

    #[test]
    fn session_starts_empty_and_accumulates_history() {
        let mut session = Session::new();
        assert!(session.is_empty());

        session.messages.push(user("hello"));
        session.messages.push(ProviderMessage {
            role: MessageRole::Assistant,
            content: vec![MessageContent::Text { text: "hi!".to_string() }],
        });
        assert_eq!(session.len(), 2);
        assert!(!session.is_empty());
    }

    #[test]
    fn session_reset_clears_history_and_tracks_system() {
        let mut session = Session::new();
        session.reset("system A");
        session.messages.push(user("first turn"));

        session.reset("system B");
        assert!(session.is_empty());
        assert_eq!(session.system(), "system B");
    }
}
