//! App-home resolution, project roots, workspaces and the path jail.
//!
//! Unlike the original Python backend (which pinned the "current project" and
//! "workspace" on thread-locals), the Rust core passes roots *explicitly*:
//! [`safe_resolve`] always takes a `base` and refuses anything that escapes it —
//! including via `..` segments or symlinks ([`PathJailError`]). The host (Swift,
//! or a future web shell) owns the notion of "which project/workspace is open".

use std::env;
use std::path::{Component, Path, PathBuf};

/// Studio-owned folders created inside a fresh project: none.
pub const PROJECT_FOLDERS: [&str; 0] = [];

/// Local state folders created inside a project's `.studio`.
pub const PROJECT_STATE_FOLDERS: [&str; 6] =
    ["jobs", "cache", "cache/thumbs", "backups", "audits", "clipboards"];

/// Marker file that identifies a studio project folder.
pub const PROJECT_MARKER: &str = "project.json";

/// Raised when a requested path escapes its project root (maps to HTTP 403 /
/// a hard error in the native app).
#[derive(Debug, Clone, thiserror::Error)]
#[error("path escapes the project root: {0}")]
pub struct PathJailError(pub String);

impl PathJailError {
    pub fn new(msg: impl Into<String>) -> Self {
        PathJailError(msg.into())
    }
}

fn env_or(names: &[&str]) -> Option<String> {
    for name in names {
        if let Ok(v) = env::var(name) {
            let v = v.trim().to_string();
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    None
}

/// Expand a leading `~` (or bare `~`) using `$HOME`.
fn expand_home(path: PathBuf) -> PathBuf {
    let s = path.to_string_lossy();
    let Ok(home) = env::var("HOME") else {
        return path;
    };
    if s == "~" {
        return PathBuf::from(home);
    }
    if let Some(rest) = s.strip_prefix("~/") {
        let mut p = PathBuf::from(home);
        if !rest.is_empty() {
            p.push(rest);
        }
        return p;
    }
    path
}

/// The app data home. `BIXEL_STATE_DIR` or `STUDIO_STATE_DIR` relocates it
/// (tests use this).
pub fn state_dir() -> PathBuf {
    if let Some(override_dir) = env_or(&["BIXEL_STATE_DIR", "STUDIO_STATE_DIR"]) {
        let expanded = expand_home(PathBuf::from(override_dir));
        return expanded
            .canonicalize()
            .unwrap_or(expanded);
    }
    default_home()
}

fn default_home() -> PathBuf {
    let local = studio_dir().join(".bixel-studio");
    if local.is_dir() {
        return local;
    }
    let new_home = PathBuf::from(env::var("HOME").unwrap_or_default()).join(".bixel-studio");
    let legacy_home =
        PathBuf::from(env::var("HOME").unwrap_or_default()).join(".langtown-asset-studio");
    if !new_home.exists() && legacy_home.exists() {
        return legacy_home;
    }
    new_home
}

/// Where the studio's own resources (skills, bundled assets) live. For the
/// native app this is the app bundle's resources; overridable with
/// `BIXEL_STUDIO_DIR`, defaulting to the current working directory.
pub fn studio_dir() -> PathBuf {
    if let Some(dir) = env_or(&["BIXEL_STUDIO_DIR"]) {
        return expand_home(PathBuf::from(dir));
    }
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Root folder that holds every studio-owned project.
pub fn projects_home() -> PathBuf {
    if let Some(dir) = env_or(&["BIXEL_PROJECTS_DIR", "STUDIO_PROJECTS_DIR"]) {
        return expand_home(PathBuf::from(dir));
    }
    state_dir().join("projects")
}

/// Create the app-home folder layout.
pub fn ensure_state_dirs() -> PathBuf {
    let root = state_dir();
    for sub in ["prompts", "cache", "cache/ai", "projects"] {
        let _ = std::fs::create_dir_all(root.join(sub));
    }
    let _ = std::fs::create_dir_all(projects_home());
    root
}

/// Resolve the deepest existing ancestor of `path` through symlinks, leaving
/// the non-existent tail untouched.
fn resolve_symlinks(path: &Path) -> PathBuf {
    let mut existing = path;
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    while !existing.exists() {
        match existing.parent() {
            Some(parent) => {
                if let Some(name) = existing.file_name() {
                    tail.push(name.to_os_string());
                }
                existing = parent;
            }
            None => break,
        }
    }
    let mut out = existing.canonicalize().unwrap_or_else(|_| existing.to_path_buf());
    for name in tail.iter().rev() {
        out.push(name);
    }
    out
}

/// Resolve `rel` inside `base`, refusing escapes.
///
/// `rel` is always treated as relative: a leading `/` is stripped rather than
/// rooting the path at the filesystem root.
pub fn safe_resolve(rel: &str, base: &Path) -> Result<PathBuf, PathJailError> {
    let root = base
        .canonicalize()
        .map_err(|_| PathJailError::new("base root does not exist"))?;

    let text = rel.trim();
    if text.is_empty() || text == "." {
        return Ok(root);
    }
    if text.contains('\0') {
        return Err(PathJailError::new("path contains a null byte"));
    }

    let stripped = text.trim_start_matches(['/', '\\']);
    let candidate = Path::new(stripped);
    if candidate.is_absolute() {
        return Err(PathJailError::new(format!(
            "absolute paths are not allowed: {text:?}"
        )));
    }

    let mut parts: Vec<std::ffi::OsString> = Vec::new();
    for comp in candidate.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if parts.pop().is_none() {
                    return Err(PathJailError::new(format!(
                        "path escapes the project root: {text:?}"
                    )));
                }
            }
            Component::Normal(c) => parts.push(c.to_os_string()),
            _ => return Err(PathJailError::new("invalid path component")),
        }
    }

    let rel_norm: PathBuf = parts.iter().collect();
    let joined = root.join(rel_norm);
    let resolved = resolve_symlinks(&joined);
    if resolved != root && !resolved.starts_with(&root) {
        return Err(PathJailError::new(format!(
            "path escapes the project root: {text:?}"
        )));
    }
    Ok(resolved)
}

/// Workspace-relative POSIX string for `path` (inverse of [`safe_resolve`]).
pub fn to_rel(path: &Path, base: &Path) -> Result<String, PathJailError> {
    let root = base
        .canonicalize()
        .map_err(|_| PathJailError::new("base root does not exist"))?;
    let resolved = path
        .canonicalize()
        .map_err(|_| PathJailError::new("path does not exist"))?;
    match resolved.strip_prefix(&root) {
        Ok(rel) => Ok(rel.to_string_lossy().replace('\\', "/")),
        Err(_) => Err(PathJailError::new("path is outside the workspace")),
    }
}

/// Workspace-relative when the path is inside `base`, absolute otherwise.
pub fn rel_or_abs(path: &Path, base: &Path) -> String {
    let root = base.canonicalize().unwrap_or_else(|_| base.to_path_buf());
    let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    match resolved.strip_prefix(&root) {
        Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
        Err(_) => resolved.to_string_lossy().into_owned(),
    }
}
