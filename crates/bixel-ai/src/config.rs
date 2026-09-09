//! AI settings loaded from the environment (`.env`), plus the env wiring that
//! points the embedded goose agent at the OpenRouter provider.

use std::path::Path;

/// Model routing + credentials for the OpenRouter gateway.
#[derive(Debug, Clone, PartialEq)]
pub struct AiSettings {
    /// `OPENROUTER_API_KEY`.
    pub api_key: String,
    /// Text completion model (also the goose agent's model).
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

    /// The OpenRouter host (origin only, no `/api/v1` path) consumed by goose's
    /// `openrouter` provider.
    pub fn openrouter_host(&self) -> String {
        let base = self.base_url.trim_end_matches('/');
        match base.strip_suffix("/api/v1") {
            Some(host) => host.to_string(),
            None => base.to_string(),
        }
    }

    /// Apply goose's configuration through the process environment.
    ///
    /// goose's `Config` resolves values from the environment (uppercased keys),
    /// so this is how the embedded agent is pointed at OpenRouter. `data_dir`
    /// (via `GOOSE_PATH_ROOT`) isolates goose's config/state/session SQLite so
    /// the host owns the location and no user `~/.config/goose` is touched.
    pub fn apply_goose_env(&self, data_dir: &Path) {
        std::env::set_var("GOOSE_PATH_ROOT", data_dir);
        std::env::set_var("GOOSE_DISABLE_KEYRING", "1");
        std::env::set_var("GOOSE_PROVIDER", "openrouter");
        std::env::set_var("GOOSE_MODEL", &self.text_model);
        std::env::set_var("OPENROUTER_API_KEY", &self.api_key);
        std::env::set_var("OPENROUTER_HOST", self.openrouter_host());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn openrouter_host_strips_api_v1() {
        let s = AiSettings::default();
        assert_eq!(s.openrouter_host(), "https://openrouter.ai");
    }

    #[test]
    fn openrouter_host_handles_custom_base() {
        let s = AiSettings {
            base_url: "https://proxy.example.com/api/v1".into(),
            ..AiSettings::default()
        };
        assert_eq!(s.openrouter_host(), "https://proxy.example.com");
    }
}
