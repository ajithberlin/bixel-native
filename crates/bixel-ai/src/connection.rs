//! Provider connection management: user-owned credentials (entered via the UI,
//! write-only across FFI), one cached `Arc<dyn Provider>` shared across all
//! sessions, and the three-model readiness gate that keeps model-backed
//! skills from dead-ending on a missing role.
//!
//! Credentials are stored in goose's secret store (Keychain on macOS, file
//! fallback) under an app-owned `GOOSE_PATH_ROOT`; `.env` remains the
//! lowest-precedence dev fallback via [`ConnectionConfig::from_env`].

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use goose::config::Config;
use goose::providers;
use goose_providers::base::Provider;
use serde::{Deserialize, Serialize};

use crate::config::AiSettings;
use crate::error::AiError;
use crate::image_gen::ImageGen;
use crate::vision::Vision;

pub const OPENROUTER_PROVIDER: &str = "openrouter";
pub const CHATGPT_CODEX_PROVIDER: &str = "chatgpt_codex";

/// Which goose provider backs the chat (text + vision) roles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderChoice {
    /// OpenRouter gateway with an API key.
    OpenRouter,
    /// ChatGPT (Codex) OAuth — the user's ChatGPT credentials, no API key.
    ChatgptCodex,
}

impl ProviderChoice {
    pub fn goose_name(self) -> &'static str {
        match self {
            ProviderChoice::OpenRouter => OPENROUTER_PROVIDER,
            ProviderChoice::ChatgptCodex => CHATGPT_CODEX_PROVIDER,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            ProviderChoice::OpenRouter => "OpenRouter",
            ProviderChoice::ChatgptCodex => "ChatGPT (Codex)",
        }
    }
}

impl Default for ProviderChoice {
    fn default() -> Self {
        ProviderChoice::OpenRouter
    }
}

/// The three model roles every model-backed feature needs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelRoles {
    pub text: String,
    pub vision: String,
    pub image: String,
}

impl Default for ModelRoles {
    fn default() -> Self {
        let s = AiSettings::default();
        ModelRoles { text: s.text_model, vision: s.vision_model, image: s.image_model }
    }
}

/// A full provider connection: provider choice, credentials, and model roles.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ConnectionConfig {
    #[serde(default)]
    pub provider: ProviderChoice,
    /// Provider credential: the OpenRouter API key, or None for Codex OAuth.
    /// Write-only: never serialized back out (see `masked_key`).
    #[serde(default)]
    pub api_key: Option<String>,
    /// Secondary OpenRouter key used for the image role when the chat
    /// provider is Codex (goose has no image-generation API). Write-only.
    #[serde(default)]
    pub image_api_key: Option<String>,
    #[serde(default)]
    pub models: ModelRoles,
    #[serde(default = "default_base_url")]
    pub base_url: String,
    /// Probe the provider over the network during connect. The UI sets this;
    /// tests keep it false to stay offline.
    #[serde(default = "default_true")]
    pub validate: bool,
}

fn default_base_url() -> String {
    AiSettings::default().base_url
}

fn default_true() -> bool {
    true
}

impl ConnectionConfig {
    /// Lowest-precedence dev fallback: `.env` / process env.
    pub fn from_env() -> Self {
        let s = AiSettings::from_env();
        ConnectionConfig {
            provider: ProviderChoice::OpenRouter,
            api_key: (!s.api_key.is_empty()).then_some(s.api_key),
            image_api_key: None,
            models: ModelRoles {
                text: s.text_model,
                vision: s.vision_model,
                image: s.image_model,
            },
            base_url: s.base_url,
            validate: true,
        }
    }

    /// The OpenRouter key that serves the image role for this config.
    pub fn image_api_key(&self) -> Option<&str> {
        match self.provider {
            ProviderChoice::OpenRouter => self.api_key.as_deref(),
            ProviderChoice::ChatgptCodex => self.image_api_key.as_deref(),
        }
        .map(str::trim)
        .filter(|k| !k.is_empty())
    }

    /// Masked credential label (`…last4`) for status display — never the key.
    pub fn masked_key(&self) -> Option<String> {
        let key = match self.provider {
            ProviderChoice::OpenRouter => self.api_key.as_deref(),
            ProviderChoice::ChatgptCodex => None,
        }?;
        let key = key.trim();
        if key.is_empty() {
            return None;
        }
        Some(format!("…{}", &key[key.len().saturating_sub(4)..]))
    }
}

/// Readiness of one model role.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RoleReadiness {
    pub model: String,
    pub ready: bool,
    pub reason: String,
}

