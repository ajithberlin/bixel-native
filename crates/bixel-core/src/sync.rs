//! Project sync core: content-addressed manifests, three-way diffing, and
//! conflict planning for Mac ↔ iPad project replication.
//!
//! This module is deliberately network-free: the host scans a project into a
//! [`Manifest`], exchanges manifests with a peer, and hands the local/remote
//! pair plus the last common `base` to [`plan`]. The returned [`SyncPlan`] is a
//! pure description of what to pull, push, delete, or flag as a conflict — the
//! transport layer only executes it.
//!
//! Design rules that keep creative work safe:
//!
//! * Every file is identified by a `blake3` content hash, so identical frames
//!   and assets dedupe instead of transferring twice.
//! * Regenerable state (`.studio/cache/**`) and sync bookkeeping
//!   (`.studio/sync/**`) are excluded from manifests.
//! * Documents are never auto-merged. When both sides changed a file since the
//!   common base, the plan reports a conflict and the caller preserves both
//!   copies (see [`conflict_name`]).

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Read;
use std::path::Path;
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};

use crate::paths::safe_resolve;

/// Manifest schema version. Bump when the shape changes incompatibly.
pub const SYNC_SCHEMA: u32 = 1;

/// Project-relative location of the per-project manifest.
pub const MANIFEST_RELATIVE: &str = ".studio/sync/manifest.json";

/// Content-addressed blob store, relative to the projects root (shared by every
/// project so identical assets are stored once).
pub const BLOBS_RELATIVE: &str = ".studio/sync/blobs";

const HASH_BUFFER: usize = 64 * 1024;

/// One tracked file: its content hash, size, and last-modified time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileEntry {
    /// `blake3:<hex>` — content hash, stable across devices and renames.
    pub hash: String,
    pub bytes: u64,
    #[serde(default)]
    pub updated_unix: u64,
}

/// A project's tracked file set plus the logical revision it was committed at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub schema: u32,
    pub project_id: String,
    /// Monotonic per-project revision, bumped on commit (never on scan).
    #[serde(default)]
    pub revision: u64,
    /// Device that produced this revision (used for conflict file naming).
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub updated_unix: u64,
    pub files: BTreeMap<String, FileEntry>,
}

impl Manifest {
    pub fn new(project_id: impl Into<String>, device: impl Into<String>) -> Self {
        Manifest {
            schema: SYNC_SCHEMA,
            project_id: project_id.into(),
            revision: 0,
            device: device.into(),
            updated_unix: now_unix(),
            files: BTreeMap::new(),
        }
    }

    /// True when two manifests describe identical file contents.
    pub fn same_files(&self, other: &Manifest) -> bool {
        self.files == other.files
    }
}

/// A file both peers changed since the common base. The caller must keep both
/// versions rather than silently overwriting either side.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Conflict {
    pub path: String,
    pub local_hash: Option<String>,
    pub remote_hash: Option<String>,
    pub base_hash: Option<String>,
}

/// The work needed to reconcile a local and remote manifest against a base.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncPlan {
    /// Paths to fetch from the peer and write locally.
    pub pull: Vec<String>,
    /// Paths to send to the peer.
    pub push: Vec<String>,
    /// Paths deleted on the peer, to remove locally.
    pub delete_local: Vec<String>,
    /// Paths deleted locally, to remove on the peer.
    pub delete_remote: Vec<String>,
    /// Paths changed on both sides — never auto-merged.
    pub conflicts: Vec<Conflict>,
}

