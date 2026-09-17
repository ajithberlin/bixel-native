//! OpenRouter image generation: text→image and image→image, called over the
//! `/images/*` endpoints (which are not part of `/chat/completions`).

use base64::Engine as _;

use crate::error::AiError;
use crate::image::{decode_any, encode_png, RgbaImage};

/// Provider options that affect the generated image's alpha/background policy.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ImageGenerationOptions {
    /// Ask the provider for real PNG transparency instead of a painted matte.
    pub transparent_background: bool,
}

/// A synchronous text→image / image→image backend (OpenRouter's `/images/*`
/// endpoints or the ChatGPT Codex backend's hosted tool).
pub trait ImageGenerator: Send + Sync {
    fn model(&self) -> &str;

    /// Generate an image (optionally conditioned on an input image for edits).
    fn generate_image(&self, prompt: &str, input: Option<&RgbaImage>)
        -> Result<RgbaImage, AiError>;

    /// Generate an image while passing provider-specific output options.
    ///
    /// The default keeps third-party/test implementations source-compatible;
    /// providers that support alpha should override this method.
    fn generate_image_with_options(
        &self,
        prompt: &str,
        input: Option<&RgbaImage>,
        _options: ImageGenerationOptions,
    ) -> Result<RgbaImage, AiError> {
        self.generate_image(prompt, input)
    }
}

/// A synchronous client for the OpenRouter image endpoints.
pub struct ImageGen {
    base_url: String,
    api_key: String,
    image_model: String,
}

fn image_request_body(
    model: &str,
    prompt: &str,
    options: ImageGenerationOptions,
) -> serde_json::Value {
    let mut body = serde_json::json!({
        "model": model,
        "prompt": prompt,
        "n": 1,
        "response_format": "b64_json",
    });
    if options.transparent_background {
        body["background"] = serde_json::json!("transparent");
        body["output_format"] = serde_json::json!("png");
    }
    body
}

impl ImageGenerator for ImageGen {
    fn model(&self) -> &str {
        &self.image_model
    }

    fn generate_image(
        &self,
        prompt: &str,
        input: Option<&RgbaImage>,
    ) -> Result<RgbaImage, AiError> {
        self.generate_image_with_options(prompt, input, ImageGenerationOptions::default())
    }

    fn generate_image_with_options(
        &self,
        prompt: &str,
        input: Option<&RgbaImage>,
        options: ImageGenerationOptions,
    ) -> Result<RgbaImage, AiError> {
        match input {
            None => self.image_generations(prompt, options),
            Some(img) => self.image_edits(prompt, img, options),
        }
    }
}

impl ImageGen {
    pub fn new(base_url: &str, api_key: &str, image_model: &str) -> Self {
        ImageGen {
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            image_model: image_model.to_string(),
        }
    }

    fn client(&self) -> reqwest::blocking::Client {
        reqwest::blocking::Client::new()
    }

    fn auth(&self) -> String {
        format!("Bearer {}", self.api_key)
    }

    /// Text → image via `POST {base}/images/generations`.
    fn image_generations(
        &self,
        prompt: &str,
        options: ImageGenerationOptions,
    ) -> Result<RgbaImage, AiError> {
        let url = format!("{}/images/generations", self.base_url);
        let body = image_request_body(&self.image_model, prompt, options);
        let resp = self
            .client()
            .post(&url)
            .header("Authorization", self.auth())
            .json(&body)
            .send()
            .map_err(|e| AiError::Provider(e.to_string()))?;
        parse_image_response(resp)
    }

    /// Image → image via `POST {base}/images/edits` (multipart).
    fn image_edits(
        &self,
        prompt: &str,
        image: &RgbaImage,
        options: ImageGenerationOptions,
    ) -> Result<RgbaImage, AiError> {
        let url = format!("{}/images/edits", self.base_url);
        let png = encode_png(image)?;
        let part = reqwest::blocking::multipart::Part::bytes(png)
            .file_name("image.png")
            .mime_str("image/png")
            .map_err(|e| AiError::Image(e.to_string()))?;
        let mut form = reqwest::blocking::multipart::Form::new()
            .text("model", self.image_model.clone())
            .text("prompt", prompt.to_string())
            .text("n", "1")
            .text("response_format", "b64_json")
            .part("image", part);
        if options.transparent_background {
            form = form
                .text("background", "transparent")
                .text("output_format", "png");
        }
        let resp = self
            .client()
            .post(&url)
            .header("Authorization", self.auth())
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
        return Err(AiError::Provider(format!(
            "images endpoint {status}: {}",
            text.trim()
        )));
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
        return decode_any(&bytes);
    }
    if let Some(url) = data.get("url").and_then(|u| u.as_str()) {
        let bytes = reqwest::blocking::get(url)
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.bytes())
            .map_err(|e| AiError::Provider(format!("failed to fetch image url: {e}")))?;
        return decode_any(&bytes);
    }
    Err(AiError::NoImage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transparent_request_asks_provider_for_png_alpha() {
        let body = image_request_body(
            "test-model",
            "a red sprite",
            ImageGenerationOptions {
                transparent_background: true,
            },
        );

        assert_eq!(body["background"], "transparent");
        assert_eq!(body["output_format"], "png");
    }
}
