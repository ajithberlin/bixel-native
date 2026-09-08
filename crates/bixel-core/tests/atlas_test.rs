use bixel_core::atlas;
use serde_json::json;

#[test]
fn valid_atlas_passes() {
    let data = json!({
        "image": "sheet.png",
        "size": { "w": 64, "h": 64 },
        "actions": {
            "idle": {
                "frames": [
                    { "x": 0, "y": 0, "w": 32, "h": 32 }
                ]
            }
        }
    });
    assert!(atlas::validate(&data, Some((64, 64))).is_ok());
}

#[test]
fn missing_image_fails() {
    let data = json!({ "actions": { "a": { "frames": [{"x":0,"y":0,"w":1,"h":1}] } } });
    assert!(atlas::validate(&data, None).is_err());
}

#[test]
fn absolute_image_path_fails() {
    let data = json!({
        "image": "/etc/passwd",
        "actions": { "a": { "frames": [{"x":0,"y":0,"w":1,"h":1}] } }
    });
    assert!(atlas::validate(&data, None).is_err());
}

#[test]
fn size_must_match_image() {
    let data = json!({
        "image": "sheet.png",
        "size": { "w": 32, "h": 32 },
        "actions": { "a": { "frames": [{"x":0,"y":0,"w":1,"h":1}] } }
    });
    assert!(atlas::validate(&data, Some((64, 64))).is_err());
}

#[test]
fn frame_out_of_bounds_fails() {
    let data = json!({
        "image": "sheet.png",
        "size": { "w": 64, "h": 64 },
        "actions": { "a": { "frames": [{"x":60,"y":0,"w":32,"h":32}] } }
    });
    assert!(atlas::validate(&data, Some((64, 64))).is_err());
}

#[test]
fn empty_actions_fails() {
    let data = json!({ "image": "sheet.png", "actions": {} });
    assert!(atlas::validate(&data, None).is_err());
}

#[test]
fn zero_size_cell_fails() {
    let data = json!({
        "image": "sheet.png",
        "actions": { "a": { "frames": [{"x":0,"y":0,"w":0,"h":1}] } }
    });
    assert!(atlas::validate(&data, None).is_err());
}
