use std::fs;
use std::path::PathBuf;

use bixel_core::project;

fn isolated_home() -> PathBuf {
    let path = std::env::temp_dir().join(format!("bixel-project-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn project_lifecycle() {
    let home = isolated_home();
    std::env::set_var("BIXEL_STATE_DIR", home.to_string_lossy().as_ref());
    std::env::set_var("BIXEL_PROJECTS_DIR", home.join("projects").to_string_lossy().as_ref());

    let created = project::create("My Game", "A test project").unwrap();
    assert_eq!(created.name, "My Game");
    assert_eq!(created.id, "my-game");
    assert!(created.path().is_dir());
    assert!(created.path().join("project.json").is_file());
    assert!(created.path().join(".studio").is_dir());

    let loaded = project::load(&created.id).unwrap();
    assert_eq!(loaded.name, "My Game");

    let listed = project::list_projects(10);
    assert!(listed.iter().any(|p| p.get("id").and_then(|v| v.as_str()) == Some("my-game")));

    project::delete(&created.id).unwrap();
    assert!(!created.path().exists());
}

#[test]
fn create_rejects_empty_name() {
    assert!(project::create("  ", "").is_err());
}

#[test]
fn load_unknown_project_errors() {
    assert!(project::load("does-not-exist").is_err());
}

#[test]
fn slugify_collapses_and_strips() {
    assert_eq!(project::slugify("Hello,   World!"), "hello-world");
    assert_eq!(project::slugify("---"), "project");
}