impl RoleReadiness {
    fn ready(model: &str) -> Self {
        RoleReadiness { model: model.to_string(), ready: true, reason: String::new() }
    }

    fn blocked(model: &str, reason: impl Into<String>) -> Self {
        RoleReadiness { model: model.to_string(), ready: false, reason: reason.into() }
    }
}

/// The three-model readiness gate computed at connect time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelReadiness {
    pub text: RoleReadiness,
    pub vision: RoleReadiness,
    pub image: RoleReadiness,
}

impl ModelReadiness {
    /// Pure readiness computation (no network). `vision_capable` comes from
    /// the local canonical model catalog (input modalities); `text_probe` is
    /// the optional network validation result from connect;
    /// `image_backend_ready` means the provider can serve the image role
    /// (OpenRouter key present, or cached ChatGPT tokens for Codex).
    pub fn compute(
        cfg: &ConnectionConfig,
        vision_capable: Option<bool>,
        text_probe: Result<(), String>,
        image_backend_ready: bool,
    ) -> Self {
        let text = if cfg.models.text.trim().is_empty() {
            RoleReadiness::blocked("", "text model is not configured")
        } else {
            match text_probe {
                Ok(()) => RoleReadiness::ready(&cfg.models.text),
                Err(reason) => RoleReadiness::blocked(&cfg.models.text, reason),
            }
        };

        let vision = if cfg.models.vision.trim().is_empty() {
            RoleReadiness::blocked("", "vision model is not configured")
        } else {
            match vision_capable {
                Some(false) => {
                    RoleReadiness::blocked(&cfg.models.vision, "model does not accept image input")
                }
                _ => RoleReadiness::ready(&cfg.models.vision),
            }
        };

        let image = match cfg.provider {
            ProviderChoice::ChatgptCodex => {
                // The hosted image_generation tool rides the chat model.
                if image_backend_ready {
                    RoleReadiness::ready(&cfg.models.text)
                } else {
                    RoleReadiness::blocked(
                        "",
                        "image generation requires signing in with ChatGPT",
                    )
                }
            }
            ProviderChoice::OpenRouter => {
                if cfg.models.image.trim().is_empty() {
                    RoleReadiness::blocked("", "image model is not configured")
                } else if !image_backend_ready {
                    RoleReadiness::blocked(
                        &cfg.models.image,
                        "image generation requires an OpenRouter API key",
                    )
                } else {
                    RoleReadiness::ready(&cfg.models.image)
                }
            }
        };

        ModelReadiness { text, vision, image }
    }

    pub fn all_ready(&self) -> bool {
        self.text.ready && self.vision.ready && self.image.ready
    }
}

/// A connected provider: the cached goose provider plus the model-role
/// clients built from the same credential set.
pub struct ProviderHandle {
    pub config: ConnectionConfig,
    pub provider: Arc<dyn Provider>,
    pub image_gen: Option<Arc<dyn crate::image_gen::ImageGenerator>>,
    pub vision: Option<Arc<Vision>>,
    pub readiness: ModelReadiness,
}

impl ProviderHandle {
    /// The chat (text) model config goose sessions are switched to.
    pub fn text_model_config(&self) -> goose_providers::model::ModelConfig {
        let mut config =
            goose_providers::model::ModelConfig::new(self.config.models.text.clone());
        config.supports_vision = Some(self.readiness.vision.ready);
        config
    }

    /// Describe image attachments with the vision role, returning text to add
    /// to the user message. None when the vision role is not ready (callers
    /// fall back to attaching the raw images to the chat model).
    pub fn describe_attachments(&self, images: &[crate::native_stream::NativeAttachment]) -> Option<String> {
        use base64::Engine as _;
        let vision = self.vision.as_ref()?;
        let mut out = String::new();
        for (i, attachment) in images.iter().enumerate() {
            let name = if attachment.name.trim().is_empty() {
                format!("attachment {}", i + 1)
            } else {
                attachment.name.clone()
            };
            let bytes = base64::engine::general_purpose::STANDARD.decode(&attachment.data).ok()?;
            let image = crate::image::decode_any(&bytes).ok()?;
            let description = vision
                .describe(
                    "Describe this image concisely for a pixel-art game-asset assistant: \
                     subject, style, palette, dimensions, notable details.",
                    &image,
                )
                .ok()?;
            out.push_str(&format!("\n\nImage {name} (described by the vision model): {description}"));
        }
        if out.is_empty() { None } else { Some(out) }
    }
}

