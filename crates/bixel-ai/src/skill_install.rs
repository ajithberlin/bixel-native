//! Install the bundled agent skills into goose's global skills directory and
//! keep their Python dependencies available.
//!
//! The workspace `skills/` packages (`SKILL.md` + `scripts/`) are embedded in
//! the binary with `include_dir!` and copied into `~/.agents/skills`, which is
//! the canonical writable location goose discovers skills from. goose's own
//! `skills` platform extension then lists them to the agent and serves
//! `load_skill`, so the agent runs them with its shell tool — no per-skill Rust
//! wiring.
//!
//! Python-backed skills declare a `requirements.txt`; on first run we create a
//! managed virtualenv and `pip install` the union of those requirements. goose's
//! shell tool replaces `PATH` with the user's login-shell PATH, so the assistant
//! system prompt points the agent at the venv interpreter explicitly (see
//! `AssistantSession.skillPythonPath`).

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use include_dir::{include_dir, Dir};

static BUNDLED_SKILLS: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/../../skills");

/// goose's canonical writable global skills directory (`~/.agents/skills`).
pub fn global_skills_dir() -> Option<PathBuf> {
    home_dir().map(|home| home.join(".agents").join("skills"))
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Managed virtualenv holding the skills' Python dependencies.
pub fn venv_dir() -> Option<PathBuf> {
    home_dir().map(|home| home.join("Library/Application Support/Bixel/skill-venv"))
}

/// Names of every bundled skill (a directory containing `SKILL.md`).
pub fn bundled_skill_names() -> Vec<String> {
    BUNDLED_SKILLS
        .dirs()
        .filter(|dir| has_skill_manifest(dir))
        .filter_map(|dir| dir.path().file_name().and_then(|n| n.to_str()).map(String::from))
        .collect()
}

/// `include_dir` entry paths are relative to the include root, so a skill's
/// `SKILL.md` appears as `<skill>/SKILL.md` — match on the file name.
fn has_skill_manifest(dir: &Dir<'_>) -> bool {
    dir.files()
        .any(|file| file.path().file_name().is_some_and(|name| name == "SKILL.md"))
}

/// Copy the bundled skills into `~/.agents/skills` exactly once per process and
/// kick off the (background) Python dependency install. Safe to call from any
/// entry point — app startup, agent construction, or command listing — so the
/// skills exist before goose first discovers them.
pub fn ensure_bundled_installed() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        if let Err(error) = install_bundled() {
            tracing::warn!(%error, "could not install bundled agent skills");
        }
        std::thread::spawn(|| {
            if let Err(error) = ensure_python_deps() {
                tracing::warn!(%error, "could not install skill python dependencies");
            }
        });
    });
}

/// Copy every bundled skill into `~/.agents/skills`, writing only files whose
/// contents changed. Returns the number of skills synced. Filesystem-only and
/// fast, so it is safe to call synchronously at startup.
pub fn install_bundled() -> Result<usize, String> {
    let target_root = global_skills_dir().ok_or("could not determine the home directory")?;
    install_bundled_into(&target_root)
}

/// Copy the bundled skills into an explicit directory (used by tests).
fn install_bundled_into(target_root: &Path) -> Result<usize, String> {
    fs::create_dir_all(target_root).map_err(|e| e.to_string())?;
    let mut count = 0;
    for dir in BUNDLED_SKILLS.dirs() {
        if !has_skill_manifest(dir) {
            continue;
        }
        let Some(name) = dir.path().file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        write_tree(dir, &target_root.join(name))?;
        count += 1;
    }
    Ok(count)
}

/// Recursively mirror an embedded directory into the filesystem.
fn write_tree(dir: &Dir<'_>, target: &Path) -> Result<(), String> {
    fs::create_dir_all(target).map_err(|e| e.to_string())?;
    for entry in dir.entries() {
        let Some(name) = entry.path().file_name() else {
            continue;
        };
        let dest = target.join(name);
        match entry {
            include_dir::DirEntry::Dir(sub) => write_tree(sub, &dest)?,
            include_dir::DirEntry::File(file) => write_if_changed(&dest, file.contents())?,
        }
    }
    Ok(())
}

fn write_if_changed(path: &Path, contents: &[u8]) -> Result<(), String> {
    if let Ok(existing) = fs::read(path) {
        if existing == contents {
            return Ok(());
        }
    }
    fs::write(path, contents).map_err(|e| format!("{}: {e}", path.display()))
}

