//! Sources: folders and files a project opens *in place* (port of
//! `core/sources.py`). A project keeps a list of source paths it edits directly
//! — nothing is copied. The **workspace** is whichever source is active,
//! falling back to the project folder.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::paths::ensure_state_dirs;
use crate::project::{self, Project};

/// Sentinel id for "the project's own folder" (no external source active).
pub const PROJECT_SOURCE_ID: &str = "project";

#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct SourceError(pub String);

impl SourceError {
    pub fn new(msg: impl Into<String>) -> Self {
        SourceError(msg.into())
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn state_dir(project: &Project) -> PathBuf {
    let _ = project::ensure_local_state(project);
    project.path().join(".studio")
}

fn sources_path(project: &Project) -> PathBuf {
    state_dir(project).join("sources.json")
}

fn active_path(project: &Project) -> PathBuf {
    state_dir(project).join("active_source.json")
}

pub fn list_sources(project: &Project) -> Vec<Value> {
    let Ok(text) = std::fs::read_to_string(sources_path(project)) else {
        return Vec::new();
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Array(items)) => items,
        _ => Vec::new(),
    }
}

fn save(project: &Project, sources: &[Value]) -> std::io::Result<()> {
    let mut text = serde_json::to_string_pretty(sources).map_err(io_other)?;
    text.push('\n');
    std::fs::write(sources_path(project), text)
}

fn io_other<E: std::fmt::Display>(e: E) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, e.to_string())
}

/// Register a folder/file by its real path. Never copies anything.
pub fn add(project: &Project, raw_path: &str) -> Result<Value, SourceError> {
    let text = raw_path.trim();
    if text.is_empty() {
        return Err(SourceError::new("enter a folder or file path"));
    }
    let path = PathBuf::from(text);
    if !path.is_absolute() {
        return Err(SourceError::new("enter an absolute path to the folder or file"));
    }
    let path = path
        .canonicalize()
        .map_err(|_| SourceError::new("nothing exists at that path"))?;

    let (kind, label) = if path.is_dir() {
        ("folder", path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
    } else if path.is_file() {
        ("file", path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
    } else {
        return Err(SourceError::new("nothing exists at that path"));
    };

    let mut sources = list_sources(project);
    if sources.iter().any(|s| s.get("path").and_then(|v| v.as_str()) == Some(path.to_str().unwrap_or(""))) {
        return Err(SourceError::new(format!("{label} is already in this project")));
    }

    let base = project::slugify(&label);
    let mut identifier = base.clone();
    let mut counter = 2;
    while sources.iter().any(|s| s.get("id").and_then(|v| v.as_str()) == Some(identifier.as_str())) {
        identifier = format!("{base}-{counter}");
        counter += 1;
    }

    let source = json!({
        "id": identifier,
        "name": label,
        "path": path.to_string_lossy(),
        "kind": kind,
        "added": now(),
    });
    sources.push(source.clone());
    save(project, &sources).map_err(|e| SourceError::new(e.to_string()))?;
    Ok(source)
}

pub fn remove(project: &Project, source_id: &str) -> Result<bool, SourceError> {
    let sources = list_sources(project);
    let original_len = sources.len();
    let kept: Vec<Value> = sources
        .into_iter()
        .filter(|s| s.get("id").and_then(|v| v.as_str()) != Some(source_id))
        .collect();
    if kept.len() == original_len {
        return Ok(false);
    }
    save(project, &kept).map_err(|e| SourceError::new(e.to_string()))?;
    if active_id(project) == source_id {
        set_active(project, PROJECT_SOURCE_ID)?;
    }
    Ok(true)
}

fn set_active_raw(project: &Project, source_id: &str) -> std::io::Result<()> {
    let _ = ensure_state_dirs();
    std::fs::write(active_path(project), json!({ "id": source_id }).to_string())
}

pub fn active_id(project: &Project) -> String {
    let Ok(text) = std::fs::read_to_string(active_path(project)) else {
        return PROJECT_SOURCE_ID.to_string();
    };
    let Ok(data) = serde_json::from_str::<Value>(&text) else {
        return PROJECT_SOURCE_ID.to_string();
    };
    data.get("id").and_then(|v| v.as_str()).unwrap_or(PROJECT_SOURCE_ID).to_string()
}

pub fn set_active(project: &Project, source_id: &str) -> Result<bool, SourceError> {
    if source_id == PROJECT_SOURCE_ID {
        set_active_raw(project, PROJECT_SOURCE_ID).map_err(|e| SourceError::new(e.to_string()))?;
        return Ok(true);
    }
    for source in list_sources(project) {
        if source.get("id").and_then(|v| v.as_str()) == Some(source_id) {
            set_active_raw(project, source_id).map_err(|e| SourceError::new(e.to_string()))?;
            return Ok(true);
        }
    }
    Err(SourceError::new(format!("unknown source: {source_id}")))
}

/// The active external source, or `None` (meaning the project folder).
pub fn active(project: &Project) -> Option<Value> {
    let identifier = active_id(project);
    if identifier == PROJECT_SOURCE_ID {
        return None;
    }
    list_sources(project)
        .into_iter()
        .find(|s| s.get("id").and_then(|v| v.as_str()) == Some(identifier.as_str()))
}

/// The workspace root a request operates on. A *folder* source is itself the
/// root; a *file* source opens as its parent directory so siblings stay
/// reachable. Without an active source, the workspace is the project folder.
pub fn workspace_root_for(source: Option<&Value>, project: &Project) -> PathBuf {
    match source {
        None => project.path(),
        Some(s) => {
            let path = PathBuf::from(s.get("path").and_then(|v| v.as_str()).unwrap_or(""));
            if path.is_dir() {
                path
            } else {
                path.parent().map(|p| p.to_path_buf()).unwrap_or(path)
            }
        }
    }
}

/// Resolve a workspace-relative path against the currently active source.
pub fn resolve_in_workspace(project: &Project, rel: &str) -> Result<PathBuf, crate::paths::PathJailError> {
    let source = active(project);
    let root = workspace_root_for(source.as_ref(), project);
    crate::paths::safe_resolve(rel, &root)
}
