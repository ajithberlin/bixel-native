//! AI settings loaded from the environment (`.env`), plus the declarative
//! OpenRouter provider JSON consumed by the goose SDK.

use serde::Serialize;

/// Model routing + credentials for the OpenRouter gateway.
#[derive(Debug, Clone, PartialEq)]
pub struct AiSettings {
    /// `OPENROUTER_API_KEY`.
    pub api_key: String,
    /// Text completion model.
    pub text_model: String,
    /// Vision model (image input → text output).
    pub vision_model: String,
    /// Image generation model (text input → image output).
    pub image_model: String,
    /// OpenRouter base URL (OpenAI-compatible).
    pub base_url: String,
}

impl Default for AiSettings {
    fn default() -> Self {
        AiSettings {
            api_key: String::new(),
            text_model: "meta/muse-spark-1.3".into(),
            vision_model: "deepseek/deepseek-v4-flash-vision-exp".into(),
            image_model: "google/gemini-3-pro-image".into(),
            base_url: "https://openrouter.ai/api/v1".into(),
        }
    }
}

impl AiSettings {
    /// Read settings from the process environment (after `.env` has been loaded).
    ///
    /// `BIXEL_TEXT_MODEL`, `BIXEL_VISION_MODEL` and `BIXEL_IMAGE_MODEL` override
    /// the defaults; `OPENROUTER_API_KEY` is required for model-backed skills.
    pub fn from_env() -> Self {
        let mut s = AiSettings::default();
        if let Ok(v) = std::env::var("OPENROUTER_API_KEY") {
            s.api_key = v.trim().to_string();
        }
        if let Ok(v) = std::env::var("BIXEL_TEXT_MODEL") {
            if !v.trim().is_empty() {
                s.text_model = v.trim().to_string();
            }
        }
        if let Ok(v) = std::env::var("BIXEL_VISION_MODEL") {
            if !v.trim().is_empty() {
                s.vision_model = v.trim().to_string();
            }
        }
        if let Ok(v) = std::env::var("BIXEL_IMAGE_MODEL") {
            if !v.trim().is_empty() {
                s.image_model = v.trim().to_string();
            }
        }
        if let Ok(v) = std::env::var("OPENROUTER_BASE_URL") {
            if !v.trim().is_empty() {
                s.base_url = v.trim().to_string();
            }
        }
        s
    }

    pub fn has_key(&self) -> bool {
        !self.api_key.is_empty()
    }

    /// Load `.env` / `.env.test` from the working directory into the process
    /// environment, then read settings. Convenience for embedding hosts.
    pub fn from_env_file() -> Self {
        bixel_core::config::load_env(None, false);
        Self::from_env()
    }
}

/// A single model entry in the declarative provider JSON.
#[derive(Serialize)]
struct DeclModel<'a> {
    name: &'a str,
    context_limit: u32,
}

/// The declarative-provider JSON for OpenRouter, resolved by the goose SDK.
///
/// OpenRouter is an OpenAI-compatible gateway, so `engine: "openai"` and the
/// `OPENROUTER_API_KEY` env placeholder work out of the box.
pub fn openrouter_provider_json(settings: &AiSettings) -> String {
    let models = [
        DeclModel { name: &settings.text_model, context_limit: 128_000 },
        DeclModel { name: &settings.vision_model, context_limit: 128_000 },
        DeclModel { name: &settings.image_model, context_limit: 128_000 },
    ];
    // De-duplicate by name (a model may serve more than one role).
    let mut seen = std::collections::HashSet::new();
    let models: Vec<_> = models
        .into_iter()
        .filter(|m| seen.insert(m.name.to_string()))
        .collect();

    serde_json::json!({
        "name": "openrouter",
        "engine": "openai",
        "display_name": "OpenRouter",
        "description": "OpenRouter multi-model gateway (text, vision, image)",
        "api_key_env": "OPENROUTER_API_KEY",
        "base_url": settings.base_url,
        "models": models,
        "supports_streaming": true,
        "requires_auth": true,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_json_is_valid_declarative_shape() {
        let settings = AiSettings::default();
        let json = openrouter_provider_json(&settings);
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["engine"], "openai");
        assert_eq!(value["api_key_env"], "OPENROUTER_API_KEY");
        assert_eq!(value["base_url"], "https://openrouter.ai/api/v1");
        let models = value["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["name"] == "meta/muse-spark-1.3"));
    }

    #[test]
    fn from_env_reads_overrides() {
        // Use unique env keys to avoid colliding with a real environment.
        std::env::set_var("BIXEL_TEXT_MODEL", "test/text-model");
        let s = AiSettings::from_env();
        assert_eq!(s.text_model, "test/text-model");
        std::env::remove_var("BIXEL_TEXT_MODEL");
    }
}
