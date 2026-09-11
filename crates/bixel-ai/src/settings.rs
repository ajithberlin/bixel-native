//! App-universal settings backing the macOS-style Settings window.
//!
//! Everything here configures goose itself and is persisted in goose's config
//! store under the app-owned `GOOSE_PATH_ROOT`, so the app, the goose CLI and
//! the agent all read the same state:
//!
//! * **MCP servers** — goose extensions (`stdio` / `streamable_http`) saved as
//!   `extensions:` entries. Credential *values* never leave the config; the UI
//!   only sees environment variable *keys*.
//! * **Skills** — the installed `SKILL.md` packages goose discovers. Skills have
//!   no native enabled flag, so the app keeps a disabled-name allowlist in the
//!   config (`BIXEL_DISABLED_SKILLS`) and filters the catalog the agent sees.
//! * **App paths** — the goose root, config, skills and venv locations shown in
//!   the About pane.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};

use goose::agents::extension::Envs;
use goose::agents::ExtensionConfig;
use goose::config::extensions::{
    get_all_extensions, name_to_key, remove_extension, set_extension, set_extension_enabled,
    ExtensionEntry,
};
use goose::config::Config;
use serde::{Deserialize, Serialize};

/// goose config param holding the app-level disabled-skill names.
const DISABLED_SKILLS_KEY: &str = "BIXEL_DISABLED_SKILLS";

/// One configured MCP extension. Credentials are never exposed — only the
/// names of environment variables the server needs.
#[derive(Debug, Clone, Serialize)]
pub struct McpExtension {
    pub key: String,
    pub name: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub enabled: bool,
    pub description: String,
    pub display_name: Option<String>,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub uri: Option<String>,
    pub timeout: Option<u64>,
    pub env_keys: Vec<String>,
    pub bundled: bool,
}

/// An installed skill (bundled, user, or project scoped) plus its app-level
/// enablement.
#[derive(Debug, Clone, Serialize)]
pub struct InstalledSkill {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source: String,
    pub path: String,
    pub global: bool,
    pub enabled: bool,
}

/// Payload for creating or updating an MCP extension from the Settings UI.
#[derive(Debug, Clone, Deserialize)]
pub struct McpSpec {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(rename = "type", default = "default_stdio")]
    pub kind: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub env_keys: Vec<String>,
    #[serde(default)]
    pub timeout: Option<u64>,
    #[serde(default)]
    pub uri: String,
    #[serde(default)]
    pub headers: HashMap<String, String>,
}

fn default_stdio() -> String {
    "stdio".to_string()
}

fn default_true() -> bool {
    true
}

/// Locations shown in the About pane.
#[derive(Debug, Clone, Serialize)]
pub struct AppPaths {
    pub goose_root: String,
    pub goose_config: String,
    pub secrets: String,
    pub skills_dir: String,
    pub venv_dir: String,
}

// --------------------------------------------------------------- MCP servers

fn env_keys_of(envs: &Envs, declared: &[String]) -> Vec<String> {
    let mut keys: BTreeSet<String> = declared.iter().cloned().collect();
    keys.extend(envs.get_env().keys().cloned());
    keys.into_iter().collect()
}

fn mcp_from_entry(entry: ExtensionEntry) -> McpExtension {
    let enabled = entry.enabled;
    let config = entry.config;
    let key = config.key();
    match config {
        ExtensionConfig::Stdio {
            name,
            description,
            cmd,
            args,
            envs,
            env_keys,
            timeout,
            bundled,
            ..
        } => McpExtension {
            key,
            name,
            kind: "stdio".into(),
            enabled,
            description,
            display_name: None,
            command: Some(cmd),
            args,
            uri: None,
            timeout,
            env_keys: env_keys_of(&envs, &env_keys),
            bundled: bundled.unwrap_or(false),
        },
        ExtensionConfig::StreamableHttp {
            name,
            description,
            uri,
            envs,
            env_keys,
            timeout,
            bundled,
            ..
        } => McpExtension {
            key,
            name,
            kind: "streamable_http".into(),
            enabled,
            description,
            display_name: None,
            command: None,
            args: vec![],
            uri: Some(uri),
            timeout,
            env_keys: env_keys_of(&envs, &env_keys),
            bundled: bundled.unwrap_or(false),
        },
        ExtensionConfig::Builtin {
            name,
            description,
            display_name,
            timeout,
            bundled,
            ..
        } => McpExtension {
            key,
            name,
            kind: "builtin".into(),
            enabled,
            description,
            display_name,
            command: None,
            args: vec![],
            uri: None,
            timeout,
            env_keys: vec![],
            bundled: bundled.unwrap_or(true),
        },
        ExtensionConfig::Platform {
            name,
            description,
            display_name,
            bundled,
            ..
        } => McpExtension {
            key,
            name,
            kind: "platform".into(),
            enabled,
            description,
            display_name,
            command: None,
            args: vec![],
            uri: None,
            timeout: None,
            env_keys: vec![],
            bundled: bundled.unwrap_or(true),
        },
    }
}

