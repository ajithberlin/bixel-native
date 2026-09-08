//! Provider configuration and API-token storage (port of `core/config.py`).
//!
//! Keys live in `config.json` under the app data home (chmod 600) and are never
//! handed to the frontend — only [`masked_config`] (which replaces `api_key`
//! with a status object) is exposed. Environment variables win over the file so
//! agents and CI can run without writing secrets to disk.

use std::collections::BTreeSet;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::paths::{ensure_state_dirs, state_dir, studio_dir};

pub const CONFIG_VERSION: u32 = 3;

/// Provider ids that ship with the studio and can never be removed.
pub const BUILTIN_IDS: [&str; 4] = ["gemini", "openai", "openrouter", "deepseek"];

/// kind -> environment variables consulted, in order.
pub fn env_keys(kind: &str) -> &'static [&'static str] {
    match kind {
        "openai" => &["OPENAI_API_KEY"],
        "gemini" => &["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        "openrouter" => &["OPENROUTER_API_KEY"],
        "deepseek" => &["DEEPSEEK_API_KEY"],
        _ => &[],
    }
}

/// One configured AI provider.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Provider {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub base_url: String,
    #[serde(default)]
    pub text_models: Vec<String>,
    #[serde(default)]
    pub image_models: Vec<String>,
    #[serde(default)]
    pub default_text: String,
    #[serde(default)]
    pub default_image: String,
    #[serde(default)]
    pub vision_model: String,
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_true() -> bool {
    true
}

impl Provider {
    pub fn supports_image(&self) -> bool {
        !self.image_models.is_empty()
    }
}

macro_rules! provider {
    ($id:expr, $kind:expr, $label:expr, $base_url:expr,
     text=[$($t:expr),*], image=[$($i:expr),*],
     default_text=$dt:expr, default_image=$di:expr, vision=$vis:expr) => {
        Provider {
            id: $id.into(),
            kind: $kind.into(),
            label: $label.into(),
            base_url: $base_url.into(),
            text_models: vec![$($t.into()),*],
            image_models: vec![$($i.into()),*],
            default_text: $dt.into(),
            default_image: $di.into(),
            vision_model: $vis.into(),
            api_key: String::new(),
            enabled: true,
        }
    };
}

/// Seed set. Models are editable in Settings; these are sane defaults.
pub fn default_providers() -> Vec<Provider> {
    vec![
        provider!(
            "gemini", "gemini", "Google Gemini",
            "https://generativelanguage.googleapis.com/v1beta",
            text = [
                "gemini-3-pro", "gemini-3-flash", "gemini-2.5-pro", "gemini-2.5-flash",
                "gemini-2.0-flash", "gemini-2.0-flash-lite"
            ],
            image = [
                "gemini-3.1-flash-lite-image", "gemini-3-pro-image",
                "gemini-2.5-flash-image", "imagen-3.0-generate-002"
            ],
            default_text = "gemini-3-flash",
            default_image = "gemini-3.1-flash-lite-image",
            vision = ""
        ),
        provider!(
            "openai", "openai", "OpenAI", "https://api.openai.com/v1",
            text = [
                "gpt-5.1", "gpt-5.1-mini", "gpt-4.5-preview", "gpt-4o", "gpt-4o-mini",
                "o3-mini", "o1"
            ],
            image = ["gpt-image-1", "dall-e-3", "dall-e-2"],
            default_text = "gpt-5.1-mini",
            default_image = "gpt-image-1",
            vision = "gpt-4o-mini"
        ),
        provider!(
            "openrouter", "openrouter", "OpenRouter", "https://openrouter.ai/api/v1",
            text = [
                "openai/gpt-6-astra", "openai/gpt-6-astra-pro", "openai/gpt-5.6-luna-pro",
                "openai/gpt-5.6-luna", "openai/gpt-5.6-terra-pro", "openai/gpt-5.6-terra",
                "openai/gpt-5.6-sol-pro", "openai/gpt-5.6-sol", "openai/gpt-5.5-pro",
                "openai/gpt-5.5", "openai/gpt-5.4-pro", "openai/gpt-5.4", "openai/gpt-5.4-mini",
                "openai/gpt-5.4-nano", "anthropic/claude-opus-5", "anthropic/claude-opus-4.8",
                "anthropic/claude-opus-4.7", "anthropic/claude-opus-4.6",
                "anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.6",
                "anthropic/claude-fable-5.1", "anthropic/claude-fable-5",
                "google/gemini-3.1-pro-preview", "meta/muse-spark-1.3",
                "meta/muse-spark-1.3-contributor", "meta/muse-spark-1.2",
                "meta/muse-spark-1.2-contributor", "meta/muse-spark-1.1",
                "meta/muse-glimmer-30b", "deepseek/deepseek-v4-pro",
                "deepseek/deepseek-v4-pro-0813", "deepseek/deepseek-v4-flash-vision-exp",
                "x-ai/grok-4.6", "x-ai/grok-4.5", "x-ai/grok-4.20-multi-agent",
                "x-ai/grok-4.20", "x-ai/grok-4.3", "x-ai/grok-build-0.1",
                "qwen/qwen3.8-max-0902", "qwen/qwen3.8-2.4t-a95b", "qwen/qwen3.8-27b",
                "qwen/qwen3.7-max", "qwen/qwen3.7-plus", "qwen/qwen3.6-max-preview",
                "qwen/qwen3.6-plus", "qwen/qwen3.6-27b", "qwen/qwen3.6-35b-a3b",
                "qwen/qwen3-max-thinking", "z-ai/glm-5.3", "z-ai/glm-5.2", "z-ai/glm-5.1",
                "z-ai/glm-5", "z-ai/glm-5v-turbo", "moonshotai/kimi-k3",
                "moonshotai/kimi-k2.6", "moonshotai/kimi-k2.5", "mistralai/mistral-medium-3-5",
                "minimax/minimax-m3", "minimax/minimax-m2.7", "bytedance-seed/seed-2-1-turbo",
                "bytedance-seed/seed-2.0-mini", "nvidia/nemotron-3.5-lightning",
                "nvidia/nemotron-3-ultra-550b-a55b", "nvidia/nemotron-3-super-120b-a12b",
                "google/gemma-4-31b-it", "google/gemma-4-26b-a4b-it", "tencent/hy4-preview",
                "openrouter/fusion", "google/gemini-3.8-flash", "google/gemini-3.7-flash",
                "google/gemini-3.6-flash", "google/gemini-3.5-flash",
                "google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite",
                "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash-0731",
                "qwen/qwen3.8-flash", "qwen/qwen3.7-flash", "qwen/qwen3.6-flash",
                "z-ai/glm-5.3-flash", "z-ai/glm-5-turbo", "mistralai/mistral-small-2603",
                "inclusionai/ling-3.0-flash", "inclusionai/ling-3.0-flash-fin",
                "thinkingmachines/inkling", "thinkingmachines/inkling-small",
                "poolside/laguna-s-2.1", "poolside/laguna-xs-2.1", "stepfun/step-3.7-flash",
                "upstage/solar-pro4", "openrouter/free", "google/gemma-4-26b-a4b-it:free",
                "google/gemma-4-31b-it:free", "nvidia/nemotron-3-ultra-550b-a55b:free",
                "nvidia/nemotron-3-super-120b-a12b:free",
                "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
                "nvidia/nemotron-3.5-lightning:free", "minimax/minimax-m3:free",
                "minimax/minimax-m2.7:free", "thinkingmachines/inkling:free",
                "thinkingmachines/inkling-small:free", "poolside/laguna-s-2.1:free",
                "poolside/laguna-xs-2.1:free", "inclusionai/ling-3.0-flash-fin:free",
                "inclusionai/ling-3.0-flash-sante:free", "inception/mercury-2.5-preview"
            ],
            image = [
                "google/gemini-3-pro-image", "openai/gpt-5.4-image-2",
                "google/gemini-3.1-flash-image", "google/gemini-3.1-flash-lite-image",
                "google/gemini-3.1-flash-image-preview", "meta/muse-image",
                "openrouter/auto-beta"
            ],
            default_text = "meta/muse-spark-1.3",
            default_image = "google/gemini-3-pro-image",
            vision = "deepseek/deepseek-v4-flash-vision-exp"
        ),
        provider!(
            "deepseek", "deepseek", "DeepSeek (text only)", "https://api.deepseek.com/v1",
            text = ["deepseek-chat", "deepseek-reasoner"],
            image = [],
            default_text = "deepseek-chat",
            default_image = "",
            vision = ""
        ),
    ]
}

pub fn config_path() -> String {
    state_dir().join("config.json").to_string_lossy().into_owned()
}

pub fn slugify(label: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in label.to_lowercase().chars() {
        if ch.is_alphanumeric() {
            out.push(ch);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let s = out.trim_matches('-');
    if s.is_empty() {
        "provider".to_string()
    } else {
        s.to_string()
    }
}

pub fn split_models(value: &Value) -> Vec<String> {
    match value {
        Value::String(s) => s
            .split(',')
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect(),
        Value::Array(items) => items
            .iter()
            .map(|v| v.as_str().unwrap_or("").trim().to_string())
            .filter(|x| !x.is_empty())
            .collect(),
        _ => Vec::new(),
    }
}

pub fn default_config() -> Value {
    json!({
        "version": CONFIG_VERSION,
        "providers": default_providers(),
        "active_provider": "gemini",
        "skill_transport": "local",
    })
}

pub fn provider_from_form(raw: &Value) -> Result<Provider, String> {
    let label = raw.get("label").and_then(|v| v.as_str()).unwrap_or("").trim();
    let base_url = raw.get("base_url").and_then(|v| v.as_str()).unwrap_or("").trim().trim_end_matches('/');
    let text_models = split_models(raw.get("text_models").unwrap_or(&Value::Null));
    let image_models = split_models(raw.get("image_models").unwrap_or(&Value::Null));
    if label.is_empty() || base_url.is_empty() {
        return Err("custom provider needs a name and a base URL".into());
    }
    if !base_url.starts_with("http://") && !base_url.starts_with("https://") {
        return Err("base URL must start with http:// or https://".into());
    }
    if text_models.is_empty() {
        return Err("custom provider needs at least one text model".into());
    }
    Ok(Provider {
        id: format!("custom-{}", slugify(label)),
        kind: "custom".into(),
        label: label.into(),
        base_url: base_url.into(),
        default_text: text_models[0].clone(),
        default_image: image_models.first().cloned().unwrap_or_default(),
        vision_model: raw.get("vision_model").and_then(|v| v.as_str()).unwrap_or("").trim().into(),
        text_models,
        image_models,
        api_key: raw.get("api_key").and_then(|v| v.as_str()).unwrap_or("").trim().into(),
        enabled: true,
    })
}

pub fn load_config() -> Value {
    migrate_legacy_state();
    ensure_state_dirs();
    let path = state_dir().join("config.json");
    if !path.exists() {
        let cfg = default_config();
        save_config(&cfg);
        return cfg;
    }
    let Ok(text) = std::fs::read_to_string(&path) else {
        return default_config();
    };
    let Ok(mut cfg) = serde_json::from_str::<Value>(&text) else {
        return default_config();
    };

    // Merge any new seed providers / models into the stored config.
    let mut needs_save = false;
    let mut arr = cfg
        .get("providers")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    for seed in default_providers() {
        if let Some(prov) = arr
            .iter_mut()
            .find(|p| p.get("id").and_then(|v| v.as_str()) == Some(seed.id.as_str()))
        {
            merge_models(prov, "text_models", &seed.text_models, &mut needs_save);
            merge_models(prov, "image_models", &seed.image_models, &mut needs_save);
            if prov.get("default_text").and_then(|v| v.as_str()).unwrap_or("").is_empty()
                && !seed.default_text.is_empty()
            {
                prov["default_text"] = json!(seed.default_text);
                needs_save = true;
            }
            if prov.get("default_image").and_then(|v| v.as_str()).unwrap_or("").is_empty()
                && !seed.default_image.is_empty()
            {
                prov["default_image"] = json!(seed.default_image);
                needs_save = true;
            }
            if prov.get("vision_model").and_then(|v| v.as_str()).unwrap_or("").is_empty()
                && !seed.vision_model.is_empty()
            {
                prov["vision_model"] = json!(seed.vision_model);
                needs_save = true;
            }
        } else {
            let mut val = serde_json::to_value(&seed).unwrap_or(Value::Null);
            if let Some(obj) = val.as_object_mut() {
                obj.remove("api_key");
            }
            arr.push(val);
            needs_save = true;
        }
    }
    cfg["providers"] = json!(arr);

    // Migrations.
    if cfg.get("active_text_provider").is_some() || cfg.get("active_image_provider").is_some() {
        let active = cfg.get("active_text_provider").and_then(|v| v.as_str())
            .or(cfg.get("active_image_provider").and_then(|v| v.as_str()))
            .unwrap_or("gemini");
        cfg["active_provider"] = json!(active);
        cfg.as_object_mut().map(|o| {
            o.remove("active_text_provider");
            o.remove("active_image_provider");
        });
    }
    if (cfg.get("version").and_then(|v| v.as_u64()).unwrap_or(1) as u32) < 3 {
        for seed in default_providers() {
            if let Some(prov) = cfg.get_mut("providers").and_then(|v| v.as_array_mut())
                .map(|arr| arr.iter_mut().find(|p| p.get("id").and_then(|v| v.as_str()) == Some(seed.id.as_str())).unwrap()) {
                prov["text_models"] = json!(seed.text_models);
                prov["image_models"] = json!(seed.image_models);
                prov["default_text"] = json!(seed.default_text);
                prov["default_image"] = json!(seed.default_image);
                prov["vision_model"] = json!(seed.vision_model);
            }
        }
    }
    cfg["active_provider"] = json!(cfg.get("active_provider").and_then(|v| v.as_str()).unwrap_or("gemini"));
    if !matches!(cfg.get("skill_transport").and_then(|v| v.as_str()), Some("local") | Some("docker") | Some("auto")) {
        cfg["skill_transport"] = json!("local");
        needs_save = true;
    }
    if cfg.get("version").and_then(|v| v.as_u64()).unwrap_or(0) as u32 != CONFIG_VERSION || needs_save {
        cfg["version"] = json!(CONFIG_VERSION);
        save_config(&cfg);
    }
    cfg
}

fn merge_models(prov: &mut Value, key: &str, seeds: &[String], needs_save: &mut bool) {
    let existing: BTreeSet<String> = prov
        .get(key)
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str()).map(String::from).collect())
        .unwrap_or_default();
    let mut arr = prov
        .get(key)
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for m in seeds {
        if !existing.contains(m) {
            arr.push(json!(m));
            *needs_save = true;
        }
    }
    prov[key] = json!(arr);
}

pub fn save_config(cfg: &Value) {
    ensure_state_dirs();
    let path = state_dir().join("config.json");
    let mut text = serde_json::to_string_pretty(cfg).unwrap_or_else(|_| "{}".into());
    text.push('\n');
    let _ = std::fs::write(&path, text);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
}

/// Load key-value pairs from an env file (`.env.test` / `.env`) into the
/// process environment. Returns the loaded pairs.
pub fn load_env(path: Option<&Path>, override_existing: bool) -> std::collections::HashMap<String, String> {
    let mut loaded = std::collections::HashMap::new();
    let mut found: Option<std::path::PathBuf> = None;
    if let Some(p) = path {
        if p.is_file() {
            found = Some(p.to_path_buf());
        }
    } else {
        for folder in [std::env::current_dir().ok(), Some(studio_dir())].into_iter().flatten() {
            for name in [".env.test", ".env"] {
                let cand = folder.join(name);
                if cand.is_file() {
                    found = Some(cand);
                    break;
                }
            }
            if found.is_some() {
                break;
            }
        }
    }
    let Some(found) = found else { return loaded; };
    let Ok(content) = std::fs::read_to_string(found) else { return loaded; };

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') || !line.contains('=') {
            continue;
        }
        let (key, val) = line.split_once('=').unwrap();
        let key = key.trim();
        let mut val = val.trim();
        if (val.starts_with('"') && val.ends_with('"')) || (val.starts_with('\'') && val.ends_with('\'')) {
            val = &val[1..val.len() - 1];
        }
        let mut val = val.to_string();
        if key == "OPENROUTER_TEST_TEXT_MODEL" && val == "nvidia/nem-3.5-lightning:free" {
            val = "nvidia/nemotron-3.5-lightning:free".into();
        }
        if override_existing || std::env::var(key).is_err() {
            std::env::set_var(key, &val);
        }
        loaded.insert(key.to_string(), val);
    }
    loaded
}

