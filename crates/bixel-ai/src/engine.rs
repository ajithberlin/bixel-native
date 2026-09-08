//! The goose-backed engine: a thin, synchronous facade over the goose SDK's
//! OpenRouter provider for text, vision and image generation.

use std::sync::Arc;

use base64::Engine as _;
use goose_sdk::bindings::{
    self, MessageContent, MessageRole, ProviderMessage, ProviderModelConfig,
};

use crate::config::{openrouter_provider_json, AiSettings};
use crate::error::AiError;
use crate::image::{encode_png, RgbaImage};

/// A synchronous wrapper around an OpenRouter provider constructed through the
/// goose SDK. Holds its own tokio runtime so the FFI / UI layer can call it
/// without an async context.
pub struct Engine {
    provider: Arc<bindings::Provider>,
    settings: AiSettings,
    runtime: tokio::runtime::Runtime,
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
        Ok(Engine { provider, settings, runtime })
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
    ) -> Result<bindings::ProviderCompletion, AiError> {
        self.provider
            .complete(self.model_config(model), system.to_string(), messages, vec![])
            .await
            .map_err(|e| AiError::Provider(e.to_string()))
    }

    // ---------------------------------------------------------- public API

    /// Text completion with the configured text model.
    pub fn complete_text(&self, prompt: &str, system: &str) -> Result<String, AiError> {
        let messages = vec![Self::user(vec![Self::text(prompt)])];
        let model = self.settings.text_model.clone();
        let completion = self.runtime.block_on(self.complete(&model, system, messages))?;
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
        let completion = self.runtime.block_on(self.complete(&model, prompt, messages))?;
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
        let completion = self.runtime.block_on(self.complete(&model, prompt, messages))?;
        Ok(concat_text(&completion.content))
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

/// Decode arbitrary image bytes (PNG/JPEG/WebP) into RGBA.
fn decode_model_image(bytes: &[u8]) -> Result<RgbaImage, AiError> {
    let img = image::load_from_memory(bytes)
        .map_err(|e| AiError::Image(format!("undecodable image: {e}")))?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Ok(RgbaImage::from_rgba(w as usize, h as usize, rgba.into_raw()))
}