/// Where goose keeps its config/sessions/OAuth tokens. Must be set before the
/// first `Config::global()` call (it is a `OnceCell`).
pub fn ensure_goose_env() -> Result<PathBuf, AiError> {
    if std::env::var_os("GOOSE_PATH_ROOT").is_none() {
        std::env::set_var("GOOSE_PATH_ROOT", default_goose_root());
    }
    let root = PathBuf::from(
        std::env::var("GOOSE_PATH_ROOT").map_err(|e| AiError::Config(e.to_string()))?,
    );
    std::fs::create_dir_all(&root).map_err(|e| AiError::Provider(e.to_string()))?;
    Ok(root)
}

#[cfg(target_os = "macos")]
fn default_goose_root() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    home.join("Library/Application Support/Bixel/goose")
}

#[cfg(not(target_os = "macos"))]
fn default_goose_root() -> PathBuf {
    std::env::temp_dir().join("bixel-goose")
}

fn codex_tokens_exist(root: &std::path::Path) -> bool {
    root.join("config/chatgpt_codex/tokens.json").is_file()
}

/// Look up a model's image-input support in goose's local canonical catalog
/// (no network). None when the model is not catalogued.
fn vision_capability(provider: &str, model: &str) -> Option<bool> {
    use goose::providers::canonical::{maybe_get_canonical_model, Modality};
    let canonical = maybe_get_canonical_model(provider, model)?;
    Some(canonical.modalities.input.contains(&Modality::Image))
}

/// Lightweight network validation for the OpenRouter text role: the key must
/// be accepted and the model listed by `GET {base}/models`.
fn probe_openrouter(cfg: &ConnectionConfig) -> Result<(), String> {
    let key = cfg.api_key.as_deref().unwrap_or("").trim();
    let url = format!("{}/models", cfg.base_url.trim_end_matches('/'));
    let text = reqwest::blocking::Client::new()
        .get(&url)
        .header("Authorization", format!("Bearer {key}"))
        .send()
        .map_err(|e| format!("provider unreachable: {e}"))?
        .text()
        .map_err(|e| format!("provider unreachable: {e}"))?;
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("unexpected /models response: {e}"))?;
    let listed = v
        .get("data")
        .and_then(|d| d.as_array())
        .map(|models| {
            models.iter().any(|m| {
                m.get("id").and_then(|id| id.as_str()) == Some(cfg.models.text.trim())
            })
        })
        .unwrap_or(false);
    if listed {
        Ok(())
    } else {
        Err(format!("model `{}` is not listed by the provider", cfg.models.text))
    }
}

/// Build (and cache, via the returned handle) a provider for this credential
/// set: one goose provider instance serves any model; the model lives in the
/// `ModelConfig` handed to each session.
pub fn connect(
    runtime: &tokio::runtime::Runtime,
    mut cfg: ConnectionConfig,
) -> Result<Arc<ProviderHandle>, AiError> {
    let root = ensure_goose_env()?;

    let config = Config::global();
    match cfg.provider {
        ProviderChoice::OpenRouter => {
            // A missing key reuses the stored secret, so reconnecting does not
            // require retyping the key (it is never returned over FFI).
            let key = match cfg.api_key.as_deref().map(str::trim).filter(|k| !k.is_empty()) {
                Some(key) => {
                    config
                        .set_secret("OPENROUTER_API_KEY", &key.to_string())
                        .map_err(|e| AiError::Config(e.to_string()))?;
                    key.to_string()
                }
                None => config
                    .get_secret::<String>("OPENROUTER_API_KEY")
                    .map_err(|_| AiError::Config("an OpenRouter API key is required".into()))?,
            };
            cfg.api_key = Some(key);
            let host = AiSettings { base_url: cfg.base_url.clone(), ..Default::default() }
                .openrouter_host();
            if host != "https://openrouter.ai" {
                config.set_param("OPENROUTER_HOST", &host).map_err(|e| AiError::Config(e.to_string()))?;
            }
        }
        ProviderChoice::ChatgptCodex => {}
    }

    let provider = runtime
        .block_on(providers::create(cfg.provider.goose_name(), vec![]))
        .map_err(|e| AiError::Provider(e.to_string()))?;

    // Codex signs in through the browser (OAuth PKCE, localhost:1455
    // callback); run the flow only when no cached tokens exist yet.
    if cfg.provider == ProviderChoice::ChatgptCodex && !codex_tokens_exist(&root) {
        runtime
            .block_on(provider.configure_oauth())
            .map_err(|e| AiError::Provider(format!("ChatGPT sign-in failed: {e}")))?;
    }

    let text_probe = if cfg.validate {
        match cfg.provider {
            ProviderChoice::OpenRouter => probe_openrouter(&cfg),
            // Codex tokens are validated lazily at first request.
            ProviderChoice::ChatgptCodex => Ok(()),
        }
    } else {
        Ok(())
    };
    let vision_capable = if cfg.models.vision.trim().is_empty() {
        None
    } else {
        vision_capability(cfg.provider.goose_name(), cfg.models.vision.trim())
    };
    let image_backend_ready = match cfg.provider {
        ProviderChoice::OpenRouter => cfg.image_api_key().is_some(),
        // The hosted image tool rides the cached ChatGPT tokens.
        ProviderChoice::ChatgptCodex => codex_tokens_exist(&root),
    };
    let readiness = ModelReadiness::compute(&cfg, vision_capable, text_probe, image_backend_ready);

    let image_gen: Option<Arc<dyn crate::image_gen::ImageGenerator>> = if readiness.image.ready {
        match cfg.provider {
            ProviderChoice::OpenRouter => Some(Arc::new(ImageGen::new(
                &cfg.base_url,
                cfg.image_api_key().unwrap_or_default(),
                &cfg.models.image,
            ))),
            ProviderChoice::ChatgptCodex => {
                Some(Arc::new(crate::codex_image::CodexImageGen::new(&cfg.models.text)?))
            }
        }
    } else {
        None
    };
    let vision = (readiness.vision.ready && cfg.image_api_key().is_some()).then(|| {
        Arc::new(Vision::new(
            &cfg.base_url,
            cfg.image_api_key().unwrap_or_default(),
            &cfg.models.vision,
        ))
    });

    Ok(Arc::new(ProviderHandle {
        config: cfg,
        provider,
        image_gen,
        vision,
        readiness,
    }))
}