pub fn get_provider(cfg: &Value, provider_id: &str) -> Option<Provider> {
    let raw = cfg.get("providers")?.as_array()?.iter().find(|p| {
        p.get("id").and_then(|v| v.as_str()) == Some(provider_id)
    })?;
    let mut provider: Provider = serde_json::from_value(raw.clone()).ok()?;
    if provider.id == "openrouter" {
        if let Ok(t) = std::env::var("OPENROUTER_TEST_TEXT_MODEL") {
            let t = t.trim();
            if !t.is_empty() && !provider.text_models.contains(&t.to_string()) {
                provider.text_models.push(t.to_string());
            }
        }
        if let Ok(i) = std::env::var("OPENROUTER_TEST_IMAGE_MODEL") {
            let i = i.trim();
            if !i.is_empty() && !provider.image_models.contains(&i.to_string()) {
                provider.image_models.push(i.to_string());
            }
        }
    }
    Some(provider)
}

/// Environment first, then the stored key.
pub fn resolve_key(provider: &Provider) -> String {
    for env_name in env_keys(&provider.kind) {
        if let Ok(v) = std::env::var(env_name) {
            let v = v.trim();
            if !v.is_empty() {
                return v.to_string();
            }
        }
    }
    provider.api_key.trim().to_string()
}