/// Every configured MCP extension, in config order.
pub fn list_mcp() -> Result<Vec<McpExtension>, String> {
    crate::connection::ensure_goose_env().map_err(|e| e.to_string())?;
    Ok(get_all_extensions().into_iter().map(mcp_from_entry).collect())
}

/// Create or update an MCP extension. Returns the normalized config key.
pub fn upsert_mcp(spec: McpSpec) -> Result<String, String> {
    crate::connection::ensure_goose_env().map_err(|e| e.to_string())?;
    let name = spec.name.trim().to_string();
    if name.is_empty() {
        return Err("an extension name is required".into());
    }
    let key = name_to_key(&name);
    // The UI never sees credential values, so an edit sends only the env/header
    // names. Reuse the stored values for any empty entry so editing a server
    // does not silently wipe its secrets.
    let existing = get_all_extensions()
        .into_iter()
        .find(|entry| entry.config.key() == key)
        .map(|entry| entry.config);
    let env = merge_env(existing.as_ref(), spec.env);
    let headers = merge_headers(existing.as_ref(), spec.headers);

    let config = match spec.kind.as_str() {
        "streamable_http" | "http" => {
            if spec.uri.trim().is_empty() {
                return Err("a server URI is required".into());
            }
            ExtensionConfig::StreamableHttp {
                name,
                description: spec.description,
                uri: spec.uri.trim().to_string(),
                envs: Envs::new(env),
                env_keys: spec.env_keys,
                headers,
                timeout: spec.timeout,
                socket: None,
                client_id: None,
                client_secret_key: None,
                scopes: vec![],
                bundled: None,
                available_tools: vec![],
            }
        }
        _ => {
            if spec.command.trim().is_empty() {
                return Err("a command is required".into());
            }
            ExtensionConfig::Stdio {
                name,
                description: spec.description,
                cmd: spec.command.trim().to_string(),
                args: spec.args,
                envs: Envs::new(env),
                env_keys: spec.env_keys,
                timeout: spec.timeout,
                cwd: None,
                bundled: None,
                available_tools: vec![],
            }
        }
    };
    set_extension(ExtensionEntry { enabled: spec.enabled, config });
    Ok(key)
}

/// Fill empty values in `incoming` from the existing config for the same keys.
fn merge_env(
    existing: Option<&ExtensionConfig>,
    incoming: HashMap<String, String>,
) -> HashMap<String, String> {
    let mut merged = incoming;
    let old = match existing {
        Some(ExtensionConfig::Stdio { envs, .. })
        | Some(ExtensionConfig::StreamableHttp { envs, .. }) => envs.get_env(),
        _ => return merged,
    };
    for (key, value) in merged.iter_mut() {
        if value.is_empty() {
            if let Some(previous) = old.get(key) {
                *value = previous.clone();
            }
        }
    }
    merged
}

/// Overlay new headers on the existing ones so an edit cannot drop the stored
/// authentication headers the UI does not display.
fn merge_headers(
    existing: Option<&ExtensionConfig>,
    incoming: HashMap<String, String>,
) -> HashMap<String, String> {
    let mut merged = match existing {
        Some(ExtensionConfig::StreamableHttp { headers, .. }) => headers.clone(),
        _ => HashMap::new(),
    };
    merged.extend(incoming);
    merged
}

/// Remove an MCP extension by config key.
pub fn remove_mcp(key: &str) -> Result<(), String> {
    crate::connection::ensure_goose_env().map_err(|e| e.to_string())?;
    let key = key.trim();
    if key.is_empty() {
        return Err("an extension key is required".into());
    }
    remove_extension(key);
    Ok(())
}

/// Toggle an MCP extension. Returns false when no entry has that key.
pub fn set_mcp_enabled(key: &str, enabled: bool) -> Result<bool, String> {
    crate::connection::ensure_goose_env().map_err(|e| e.to_string())?;
    let key = key.trim();
    if key.is_empty() {
        return Err("an extension key is required".into());
    }
    Ok(set_extension_enabled(key, enabled))
}