/// Remove stored credentials and cached OAuth tokens. The caller drops the
/// cached provider handle.
pub fn disconnect(runtime: &tokio::runtime::Runtime, provider: ProviderChoice) -> Result<(), AiError> {
    let _root = ensure_goose_env()?;
    let config = Config::global();
    config
        .delete_secret("OPENROUTER_API_KEY")
        .map_err(|e| AiError::Config(e.to_string()))?;
    if provider == ProviderChoice::ChatgptCodex {
        let _ = runtime.block_on(providers::cleanup_provider(CHATGPT_CODEX_PROVIDER));
    }
    Ok(())
}

/// Run the ChatGPT (Codex) browser sign-in ahead of `connect`, so the UI can
/// offer a dedicated "Sign in with ChatGPT" action. Tokens are cached under
/// `GOOSE_PATH_ROOT`, so a later `connect` reuses them.
///
/// The flow is spawned (not called inline) so [`cancel_codex_oauth`] can abort
/// it: goose holds a process-wide mutex for the whole flow, including its
/// 300 s browser-callback wait — aborting the task is the only way to release
/// that mutex early and let the user retry immediately.
pub fn start_codex_oauth(runtime: &tokio::runtime::Runtime) -> Result<(), AiError> {
    ensure_goose_env()?;
    cancel_codex_oauth();
    let provider = runtime
        .block_on(providers::create(CHATGPT_CODEX_PROVIDER, vec![]))
        .map_err(|e| AiError::Provider(e.to_string()))?;
    let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();
    let task = runtime.spawn(async move {
        let result = provider.configure_oauth().await.map_err(|e| e.to_string());
        let _ = tx.send(result);
    });
    *OAUTH_TASK.lock().unwrap() = Some(task);
    let result = rx
        .recv()
        .map_err(|_| AiError::Provider("ChatGPT sign-in was cancelled".into()))?;
    *OAUTH_TASK.lock().unwrap() = None;
    result.map_err(|e| AiError::Provider(format!("ChatGPT sign-in failed: {e}")))
}

/// Abort an in-flight [`start_codex_oauth`] flow (releases goose's OAuth
/// mutex so the next attempt can start immediately).
pub fn cancel_codex_oauth() {
    if let Some(handle) = OAUTH_TASK.lock().unwrap().take() {
        handle.abort();
    }
}

static OAUTH_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);