/// What the frontend is allowed to know about a key.
pub fn key_status(provider: &Provider) -> Value {
    for env_name in env_keys(&provider.kind) {
        if let Ok(v) = std::env::var(env_name) {
            if !v.trim().is_empty() {
                return json!({ "set": true, "source": "env", "env": env_name, "hint": "" });
            }
        }
    }
    let stored = provider.api_key.trim();
    if !stored.is_empty() {
        let hint = if stored.len() > 4 {
            format!("…{}", &stored[stored.len() - 4..])
        } else {
            "…".to_string()
        };
        return json!({ "set": true, "source": "file", "env": "", "hint": hint });
    }
    json!({ "set": false, "source": "", "env": "", "hint": "" })
}

/// Config safe to hand to the frontend: `api_key` replaced by key status.
pub fn masked_config(cfg: &Value) -> Value {
    let env_mode = std::env::var("BIXEL_SKILL_TRANSPORT")
        .map(|v| v.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let env_override = matches!(env_mode.as_str(), "local" | "docker" | "auto");
    let mut mode = cfg.get("skill_transport").and_then(|v| v.as_str()).unwrap_or("local").to_string();
    if !matches!(mode.as_str(), "local" | "docker" | "auto") {
        mode = "local".into();
    }

    let mut providers_out = Vec::new();
    if let Some(arr) = cfg.get("providers").and_then(|v| v.as_array()) {
        for raw in arr {
            if let Ok(provider) = serde_json::from_value::<Provider>(raw.clone()) {
                let mut entry = serde_json::to_value(&provider).unwrap_or(Value::Null);
                if let Some(obj) = entry.as_object_mut() {
                    obj.remove("api_key");
                    obj.insert("key".into(), key_status(&provider));
                    obj.insert("supports_image".into(), json!(provider.supports_image()));
                    obj.insert("builtin".into(), json!(BUILTIN_IDS.contains(&provider.id.as_str())));
                }
                providers_out.push(entry);
            }
        }
    }

    json!({
        "version": cfg.get("version").and_then(|v| v.as_u64()).unwrap_or(CONFIG_VERSION as u64),
        "active_provider": cfg.get("active_provider").and_then(|v| v.as_str()).unwrap_or(""),
        "skill_transport": if env_override { env_mode } else { mode },
        "skill_transport_env": env_override,
        "providers": providers_out,
    })
}

fn migrate_legacy_state() {
    let legacy = studio_dir().join(".studio");
    if !legacy.is_dir() {
        return;
    }
    let home = state_dir();
    let _ = ensure_state_dirs();
    if !home.join("config.json").exists() && legacy.join("config.json").exists() {
        let _ = std::fs::copy(legacy.join("config.json"), home.join("config.json"));
    }
    if !home.join("prompts").exists() && legacy.join("prompts").is_dir() {
        let _ = copy_dir_all(legacy.join("prompts"), home.join("prompts"));
    }
}

fn copy_dir_all(src: std::path::PathBuf, dst: std::path::PathBuf) -> std::io::Result<()> {
    std::fs::create_dir_all(&dst)?;
    for entry in std::fs::read_dir(&src)? {
        let entry = entry?;
        let target = dst.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir_all(entry.path(), target)?;
        } else {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}
