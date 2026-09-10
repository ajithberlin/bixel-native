//! Native host storage. The host supplies its sandbox's Documents root; no
//! process-global current project or platform-specific home-directory policy.
use std::{fs, path::Path, sync::atomic::{AtomicU64, Ordering}};
use serde_json::{json, Value};
use crate::paths::safe_resolve;

static WRITE_ID: AtomicU64 = AtomicU64::new(0);

// Inventory and binary reads accept only literal relative paths, and never
// follow links (including links that happen to point back inside the root).
fn file_path(root: &Path, relative: &str) -> Result<std::path::PathBuf, String> {
    use std::path::Component;
    let relative = relative.trim();
    let path = Path::new(relative);
    if path.is_absolute() || relative.starts_with('\\') || path.components().any(|part| matches!(part, Component::ParentDir)) {
        return Err("Expected a relative path without traversal".into());
    }
    let resolved = safe_resolve(relative, root).map_err(|e| e.to_string())?;
    let mut current = root.to_path_buf();
    for part in path.components() {
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => return Err("Symbolic links are not allowed".into()),
            Ok(_) => {},
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(resolved)
}

fn files(root: &Path, relative: &str, recursive: bool) -> Result<Value, String> {
    let directory = file_path(root, relative)?;
    let mut pending = std::collections::BTreeSet::from([directory]);
    let mut files = Vec::new();
    while let Some(directory) = pending.pop_first() {
        let entries = match fs::read_dir(directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.to_string()),
        };
        let mut entries = entries.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let kind = entry.file_type().map_err(|e| e.to_string())?;
            if kind.is_symlink() { continue; }
            let entry_path = entry.path();
            let relative = entry_path.strip_prefix(root).map_err(|e| e.to_string())?
                .to_str().ok_or("File path is not UTF-8")?;
            let path = file_path(root, relative)?;
            if kind.is_dir() && recursive {
                pending.insert(path);
            } else if kind.is_file() {
                let metadata = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
                if !metadata.is_file() { continue; }
                files.push(json!({"path": relative, "name": entry.file_name().to_string_lossy(), "bytes": metadata.len()}));
                if files.len() == 2000 { break; }
            }
        }
        if files.len() == 2000 { break; }
    }
    files.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    Ok(files.into())
}

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

/// Read a regular file under the storage root. `Ok(None)` means not found.
/// Used by the bulk FFI path so the host never round-trips bytes as JSON.
pub fn read_bytes(base: &Path, relative: &str) -> Result<Option<Vec<u8>>, String> {
    use std::io::Read;
    const MAX_BYTES: u64 = 32_000_000;
    let root = ensure_root(base)?;
    let path = file_path(&root, relative)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.is_file() => {},
        Ok(_) => return Err("Expected a regular file".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    }
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() {
        return Err("Expected a regular file".into());
    }
    if metadata.len() > MAX_BYTES {
        return Err("Choose an asset no larger than 32 MB.".into());
    }
    // Bound the actual read too: a file may grow after metadata is read.
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err("Choose an asset no larger than 32 MB.".into());
    }
    Ok(Some(bytes))
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
        "files" => {
            let recursive = match value.get("recursive") {
                None => true,
                Some(value) => value.as_bool().ok_or("recursive must be a boolean")?,
            };
            files(&root, field("path")?, recursive)
        }
        "read_bytes" => {
            match read_bytes(&root, field("path")?)? {
                Some(bytes) => Ok(json!(bytes)),
                None => Ok(Value::Null),
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