/// Model ids selectable in the UI: the provider's known models (Codex) or the
/// OpenRouter catalog (requires a stored OpenRouter key), plus the provider's
/// default model when it declares one. No network for Codex; one `/models`
/// call for OpenRouter.
pub fn list_models(provider: ProviderChoice) -> Result<(Vec<String>, Option<String>), AiError> {
    ensure_goose_env()?;
    match provider {
        ProviderChoice::ChatgptCodex => {
            let runtime = tokio::runtime::Runtime::new()
                .map_err(|e| AiError::Provider(format!("failed to start runtime: {e}")))?;
            let entry = runtime
                .block_on(providers::get_from_registry(CHATGPT_CODEX_PROVIDER))
                .map_err(|e| AiError::Provider(e.to_string()))?;
            let default = entry.metadata().default_model.clone();
            let mut names: Vec<String> = entry
                .metadata()
                .known_models
                .iter()
                .map(|m| m.name.clone())
                .collect();
            names.sort();
            Ok((names, Some(default).filter(|d| !d.is_empty())))
        }
        ProviderChoice::OpenRouter => {
            let key: String = Config::global()
                .get_secret("OPENROUTER_API_KEY")
                .map_err(|_| AiError::Config("connect an OpenRouter API key first".into()))?;
            let url = format!("{}/models", default_base_url().trim_end_matches('/'));
            let text = reqwest::blocking::Client::new()
                .get(&url)
                .header("Authorization", format!("Bearer {key}"))
                .send()
                .map_err(|e| AiError::Provider(e.to_string()))?
                .text()
                .map_err(|e| AiError::Provider(e.to_string()))?;
            let v: serde_json::Value = serde_json::from_str(&text)
                .map_err(|e| AiError::Provider(format!("unexpected /models response: {e}")))?;
            let mut ids: Vec<String> = v
                .get("data")
                .and_then(|d| d.as_array())
                .map(|models| {
                    models
                        .iter()
                        .filter_map(|m| m.get("id").and_then(|id| id.as_str()).map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            ids.sort();
            Ok((ids, None))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(provider: ProviderChoice, key: Option<&str>, image_key: Option<&str>) -> ConnectionConfig {
        ConnectionConfig {
            provider,
            api_key: key.map(String::from),
            image_api_key: image_key.map(String::from),
            ..Default::default()
        }
    }

    #[test]
    fn masked_key_shows_last4_only() {
        let c = cfg(ProviderChoice::OpenRouter, Some("sk-or-abcdef1234"), None);
        assert_eq!(c.masked_key().as_deref(), Some("…1234"));
    }

    #[test]
    fn codex_has_no_key_mask() {
        let c = cfg(ProviderChoice::ChatgptCodex, None, Some("sk-or-xyz9"));
        assert_eq!(c.masked_key(), None);
        assert_eq!(c.image_api_key(), Some("sk-or-xyz9"));
    }

    #[test]
    fn openrouter_uses_primary_key_for_image_role() {
        let c = cfg(ProviderChoice::OpenRouter, Some("sk-primary"), None);
        assert_eq!(c.image_api_key(), Some("sk-primary"));
    }

    #[test]
    fn readiness_blocks_missing_roles() {
        let mut c = cfg(ProviderChoice::OpenRouter, None, None);
        c.models.text.clear();
        c.models.vision.clear();
        c.models.image.clear();
        let r = ModelReadiness::compute(&c, None, Ok(()), false);
        assert!(!r.text.ready && !r.vision.ready && !r.image.ready);
        assert!(r.image.reason.contains("not configured"));
    }

    #[test]
    fn readiness_blocks_non_vision_model() {
        let c = cfg(ProviderChoice::OpenRouter, Some("sk-key"), None);
        let r = ModelReadiness::compute(&c, Some(false), Ok(()), true);
        assert!(r.text.ready);
        assert!(!r.vision.ready);
        assert!(r.image.ready);
    }

    #[test]
    fn readiness_reports_failed_text_probe() {
        let c = cfg(ProviderChoice::OpenRouter, Some("sk-key"), None);
        let r = ModelReadiness::compute(&c, Some(true), Err("provider unreachable".into()), true);
        assert!(!r.text.ready);
        assert_eq!(r.text.reason, "provider unreachable");
        assert!(r.vision.ready && r.image.ready);
    }

    #[test]
    fn codex_without_tokens_blocks_image_role_only() {
        let c = cfg(ProviderChoice::ChatgptCodex, None, None);
        let r = ModelReadiness::compute(&c, Some(true), Ok(()), false);
        assert!(r.text.ready && r.vision.ready);
        assert!(!r.image.ready);
        assert!(r.image.reason.contains("signing in with ChatGPT"));
    }

    #[test]
    fn codex_with_tokens_serves_image_role_from_chat_model() {
        let c = cfg(ProviderChoice::ChatgptCodex, None, None);
        let r = ModelReadiness::compute(&c, Some(true), Ok(()), true);
        assert!(r.text.ready && r.vision.ready && r.image.ready);
        assert_eq!(r.image.model, c.models.text);
    }
}
