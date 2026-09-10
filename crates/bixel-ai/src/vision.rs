//! Direct vision calls: image input → text output over the OpenAI-compatible
//! `chat/completions` endpoint (the same pattern as `image_gen.rs`). goose has
//! no vision-role abstraction, so attachment descriptions go through this
//! client using the configured vision model.

use base64::Engine as _;

use crate::error::AiError;
use crate::image::{encode_png, RgbaImage};

/// A synchronous client for vision (image-understanding) requests.
pub struct Vision {
    base_url: String,
    api_key: String,
    model: String,
}

impl Vision {
    pub fn new(base_url: &str, api_key: &str, model: &str) -> Self {
        Vision {
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            model: model.to_string(),
        }
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    /// Ask the vision model to describe an image. `prompt` steers the output
    /// (e.g. "Describe this pixel-art image for the assistant.").
    pub fn describe(&self, prompt: &str, image: &RgbaImage) -> Result<String, AiError> {
        let png = encode_png(image)?;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
        let url = format!("{}/chat/completions", self.base_url);
        let body = serde_json::json!({
            "model": self.model,
            "messages": [{
                "role": "user",
                "content": [
                    { "type": "text", "text": prompt },
                    { "type": "image_url", "image_url": { "url": format!("data:image/png;base64,{b64}") } },
                ],
            }],
            "max_tokens": 512,
        });
        let resp = reqwest::blocking::Client::new()
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&body)
            .send()
            .map_err(|e| AiError::Provider(e.to_string()))?;
        let status = resp.status();
        let text = resp.text().map_err(|e| AiError::Provider(e.to_string()))?;
        if !status.is_success() {
            return Err(AiError::Provider(format!("vision endpoint {status}: {}", text.trim())));
        }
        let v: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| AiError::Provider(format!("bad response: {e}")))?;
        let content = v
            .pointer("/choices/0/message/content")
            .and_then(|c| c.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or(AiError::NoText)?;
        Ok(content.to_string())
    }
}