impl SyncPlan {
    /// True when local and remote already agree (no transfers, no conflicts).
    pub fn is_empty(&self) -> bool {
        self.pull.is_empty()
            && self.push.is_empty()
            && self.delete_local.is_empty()
            && self.delete_remote.is_empty()
            && self.conflicts.is_empty()
    }
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Hash arbitrary bytes as `blake3:<hex>`.
pub fn hash_bytes(bytes: &[u8]) -> String {
    format!("blake3:{}", blake3::hash(bytes).to_hex())
}

/// Stream a file through BLAKE3 so large pixel documents never load fully into
/// memory. Returns `blake3:<hex>`.
pub fn hash_file(path: &Path) -> Result<String, String> {
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = blake3::Hasher::new();
    let mut buffer = vec![0u8; HASH_BUFFER];
    loop {
        let read = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("blake3:{}", hasher.finalize().to_hex()))
}

/// Paths that never travel: regenerable caches, sync bookkeeping, and stray
/// temporary files. `relative` uses `/` separators.
pub fn is_excluded(relative: &str) -> bool {
    let rel = relative.trim_start_matches("./");
    rel == ".studio/sync"
        || rel.starts_with(".studio/sync/")
        || rel == ".studio/cache"
        || rel.starts_with(".studio/cache/")
        || rel.ends_with(".tmp")
}

/// Walk a project directory and hash every trackable file. Symlinks are skipped
/// (mirrors [`crate::storage`]'s jail) and the result is sorted by path.
pub fn scan_files(project_root: &Path) -> Result<BTreeMap<String, FileEntry>, String> {
    if !project_root.is_absolute() {
        return Err("Project root must be absolute".into());
    }
    let mut files = BTreeMap::new();
    let mut pending = vec![project_root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let entries = match fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.to_string()),
        };
        for entry in entries {
            let entry = entry.map_err(|e| e.to_string())?;
            let kind = entry.file_type().map_err(|e| e.to_string())?;
            if kind.is_symlink() {
                continue;
            }
            let path = entry.path();
            let relative = path
                .strip_prefix(project_root)
                .map_err(|e| e.to_string())?
                .to_str()
                .ok_or("File path is not UTF-8")?
                .replace('\\', "/");
            if kind.is_dir() {
                if !is_excluded(&relative) {
                    pending.push(path);
                }
            } else if kind.is_file() {
                if is_excluded(&relative) {
                    continue;
                }
                let metadata = entry.metadata().map_err(|e| e.to_string())?;
                let updated_unix = metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                    .map(|duration| duration.as_secs())
                    .unwrap_or(0);
                files.insert(
                    relative,
                    FileEntry {
                        hash: hash_file(&path)?,
                        bytes: metadata.len(),
                        updated_unix,
                    },
                );
            }
        }
    }
    Ok(files)
}

/// Build a manifest from a project directory, preserving the revision/device of
/// an existing manifest when present. Scanning never bumps the revision.
pub fn scan_manifest(project_root: &Path, project_id: &str) -> Result<Manifest, String> {
    let mut manifest = read_manifest(project_root).unwrap_or_else(|| Manifest::new(project_id, ""));
    manifest.schema = SYNC_SCHEMA;
    manifest.project_id = project_id.to_string();
    manifest.files = scan_files(project_root)?;
    Ok(manifest)
}

