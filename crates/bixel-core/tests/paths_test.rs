use std::fs;
use std::path::PathBuf;

use bixel_core::paths::{safe_resolve, to_rel, PathJailError};
use bixel_core::project;

fn temp_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!("bixel-paths-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    path.canonicalize().unwrap()
}

#[test]
fn safe_resolve_inside_root() {
    let root = temp_dir();
    let resolved = safe_resolve("assets/foo.png", &root).unwrap();
    assert_eq!(resolved, root.join("assets/foo.png"));
}

#[test]
fn safe_resolve_rejects_parent_traversal() {
    let root = temp_dir();
    let result = safe_resolve("../secret.png", &root);
    assert!(matches!(result, Err(PathJailError(_))));
}

#[test]
fn safe_resolve_strips_leading_slash() {
    // A leading slash is stripped and treated as relative (matching the Python
    // jail), so an absolute-looking path can never escape the root.
    let root = temp_dir();
    let resolved = safe_resolve("/assets/foo.png", &root).unwrap();
    assert_eq!(resolved, root.join("assets/foo.png"));
}

#[test]
fn safe_resolve_rejects_null_byte() {
    let root = temp_dir();
    let result = safe_resolve("foo\0bar", &root);
    assert!(matches!(result, Err(PathJailError(_))));
}

#[test]
fn to_rel_roundtrips() {
    let root = temp_dir();
    let resolved = safe_resolve("a/b.png", &root).unwrap();
    fs::create_dir_all(root.join("a")).unwrap();
    fs::write(&resolved, b"x").unwrap();
    let rel = to_rel(&resolved, &root).unwrap();
    assert_eq!(rel, "a/b.png");
}

#[test]
fn symlink_escape_is_rejected() {
    let root = temp_dir();
    let outside = std::env::temp_dir().join(format!("bixel-outside-{}", std::process::id()));
    let _ = fs::remove_dir_all(&outside);
    fs::create_dir_all(&outside).unwrap();
    // Symlink `root/link` -> outside directory.
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        let result = safe_resolve("link/secret.txt", &root);
        assert!(matches!(result, Err(PathJailError(_))));
    }
}

#[test]
fn slugify_normalizes() {
    assert_eq!(project::slugify("Hello, World!"), "hello-world");
    assert_eq!(project::slugify("  "), "project");
    assert_eq!(project::slugify("a--b"), "a-b");
}
