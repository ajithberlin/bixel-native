//! The asset clipboard: a per-project tray of assets you are working with
//! (port of `core/clipboard.py`). Stored in the project's `.studio/clipboards/`.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::paths::safe_resolve;
use crate::project::{self, Project};

const MAX_CLIPS: usize = 200;

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn tray_path(project: &Project) -> PathBuf {
    let _ = project::ensure_local_state(project);
    let folder = project.path().join(".studio").join("clipboards");
    let _ = std::fs::create_dir_all(&folder);
    folder.join("default.json")
}

pub fn list_clips(project: &Project) -> Vec<Value> {
    let path = tray_path(project);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Array(items)) => items,
        _ => Vec::new(),
    }
}

fn save(project: &Project, clips: &[Value]) -> std::io::Result<()> {
    let mut text = serde_json::to_string_pretty(clips)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    text.push('\n');
    std::fs::write(tray_path(project), text)
}

/// Pin an asset. Silently no-ops when it is already clipped.
pub fn clip(project: &Project, rel: &str) -> Result<Value, crate::paths::PathJailError> {
    let root = crate::sources::workspace_root_for(crate::sources::active(project).as_ref(), project);
    let path = safe_resolve(rel, &root)?;
    let rel_norm = crate::paths::to_rel(&path, &root)?;

    let mut clips = list_clips(project);
    if clips.iter().any(|c| c.get("rel").and_then(|v| v.as_str()) == Some(rel_norm.as_str())) {
        return Ok(json!({ "clips": clips, "added": false }));
    }
    if !path.is_file() {
        return Err(crate::paths::PathJailError::new("asset does not exist"));
    }
    clips.insert(
        0,
        json!({
            "rel": rel_norm,
            "name": path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            "added": now(),
        }),
    );
    clips.truncate(MAX_CLIPS);
    save(project, &clips).map_err(|e| crate::paths::PathJailError::new(e.to_string()))?;
    Ok(json!({ "clips": list_clips(project), "added": true }))
}

pub fn unclip(project: &Project, rel: &str) -> Result<Value, crate::paths::PathJailError> {
    let root = crate::sources::workspace_root_for(crate::sources::active(project).as_ref(), project);
    let path = safe_resolve(rel, &root)?;
    let rel_norm = crate::paths::to_rel(&path, &root)?;
    let clips: Vec<Value> = list_clips(project)
        .into_iter()
        .filter(|c| c.get("rel").and_then(|v| v.as_str()) != Some(rel_norm.as_str()))
        .collect();
    save(project, &clips).map_err(|e| crate::paths::PathJailError::new(e.to_string()))?;
    Ok(json!({ "clips": clips, "removed": true }))
}

pub fn clear(project: &Project) -> std::io::Result<Value> {
    save(project, &[])?;
    Ok(json!({ "clips": [] }))
}
