use bixel_core::{document::AsepriteDoc, storage};
use serde_json::json;

#[test]
fn project_storage_is_durable_and_confined() {
    let root = std::env::temp_dir().join(format!("bixel-storage-{}", std::process::id()));
    let root = root.join("nested/projects");
    let created = storage::request(&root, &json!({"op":"create", "id":"one", "name":"My Project"})).unwrap();
    assert_eq!(created["name"], "My Project");
    assert!(storage::request(&root, &json!({"op":"create", "id":"one", "name":"Other"})).is_err());
    storage::request(&root, &json!({"op":"write", "path":"one/.studio/cache/ai/code.swift", "text":"let x = 1"})).unwrap();
    let text = storage::request(&root, &json!({"op":"read", "path":"one/.studio/cache/ai/code.swift"})).unwrap();
    assert_eq!(text, "let x = 1");
    assert!(!storage::write_new(&root, "one/.studio/cache/ai/code.swift", b"replacement").unwrap());
    assert_eq!(storage::request(&root, &json!({"op":"read", "path":"one/.studio/cache/ai/code.swift"})).unwrap(), "let x = 1");
    assert!(storage::write_new(&root, "one/.studio/cache/ai/second.swift", b"new output").unwrap());
    assert!(storage::request(&root, &json!({"op":"write", "path":"../escape", "text":"bad"})).is_err());
    assert_eq!(storage::request(&root, &json!({"op":"list"})).unwrap().as_array().unwrap().len(), 1);
    #[cfg(unix)] {
        std::os::unix::fs::symlink(std::env::temp_dir(), root.join("outside")).unwrap();
        assert!(storage::request(&root, &json!({"op":"write", "path":"outside/escape", "text":"bad"})).is_err());
    }
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn document_roundtrip_preserves_editable_layers_and_frames() {
    let mut doc = AsepriteDoc::new(4, 3, &[]);
    doc.add_frame(250);
    doc.add_layer(Some("Shadow"));
    doc.layers[1].visible = false;
    doc.set_pixel(1, 1, 2, 1, bixel_core::Rgba {r: 10, g: 20, b: 30, a: 255});
    let saved = doc.to_json().unwrap();
    let mut restored = AsepriteDoc::from_json(&saved).unwrap();
    assert_eq!(restored.layers[1].name, "Shadow");
    assert!(!restored.layers[1].visible);
    assert_eq!(restored.frames[1].duration_ms, 250);
    assert_eq!(restored.get_pixel(1, 1, 2, 1).g, 20);
    assert_eq!(restored.composite_frame(1), doc.composite_frame(1));
    let invalid = saved.replace("\"width\":4", "\"width\":0");
    assert!(AsepriteDoc::from_json(&invalid).is_err());
}
