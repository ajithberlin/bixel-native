//! The goose-backed engine: a thin, synchronous facade over the goose SDK's
//! OpenRouter provider for text, vision and image generation.

use std::sync::Arc;

use goose_sdk::bindings::{
    self, MessageContent, MessageRole, ProviderMessage, ProviderModelConfig,
};

use crate::config::{openrouter_provider_json, AiSettings};
use crate::error::AiError;
use crate::image::{decode_png, encode_png, RgbaImage};

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
    pub fn generate_image(&self, prompt: &str, input: Option<&RgbaImage>) -> Result<RgbaImage, AiError> {
        let mut content = Vec::new();
        if let Some(input) = input {
            content.push(Self::image("image/png", encode_png(input)?));
        }
        content.push(Self::text(prompt));
        let messages = vec![Self::user(content)];
        let model = self.settings.image_model.clone();
        let completion = self.runtime.block_on(self.complete(&model, prompt, messages))?;
        extract_image(&completion.content)
    }
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

fn extract_image(content: &[MessageContent]) -> Result<RgbaImage, AiError> {
    for c in content {
        if let MessageContent::Image { data, .. } = c {
            if !data.is_empty() {
                return decode_png(data).map_err(|_| {
                    // Some providers return raw RGBA or JPEG; PNG is the common
                    // case for OpenRouter image models.
                    AiError::Image("model returned image bytes that are not a decodable PNG".into())
                });
            }
        }
    }
    Err(AiError::NoImage)
}