/// Read a project's manifest, or `None` when it has never been synced.
pub fn read_manifest(project_root: &Path) -> Option<Manifest> {
    let path = safe_resolve(MANIFEST_RELATIVE, project_root).ok()?;
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Atomically persist a project's manifest (temp + rename via [`crate::storage`]).
pub fn write_manifest(project_root: &Path, manifest: &Manifest) -> Result<(), String> {
    let body = serde_json::to_vec(manifest).map_err(|e| e.to_string())?;
    crate::storage::write(project_root, MANIFEST_RELATIVE, &body)
}

/// Three-way reconcile. `base` is the last manifest both sides agreed on
/// (`None` for a first-ever sync).
///
/// * local unchanged (`l == base`), remote changed → `pull`
/// * remote unchanged (`r == base`), local changed → `push`
/// * both changed to the same content → converged, nothing to do
/// * both changed differently → `conflicts`
/// * a file deleted on one side and untouched on the other → propagate delete
/// * a file deleted on one side and edited on the other → `conflicts`
pub fn plan(base: Option<&Manifest>, local: &Manifest, remote: &Manifest) -> SyncPlan {
    let mut paths: BTreeSet<&str> = BTreeSet::new();
    paths.extend(local.files.keys().map(String::as_str));
    paths.extend(remote.files.keys().map(String::as_str));
    if let Some(base) = base {
        paths.extend(base.files.keys().map(String::as_str));
    }

    let hash = |manifest: Option<&Manifest>, path: &str| -> Option<String> {
        manifest
            .and_then(|m| m.files.get(path))
            .map(|entry| entry.hash.clone())
    };

    let mut result = SyncPlan::default();
    for path in paths {
        let l = hash(Some(local), path);
        let r = hash(Some(remote), path);
        let b = hash(base, path);

        match (l, r, b) {
            (Some(lh), Some(rh), _) if lh == rh => {}
            (Some(lh), Some(rh), Some(bh)) => {
                if lh == bh {
                    result.pull.push(path.to_string());
                } else if rh == bh {
                    result.push.push(path.to_string());
                } else {
                    result.conflicts.push(Conflict {
                        path: path.to_string(),
                        local_hash: Some(lh),
                        remote_hash: Some(rh),
                        base_hash: Some(bh),
                    });
                }
            }
            (Some(lh), Some(rh), None) => result.conflicts.push(Conflict {
                path: path.to_string(),
                local_hash: Some(lh),
                remote_hash: Some(rh),
                base_hash: None,
            }),
            (Some(lh), None, Some(bh)) => {
                if lh == bh {
                    result.delete_local.push(path.to_string());
                } else {
                    result.conflicts.push(Conflict {
                        path: path.to_string(),
                        local_hash: Some(lh),
                        remote_hash: None,
                        base_hash: Some(bh),
                    });
                }
            }
            (Some(_), None, None) => result.push.push(path.to_string()),
            (None, Some(rh), Some(bh)) => {
                if rh == bh {
                    result.delete_remote.push(path.to_string());
                } else {
                    result.conflicts.push(Conflict {
                        path: path.to_string(),
                        local_hash: None,
                        remote_hash: Some(rh),
                        base_hash: Some(bh),
                    });
                }
            }
            (None, Some(_), None) => result.pull.push(path.to_string()),
            (None, None, Some(_)) => {}
            (None, None, None) => {}
        }
    }
    result
}

/// Derive the preserved-peer filename for a conflict, e.g.
/// `documents/a.json` → `documents/a.conflict-ipad-1699999999.json`.
pub fn conflict_name(path: &str, device: &str, timestamp: u64) -> String {
    let device: String = device
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect();
    let device = if device.is_empty() { "peer" } else { device.as_str() };
    match path.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => {
            format!("{stem}.conflict-{device}-{timestamp}.{extension}")
        }
        _ => format!("{path}.conflict-{device}-{timestamp}"),
    }
}

/// Project-relative path of a blob in the shared content-addressed store.
/// `hash` is `blake3:<hex>`.
pub fn blob_relative(hash: &str) -> Result<String, String> {
    let hex = hash.strip_prefix("blake3:").unwrap_or(hash);
    if hex.is_empty() || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid blob hash".into());
    }
    Ok(format!("{BLOBS_RELATIVE}/{hex}"))
}

/// Store bytes in the content-addressed blob store (idempotent) and return the
/// `blake3:<hex>` hash. Existing blobs are left untouched.
pub fn store_blob(projects_root: &Path, bytes: &[u8]) -> Result<String, String> {
    let hash = hash_bytes(bytes);
    let relative = blob_relative(&hash)?;
    let path = safe_resolve(&relative, projects_root).map_err(|e| e.to_string())?;
    if path.is_file() {
        return Ok(hash);
    }
    crate::storage::write(projects_root, &relative, bytes)?;
    Ok(hash)
}

