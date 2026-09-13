//! Keep the embedded skill packages in sync with the binary.
//!
//! `skill_install.rs` embeds the workspace `skills/` tree with `include_dir!`.
//! That macro is evaluated at compile time, but Cargo has no idea the sources
//! live outside the crate, so adding or editing a skill would otherwise leave
//! the previously compiled copy embedded and silently skip installing the new
//! one. Emitting `rerun-if-changed` for every entry under `skills/` makes Cargo
//! rebuild `bixel-ai` whenever a skill is added, removed, or edited.

use std::path::Path;

fn main() {
    let skills = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills");
    // Cargo scans a watched directory recursively, but emitting every entry
    // also covers older Cargo versions and makes file additions unambiguous.
    println!("cargo:rerun-if-changed={}", skills.display());
    walk(&skills);
}

fn walk(path: &Path) {
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        println!("cargo:rerun-if-changed={}", path.display());
        if path.is_dir() {
            walk(&path);
        }
    }
}
