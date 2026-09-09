//! Native host storage. The host supplies its sandbox's Documents root; no
//! process-global current project or platform-specific home-directory policy.
use std::{fs, path::Path, sync::atomic::{AtomicU64, Ordering}};
use serde_json::{json, Value};
use crate::paths::safe_resolve;

static WRITE_ID: AtomicU64 = AtomicU64::new(0);

fn ensure_root(base: &Path) -> Result<std::path::PathBuf, String> {
    if !base.is_absolute() { return Err("Storage root must be absolute".into()); }
    let ancestor = base.ancestors().find(|p| p.exists()).ok_or("Storage has no existing ancestor")?;
    let relative = base.strip_prefix(ancestor).map_err(|e| e.to_string())?;
    let root = safe_resolve(&relative.to_string_lossy(), ancestor).map_err(|e| e.to_string())?;
    fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    Ok(root)
}

pub fn write(base: &Path, relative: &str, bytes: &[u8]) -> Result<(), String> {
    let root = ensure_root(base)?;
    let base = root.as_path();
    let path = safe_resolve(relative, base).map_err(|e| e.to_string())?;
    let parent = path.parent().ok_or("missing parent")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let temporary = format!("{}.{}-{}.tmp", relative, std::process::id(), WRITE_ID.fetch_add(1, Ordering::Relaxed));
    let tmp = safe_resolve(&temporary, base).map_err(|e| e.to_string())?;
    let result = (|| {
        use std::io::Write;
        let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, &path)
    })();
    if result.is_err() { let _ = fs::remove_file(tmp); }
    result.map_err(|e: std::io::Error| e.to_string())
}

pub fn request(base: &Path, value: &Value) -> Result<Value, String> {
    if !base.is_absolute() { return Err("Storage root must be absolute".into()); }
    let root = ensure_root(base)?;
    let field = |key| value.get(key).and_then(Value::as_str).ok_or_else(|| format!("Missing {key}"));
    match field("op")? {
        "create" => {
            let id = field("id")?;
            let name = field("name")?.trim();
            if id.is_empty() || id.len() > 120 || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') || name.is_empty() || name.len() > 240 {
                return Err("Invalid project name or identifier".into());
            }
            let folder = safe_resolve(id, &root).map_err(|e| e.to_string())?;
            fs::create_dir(&folder).map_err(|e| e.to_string())?;
            let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs_f64();
            let metadata = json!({"id":id, "name":name, "schema":1, "created":stamp});
            write(&root, &format!("{id}/project.json"), metadata.to_string().as_bytes())?;
            let cache = safe_resolve(&format!("{id}/.studio/cache/ai"), &root).map_err(|e| e.to_string())?;
            fs::create_dir_all(cache).map_err(|e| e.to_string())?;
            Ok(metadata)
        }
        "list" => {
            let mut projects = Vec::new();
            for entry in fs::read_dir(&root).map_err(|e| e.to_string())?.flatten() {
                if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) { continue; }
                let id = entry.file_name().to_string_lossy().into_owned();
                let path = safe_resolve(&format!("{id}/project.json"), &root).map_err(|e| e.to_string())?;
                if let Ok(text) = fs::read_to_string(path) {
                    if let Ok(mut data) = serde_json::from_str::<Value>(&text) {
                        if data["name"].is_string() && data["schema"] == 1 {
                            data["id"] = id.into();
                            projects.push(data);
                        }
                    }
                }
            }
            projects.sort_by(|a,b| a["name"].as_str().cmp(&b["name"].as_str()));
            Ok(projects.into())
        }
        "read" => {
            let path = safe_resolve(field("path")?, &root).map_err(|e| e.to_string())?;
            match fs::read_to_string(path) {
                Ok(text) => Ok(text.into()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Null),
                Err(e) => Err(e.to_string()),
            }
        }
        "write" => { write(&root, field("path")?, field("text")?.as_bytes())?; Ok(Value::Null) }
        _ => Err("Unknown storage operation".into()),
    }
}

/// Reserve a new artifact without replacing existing output, even across app
/// restarts or concurrent processes. False means the caller should pick a new name.
pub fn write_new(base: &Path, relative: &str, bytes: &[u8]) -> Result<bool, String> {
    use std::io::Write;
    let root = ensure_root(base)?;
    let path = safe_resolve(relative, &root).map_err(|e| e.to_string())?;
    fs::create_dir_all(path.parent().ok_or("Missing parent")?).map_err(|e| e.to_string())?;
    let mut file = match fs::OpenOptions::new().write(true).create_new(true).open(&path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(e) => return Err(e.to_string()),
    };
    if let Err(error) = file.write_all(bytes).and_then(|_| file.sync_all()) {
        let _ = fs::remove_file(path);
        return Err(error.to_string());
    }
    Ok(true)
}