/// Read a blob by hash, or `None` when it is not present locally.
pub fn read_blob(projects_root: &Path, hash: &str) -> Result<Option<Vec<u8>>, String> {
    let relative = blob_relative(hash)?;
    let path = safe_resolve(&relative, projects_root).map_err(|e| e.to_string())?;
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(root: &Path, relative: &str, body: &str) {
        crate::storage::write(root, relative, body.as_bytes()).unwrap();
    }

    fn project() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "bixel-sync-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn entry(hash: &str) -> FileEntry {
        FileEntry { hash: hash.into(), bytes: 1, updated_unix: 0 }
    }

    #[test]
    fn scan_ignores_cache_and_sync_but_tracks_documents() {
        let root = project();
        write(&root, "project.json", "{}");
        write(&root, "documents/a.json", "{\"schema\":1}");
        write(&root, "assets/hero.png", "PNG");
        write(&root, ".studio/cache/ai/1/foo.png", "cache");
        write(&root, ".studio/sync/manifest.json", "{}");

        let files = scan_files(&root).unwrap();
        let paths: Vec<&str> = files.keys().map(String::as_str).collect();
        assert_eq!(paths, vec!["assets/hero.png", "documents/a.json", "project.json"]);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn manifest_round_trips_and_hash_is_content_addressed() {
        let root = project();
        write(&root, "project.json", "{\"name\":\"a\"}");
        let mut manifest = scan_manifest(&root, "proj-1").unwrap();
        assert_eq!(manifest.schema, SYNC_SCHEMA);
        manifest.revision = 7;
        manifest.device = "mac".into();
        write_manifest(&root, &manifest).unwrap();

        let loaded = read_manifest(&root).unwrap();
        assert_eq!(loaded.revision, 7);
        assert_eq!(loaded.device, "mac");
        assert_eq!(loaded.files["project.json"].hash, hash_bytes(b"{\"name\":\"a\"}"));

        // Same content scanned twice produces the same hash.
        assert_eq!(scan_files(&root).unwrap(), manifest.files);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn plan_pushes_local_only_and_pulls_remote_only() {
        let mut local = Manifest::new("p", "mac");
        local.files.insert("documents/a.json".into(), entry("h1"));
        let mut remote = Manifest::new("p", "ipad");
        remote.files.insert("documents/b.json".into(), entry("h2"));

        let plan = plan(None, &local, &remote);
        assert_eq!(plan.push, vec!["documents/a.json"]);
        assert_eq!(plan.pull, vec!["documents/b.json"]);
        assert!(plan.conflicts.is_empty());
    }

    #[test]
    fn plan_detects_both_sides_changed_as_conflict() {
        let mut base = Manifest::new("p", "mac");
        base.files.insert("documents/a.json".into(), entry("h0"));
        let mut local = Manifest::new("p", "mac");
        local.files.insert("documents/a.json".into(), entry("h1"));
        let mut remote = Manifest::new("p", "ipad");
        remote.files.insert("documents/a.json".into(), entry("h2"));

        let plan = plan(Some(&base), &local, &remote);
        assert!(plan.pull.is_empty() && plan.push.is_empty());
        assert_eq!(plan.conflicts.len(), 1);
        assert_eq!(plan.conflicts[0].path, "documents/a.json");
    }

    #[test]
    fn plan_converges_when_both_sides_made_the_same_change() {
        let mut base = Manifest::new("p", "mac");
        base.files.insert("documents/a.json".into(), entry("h0"));
        let mut local = Manifest::new("p", "mac");
        local.files.insert("documents/a.json".into(), entry("h1"));
        let mut remote = Manifest::new("p", "ipad");
        remote.files.insert("documents/a.json".into(), entry("h1"));

        let plan = plan(Some(&base), &local, &remote);
        assert!(plan.is_empty());
    }

    #[test]
    fn plan_propagates_deletes_and_flags_delete_versus_edit() {
        let mut base = Manifest::new("p", "mac");
        base.files.insert("assets/a.png".into(), entry("h0"));
        base.files.insert("assets/b.png".into(), entry("h0"));

        // Local deleted both; remote left a untouched but edited b.
        let mut local = Manifest::new("p", "mac");
        local.files.insert("project.json".into(), entry("x"));
        let mut remote = Manifest::new("p", "ipad");
        remote.files.insert("assets/a.png".into(), entry("h0"));
        remote.files.insert("assets/b.png".into(), entry("h1"));
        remote.files.insert("project.json".into(), entry("x"));

        let plan = plan(Some(&base), &local, &remote);
        assert_eq!(plan.delete_remote, vec!["assets/a.png"]);
        assert_eq!(plan.conflicts.len(), 1);
        assert_eq!(plan.conflicts[0].path, "assets/b.png");
    }

    #[test]
    fn conflict_name_keeps_extension_and_sanitizes_device() {
        assert_eq!(
            conflict_name("documents/a.json", "iPad Pro", 42),
            "documents/a.conflict-iPad-Pro-42.json"
        );
        assert_eq!(conflict_name("assets/raw", "ipad", 7), "assets/raw.conflict-ipad-7");
    }

    #[test]
    fn blob_store_is_idempotent_and_content_addressed() {
        let root = project();
        let hash = store_blob(&root, b"hello").unwrap();
        assert_eq!(hash, hash_bytes(b"hello"));
        assert!(store_blob(&root, b"hello").unwrap() == hash);
        assert_eq!(read_blob(&root, &hash).unwrap().unwrap(), b"hello");
        assert!(read_blob(&root, &hash_bytes(b"missing")).unwrap().is_none());
        let _ = fs::remove_dir_all(&root);
    }
}