// ------------------------------------------------------------------- skills

/// App-level disabled skill names.
pub fn disabled_skills() -> HashSet<String> {
    // Must run before the first `Config::global()` so goose state stays under
    // the app-owned root rather than the user's ~/.config/goose.
    let _ = crate::connection::ensure_goose_env();
    Config::global()
        .get_param::<Vec<String>>(DISABLED_SKILLS_KEY)
        .map(|names| names.into_iter().collect())
        .unwrap_or_default()
}

/// True when `name` (raw or normalized) is in the disabled allowlist.
pub fn is_skill_disabled(name: &str) -> bool {
    let disabled = disabled_skills();
    disabled.contains(name) || disabled.contains(&name_to_key(name))
}

/// Installed skills (bundled + user + project) with app-level enablement.
pub fn list_skills(working_dir: Option<&Path>) -> Vec<InstalledSkill> {
    let _ = crate::connection::ensure_goose_env();
    let disabled = disabled_skills();
    goose::skills::list_installed_skills(working_dir)
        .into_iter()
        .map(|skill| InstalledSkill {
            id: skill.name.clone(),
            name: skill.name.clone(),
            description: skill.description.clone(),
            source: skill.source_type.to_string(),
            path: skill.path.clone(),
            global: skill.global,
            enabled: !disabled.contains(&skill.name),
        })
        .collect()
}

/// Enable or disable a skill by persisting it in the disabled allowlist.
pub fn set_skill_enabled(name: &str, enabled: bool) -> Result<(), String> {
    crate::connection::ensure_goose_env().map_err(|e| e.to_string())?;
    let name = name.trim();
    if name.is_empty() {
        return Err("a skill name is required".into());
    }
    let mut disabled = disabled_skills();
    if enabled {
        disabled.remove(name);
    } else {
        disabled.insert(name.to_string());
    }
    let mut list: Vec<String> = disabled.into_iter().collect();
    list.sort();
    Config::global()
        .set_param(DISABLED_SKILLS_KEY, list)
        .map_err(|e| e.to_string())
}

// --------------------------------------------------------------- app paths

fn stringify(path: PathBuf) -> String {
    path.to_string_lossy().into_owned()
}

/// Paths the Settings → About pane surfaces (and lets the user reveal).
pub fn app_paths() -> AppPaths {
    let goose_root = crate::connection::ensure_goose_env()
        .map(stringify)
        .unwrap_or_default();
    let config_path = Config::global().path();
    let skills_dir = goose::skills::global_skills_dir()
        .map(stringify)
        .unwrap_or_default();
    let venv_dir = crate::skill_install::venv_dir()
        .map(stringify)
        .unwrap_or_default();
    AppPaths {
        goose_root,
        goose_config: config_path,
        secrets: "goose secret store (Keychain / file fallback)".into(),
        skills_dir,
        venv_dir,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stdio_spec_requires_command() {
        let spec = McpSpec {
            name: "demo".into(),
            description: String::new(),
            kind: "stdio".into(),
            enabled: true,
            command: String::new(),
            args: vec![],
            env: HashMap::new(),
            env_keys: vec![],
            timeout: None,
            uri: String::new(),
            headers: HashMap::new(),
        };
        assert!(upsert_mcp(spec).unwrap_err().contains("command"));
    }

    #[test]
    fn http_spec_requires_uri() {
        let spec = McpSpec {
            name: "demo".into(),
            description: String::new(),
            kind: "streamable_http".into(),
            enabled: true,
            command: String::new(),
            args: vec![],
            env: HashMap::new(),
            env_keys: vec![],
            timeout: None,
            uri: String::new(),
            headers: HashMap::new(),
        };
        assert!(upsert_mcp(spec).unwrap_err().contains("URI"));
    }

    #[test]
    fn merge_env_preserves_existing_secret_for_empty_value() {
        let existing = ExtensionConfig::Stdio {
            name: "demo".into(),
            description: String::new(),
            cmd: "x".into(),
            args: vec![],
            envs: Envs::new(HashMap::from([("API_KEY".to_string(), "secret".to_string())])),
            env_keys: vec![],
            timeout: None,
            cwd: None,
            bundled: None,
            available_tools: vec![],
        };
        let merged = merge_env(
            Some(&existing),
            HashMap::from([("API_KEY".to_string(), String::new())]),
        );
        assert_eq!(merged.get("API_KEY").map(String::as_str), Some("secret"));
    }
}
