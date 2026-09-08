//! The Project: a self-contained, studio-owned workspace (port of
//! `core/projects.py`). A project is a folder under [`paths::projects_home`]
//! holding `project.json` plus its `.studio/` local state. Content lives in
//! *sources* (folders/files opened in place) — see [`crate::sources`].

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::paths::{self, ensure_state_dirs, projects_home, state_dir};

pub const SCHEMA: u32 = 1;

/// Raised for unknown projects and bad create payloads.
#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct ProjectError(pub String);

impl ProjectError {
    pub fn new(msg: impl Into<String>) -> Self {
        ProjectError(msg.into())
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    /// slug; also the folder name under `projects_home`.
    pub id: String,
    pub name: String,
    /// absolute path of the project folder.
    pub root: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub created: f64,
    #[serde(default)]
    pub updated: f64,
    #[serde(default)]
    pub opened: Option<f64>,
}

impl Project {
    pub fn path(&self) -> PathBuf {
        PathBuf::from(&self.root)
    }

    pub fn to_dict(&self) -> serde_json::Value {
        let mut v = serde_json::to_value(self).unwrap_or(serde_json::Value::Null);
        if let Some(obj) = v.as_object_mut() {
            obj.insert("kind".into(), "studio-project".into());
        }
        v
    }
}

/// `slugify` the way the Python backend does: alnum kept, everything else a
/// dash, collapsed runs of dashes trimmed.
pub fn slugify(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut prev_dash = false;
    for ch in name.trim().to_lowercase().chars() {
        if ch.is_alphanumeric() {
            out.push(ch);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    let slug = out.trim_matches('-');
    if slug.is_empty() {
        "project".to_string()
    } else {
        slug.to_string()
    }
}

fn meta_path(project_id: &str) -> PathBuf {
    projects_home().join(slugify(project_id)).join(paths::PROJECT_MARKER)
}

fn write_project(project: &Project) -> std::io::Result<()> {
    let path = project.path().join(paths::PROJECT_MARKER);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut text = serde_json::to_string_pretty(&project.to_dict())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    text.push('\n');
    std::fs::write(path, text)
}

/// Materialise `.studio` subfolders so project state stays local & ready.
pub fn ensure_local_state(project: &Project) -> std::io::Result<()> {
    let local = project.path().join(".studio");
    for sub in paths::PROJECT_STATE_FOLDERS {
        std::fs::create_dir_all(local.join(sub))?;
    }
    Ok(())
}

/// Make a fresh studio-owned project folder with its layout.
pub fn create(name: &str, description: &str) -> Result<Project, ProjectError> {
    let display = name.trim();
    if display.is_empty() {
        return Err(ProjectError::new("a project name is required"));
    }
    let base = slugify(display);
    let mut target = base.clone();
    let mut counter = 2;
    while meta_path(&target).exists() || projects_home().join(&target).exists() {
        target = format!("{base}-{counter}");
        counter += 1;
    }
    let stamp = now();
    let project = Project {
        id: target.clone(),
        name: display.to_string(),
        root: projects_home().join(&target).to_string_lossy().into_owned(),
        description: description.trim().to_string(),
        created: stamp,
        updated: stamp,
        opened: None,
    };
    std::fs::create_dir_all(project.path()).map_err(|e| ProjectError::new(e.to_string()))?;
    ensure_local_state(&project).map_err(|e| ProjectError::new(e.to_string()))?;
    write_project(&project).map_err(|e| ProjectError::new(e.to_string()))?;
    Ok(project)
}

fn valid_id(project_id: &str) -> bool {
    let s = project_id.trim();
    !s.is_empty()
        && s.len() <= 120
        && s.chars().next().map(|c| c.is_ascii_alphanumeric()).unwrap_or(false)
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Read a project from disk.
pub fn load(project_id: &str) -> Result<Project, ProjectError> {
    if !valid_id(project_id) {
        return Err(ProjectError::new("unknown project"));
    }
    let path = meta_path(project_id);
    let text = std::fs::read_to_string(&path).map_err(|_| ProjectError::new("unknown project"))?;
    let data: serde_json::Value =
        serde_json::from_str(&text).map_err(|_| ProjectError::new("unknown project"))?;
    let Some(name) = data.get("name").and_then(|v| v.as_str()) else {
        return Err(ProjectError::new("unknown project"));
    };
    let project = Project {
        id: slugify(project_id),
        name: name.to_string(),
        description: data.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        root: path
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default(),
        created: data.get("created").and_then(|v| v.as_f64()).unwrap_or_else(now),
        updated: data.get("updated").and_then(|v| v.as_f64()).unwrap_or_else(now),
        opened: data.get("opened").and_then(|v| v.as_f64()),
    };
    Ok(project)
}

/// Every project under the projects home, most recently touched first.
pub fn list_projects(limit: usize) -> Vec<serde_json::Value> {
    let _ = ensure_state_dirs();
    let home = projects_home();
    let mut items: Vec<serde_json::Value> = Vec::new();
    let Ok(entries) = std::fs::read_dir(&home) else {
        return items;
    };
    for entry in entries.flatten() {
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        match load(&name) {
            Ok(p) => {
                let mut d = p.to_dict();
                if let Some(obj) = d.as_object_mut() {
                    obj.insert("available".into(), true.into());
                }
                items.push(d);
            }
            Err(_) => {
                let (ctime, mtime) = std::fs::metadata(entry.path())
                    .map(|m| {
                        let to_secs = |t: std::io::Result<SystemTime>| {
                            t.ok()
                                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                                .map(|d| d.as_secs_f64())
                                .unwrap_or(0.0)
                        };
                        (to_secs(m.created()), to_secs(m.modified()))
                    })
                    .unwrap_or((0.0, 0.0));
                items.push(serde_json::json!({
                    "kind": "studio-project",
                    "id": name,
                    "name": name,
                    "description": "Project files or metadata missing",
                    "root": entry.path().to_string_lossy(),
                    "available": false,
                    "created": ctime,
                    "updated": mtime,
                    "opened": null,
                }));
            }
        }
    }
    items.sort_by(|a, b| {
        let at = a.get("opened").and_then(|v| v.as_f64()).unwrap_or(0.0)
            .max(a.get("updated").and_then(|v| v.as_f64()).unwrap_or(0.0));
        let bt = b.get("opened").and_then(|v| v.as_f64()).unwrap_or(0.0)
            .max(b.get("updated").and_then(|v| v.as_f64()).unwrap_or(0.0));
        bt.partial_cmp(&at).unwrap_or(std::cmp::Ordering::Equal)
    });
    items.truncate(limit);
    items
}

/// Permanently delete a project folder and clear the active project if open.
pub fn delete(project_id: &str) -> Result<(), ProjectError> {
    let slug = slugify(project_id);
    let home = projects_home()
        .canonicalize()
        .map_err(|e| ProjectError::new(e.to_string()))?;
    let folder = projects_home().join(&slug);
    let resolved = folder
        .canonicalize()
        .unwrap_or_else(|_| folder.clone());
    if !resolved.starts_with(&home) {
        return Err(ProjectError::new("invalid project id"));
    }
    if active_id() == slug || active_id() == project_id {
        let _ = set_active(None);
    }
    if folder.is_dir() {
        std::fs::remove_dir_all(&folder).map_err(|e| ProjectError::new(e.to_string()))?;
    } else if folder.exists() {
        let _ = std::fs::remove_file(&folder);
    }
    Ok(())
}

/// Mark the project as used: bump the `updated` and `opened` stamps.
pub fn touch(project: &mut Project) -> std::io::Result<()> {
    let stamp = now();
    project.updated = stamp;
    project.opened = Some(stamp);
    write_project(project)
}

// ------------------------------------------------------------------ active

pub fn active_id() -> String {
    let Ok(text) = std::fs::read_to_string(state_dir().join("active.json")) else {
        return String::new();
    };
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&text) else {
        return String::new();
    };
    data.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string()
}

pub fn set_active(project: Option<&Project>) -> std::io::Result<()> {
    ensure_state_dirs();
    let payload = match project {
        Some(p) => serde_json::json!({ "id": p.id }),
        None => serde_json::json!({}),
    };
    std::fs::write(state_dir().join("active.json"), payload.to_string())
}

/// The open project, or `None` when the studio has no project open.
pub fn current() -> Option<Project> {
    let project_id = active_id();
    if project_id.is_empty() {
        return None;
    }
    match load(&project_id) {
        Ok(p) => Some(p),
        Err(_) => {
            let _ = set_active(None);
            None
        }
    }
}

pub fn require_project() -> Result<Project, ProjectError> {
    current().ok_or_else(|| ProjectError::new("open or create a project first"))
}