/// Union of the `requirements.txt` files across the bundled skills only — the
/// user's own installed skills manage their own environments.
fn collected_requirements() -> BTreeSet<String> {
    let mut lines = BTreeSet::new();
    let Some(root) = global_skills_dir() else {
        return lines;
    };
    for name in bundled_skill_names() {
        let req = root.join(&name).join("requirements.txt");
        if let Ok(text) = fs::read_to_string(&req) {
            for line in text.lines() {
                let line = line.trim();
                if !line.is_empty() && !line.starts_with('#') {
                    lines.insert(line.to_string());
                }
            }
        }
    }
    lines
}

/// Prefer the newest Python available: the skill requirements (numpy 2.x,
/// Pillow 12) need 3.10+, while macOS's `/usr/bin/python3` is often older.
fn find_python() -> Option<String> {
    for candidate in ["python3.13", "python3.12", "python3.11", "python3.10", "python3"] {
        let ok = Command::new(candidate)
            .arg("--version")
            .output()
            .map(|output| output.status.success())
            .unwrap_or(false);
        if ok {
            return Some(candidate.to_string());
        }
    }
    None
}

/// Ensure the managed virtualenv has every bundled skill's Python dependency
/// and put it on `PATH`. Idempotent: a fingerprint of the requirement set
/// skips re-installs. Intended to run on a background thread — it can take a
/// while and needs network the first time.
pub fn ensure_python_deps() -> Result<(), String> {
    let requirements = collected_requirements();
    if requirements.is_empty() {
        return Ok(());
    }
    let venv = venv_dir().ok_or("could not determine the home directory")?;
    let python = venv.join("bin").join("python3");
    let marker = venv.join(".bixel-requirements");
    let fingerprint = fingerprint(&requirements);

    if python.is_file() {
        if let Ok(existing) = fs::read_to_string(&marker) {
            if existing.trim() == fingerprint {
                prepend_venv_to_path(&venv);
                return Ok(());
            }
        }
    } else {
        let python_cmd = find_python().ok_or("no python3 interpreter found on PATH")?;
        let status = Command::new(&python_cmd)
            .args(["-m", "venv"])
            .arg(&venv)
            .status()
            .map_err(|e| format!("failed to create python venv: {e}"))?;
        if !status.success() {
            return Err(format!("{python_cmd} -m venv failed"));
        }
    }

    let list_path = venv.join("requirements.txt");
    let body = requirements.iter().cloned().collect::<Vec<_>>().join("\n");
    fs::write(&list_path, body).map_err(|e| e.to_string())?;
    let status = Command::new(&python)
        .args(["-m", "pip", "install", "--upgrade", "--quiet", "-r"])
        .arg(&list_path)
        .status()
        .map_err(|e| format!("failed to run pip: {e}"))?;
    if !status.success() {
        return Err("pip install of skill requirements failed".into());
    }
    fs::write(&marker, &fingerprint).map_err(|e| e.to_string())?;
    prepend_venv_to_path(&venv);
    Ok(())
}

fn fingerprint(requirements: &BTreeSet<String>) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    requirements.iter().for_each(|requirement| requirement.hash(&mut hasher));
    format!("{:x}", hasher.finish())
}

fn prepend_venv_to_path(venv: &Path) {
    let bin = venv.join("bin");
    let mut paths = vec![bin];
    if let Some(current) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&current));
    }
    if let Ok(joined) = std::env::join_paths(paths) {
        std::env::set_var("PATH", joined);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_skills_are_discoverable() {
        let names = bundled_skill_names();
        assert!(names.iter().any(|n| n == "skill-creator"), "skill-creator must be bundled");
        assert!(names.iter().any(|n| n == "pixel-spritesheet-gen"));
        assert!(names.iter().any(|n| n == "tileset-asset-extender"));
    }

    #[test]
    fn install_copies_skill_manifests_and_nested_scripts() {
        let dir = std::env::temp_dir().join(format!("bixel-skills-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let count = install_bundled_into(&dir).unwrap();
        assert!(count >= 2, "expected the bundled skills to be installed");
        assert!(dir.join("skill-creator/SKILL.md").is_file());
        assert!(dir.join("pixel-spritesheet-gen/scripts/freeform_pack.py").is_file());
        let _ = fs::remove_dir_all(&dir);
    }
}
