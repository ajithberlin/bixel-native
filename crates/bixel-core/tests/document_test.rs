use bixel_core::color::Rgba;
use bixel_core::document::{AsepriteDoc, BlendMode};

fn rgba(r: u8, g: u8, b: u8, a: u8) -> Rgba {
    Rgba::new(r, g, b, a)
}

#[test]
fn new_doc_has_one_frame_layer_cel() {
    let doc = AsepriteDoc::new(32, 32, &[]);
    assert_eq!(doc.width, 32);
    assert_eq!(doc.height, 32);
    assert_eq!(doc.frames.len(), 1);
    assert_eq!(doc.layers.len(), 1);
    assert_eq!(doc.layers[0].cels.len(), 1);
    assert_eq!(doc.frames[0].duration_ms, 125);
}

#[test]
fn set_and_get_pixel_roundtrip() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    doc.set_pixel(0, 0, 3, 4, rgba(255, 128, 64, 200));
    assert_eq!(doc.get_pixel(0, 0, 3, 4), rgba(255, 128, 64, 200));
    // Out of bounds returns transparent.
    assert_eq!(doc.get_pixel(0, 0, 99, 99), Rgba::TRANSPARENT);
}

#[test]
fn add_frame_creates_independent_layer_stack() {
    let mut doc = AsepriteDoc::new(4, 4, &[]);
    doc.add_layer(Some("bg"));
    doc.add_frame(200);
    assert_eq!(doc.frames.len(), 2);
    // Frame 0 keeps its two layers; frame 1 gets a single fresh layer.
    assert_eq!(doc.frame_layers(0).len(), 2);
    assert_eq!(doc.frame_layers(1).len(), 1);
    assert_eq!(doc.layers.len(), 3);
    // Every layer tracks every frame slot for storage compatibility.
    for layer in &doc.layers {
        assert_eq!(layer.cels.len(), 2);
    }
    // Existing layers have no cel on the new frame.
    assert!(doc.layers[0].cels[1].is_none());
    assert_eq!(doc.frames[1].duration_ms, 200);
}

#[test]
fn remove_frame_adjusts_tags() {
    let mut doc = AsepriteDoc::new(4, 4, &[]);
    doc.add_frame(125);
    doc.add_frame(125);
    doc.add_tag("walk", 1, 2, "#ffaa00");
    doc.remove_frame(0);
    // tag was [1,2] over 3 frames -> after removing frame 0 it's [0,1].
    assert_eq!(doc.tags[0].from, 0);
    assert_eq!(doc.tags[0].to, 1);
}

#[test]
fn undo_redo_restores_state() {
    let mut doc = AsepriteDoc::new(4, 4, &[]);
    doc.snapshot();
    doc.set_pixel(0, 0, 1, 1, rgba(255, 0, 0, 255));
    assert_eq!(doc.get_pixel(0, 0, 1, 1).r, 255);
    assert!(doc.undo());
    assert_eq!(doc.get_pixel(0, 0, 1, 1).a, 0);
    assert!(doc.redo());
    assert_eq!(doc.get_pixel(0, 0, 1, 1).r, 255);
}

#[test]
fn resize_preserves_pixels() {
    let mut doc = AsepriteDoc::new(4, 4, &[]);
    doc.set_pixel(0, 0, 0, 0, rgba(1, 2, 3, 4));
    doc.resize(8, 8);
    assert_eq!(doc.get_pixel(0, 0, 0, 0), rgba(1, 2, 3, 4));
    assert_eq!(doc.get_pixel(0, 0, 7, 7), Rgba::TRANSPARENT);
}

#[test]
fn composite_flat_layer() {
    let mut doc = AsepriteDoc::new(2, 2, &[]);
    doc.set_pixel(0, 0, 0, 0, rgba(10, 20, 30, 255));
    let out = doc.composite_frame(0);
    assert_eq!(out[0], 10);
    assert_eq!(out[1], 20);
    assert_eq!(out[2], 30);
    assert_eq!(out[3], 255);
}

#[test]
fn composite_hidden_layer_skipped() {
    let mut doc = AsepriteDoc::new(2, 2, &[]);
    doc.add_layer(Some("hidden"));
    doc.set_pixel(1, 0, 0, 0, rgba(200, 200, 200, 255));
    doc.layers[1].visible = false;
    let out = doc.composite_frame(0);
    assert_eq!(out[3], 0);
}

#[test]
fn composite_multiply_blend() {
    let mut doc = AsepriteDoc::new(1, 1, &[]);
    doc.set_pixel(0, 0, 0, 0, rgba(200, 200, 200, 255));
    doc.add_layer(Some("m"));
    doc.layers[1].blend_mode = BlendMode::Multiply;
    doc.set_pixel(1, 0, 0, 0, rgba(128, 128, 128, 255));
    let out = doc.composite_frame(0);
    // 200 * 128 / 255 == 100
    assert_eq!(out[0], 100);
}

#[test]
fn blend_mode_parsing() {
    assert_eq!(BlendMode::from_str("Addition"), BlendMode::Addition);
    assert_eq!(BlendMode::from_str("add"), BlendMode::Addition);
    assert_eq!(BlendMode::from_str("bogus"), BlendMode::Normal);
    assert_eq!(BlendMode::from_str("Screen"), BlendMode::Screen);
}

#[test]
fn draw_stroke_single_pixel() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    doc.draw_stroke(0, 0, &[(2, 2)], rgba(255, 0, 0, 255), 0);
    assert_eq!(doc.get_pixel(0, 0, 2, 2), rgba(255, 0, 0, 255));
    assert_eq!(doc.get_pixel(0, 0, 3, 3), Rgba::TRANSPARENT);
}

#[test]
fn draw_stroke_line_connects_endpoints() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    doc.draw_stroke(0, 0, &[(0, 0), (4, 0)], rgba(255, 255, 255, 255), 0);
    assert_eq!(doc.get_pixel(0, 0, 0, 0).a, 255);
    assert_eq!(doc.get_pixel(0, 0, 4, 0).a, 255);
    assert_eq!(doc.get_pixel(0, 0, 2, 0).a, 255);
}

#[test]
fn draw_stroke_brush_radius() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    doc.draw_stroke(0, 0, &[(3, 3)], rgba(0, 0, 255, 255), 1);
    // radius 1 (single pixel plus, actually a 1px dot)
    assert_eq!(doc.get_pixel(0, 0, 3, 3), rgba(0, 0, 255, 255));
}

#[test]
fn flood_fill_bounded_region() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    // Draw a vertical wall at x=4 from y=0..=7.
    for y in 0..8 {
        doc.set_pixel(0, 0, 4, y, rgba(255, 255, 255, 255));
    }
    let changed = doc.flood_fill(0, 0, 0, 0, rgba(255, 0, 0, 255));
    // Fills x=0..3 (4 columns * 8 rows = 32).
    assert_eq!(changed, 32);
    assert_eq!(doc.get_pixel(0, 0, 0, 0), rgba(255, 0, 0, 255));
    assert_eq!(doc.get_pixel(0, 0, 3, 7), rgba(255, 0, 0, 255));
    // Wall untouched.
    assert_eq!(doc.get_pixel(0, 0, 4, 4), rgba(255, 255, 255, 255));
}

#[test]
fn flood_fill_within_selection_bounds_does_not_escape() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    // A closed square leaves a 3x3 interior at x/y 3..6. The selection is
    // deliberately tighter than the canvas so a fill must respect both the
    // drawn boundary and the editor's selection bounds.
    for x in 2..=6 {
        doc.set_pixel(0, 0, x, 2, rgba(255, 255, 255, 255));
        doc.set_pixel(0, 0, x, 6, rgba(255, 255, 255, 255));
    }
    for y in 2..=6 {
        doc.set_pixel(0, 0, 2, y, rgba(255, 255, 255, 255));
        doc.set_pixel(0, 0, 6, y, rgba(255, 255, 255, 255));
    }

    let changed = doc.flood_fill_within(0, 0, 4, 4, rgba(255, 0, 0, 255), 3, 3, 6, 6);

    assert_eq!(changed, 9);
    assert_eq!(doc.get_pixel(0, 0, 4, 4), rgba(255, 0, 0, 255));
    assert_eq!(doc.get_pixel(0, 0, 1, 1), Rgba::TRANSPARENT);
    assert_eq!(doc.get_pixel(0, 0, 6, 4), rgba(255, 255, 255, 255));
}

#[test]
fn legacy_global_layers_expand_to_per_frame_stacks() {
    // A pre-per-frame (schema-1) document: one layer with a cel on every frame.
    let json = serde_json::json!({
        "schema": 1,
        "document": {
            "width": 1, "height": 1, "palette": [],
            "frames": [
                {"index": 0, "duration_ms": 100},
                {"index": 1, "duration_ms": 100}
            ],
            "tags": [],
            "layers": [{
                "name": "Shared",
                "visible": true,
                "locked": false,
                "opacity": 1.0,
                "blend_mode": "Normal",
                "cels": [
                    {"layer_index":0,"frame_index":0,"width":1,"height":1,"data":[1,0,0,255]},
                    {"layer_index":0,"frame_index":1,"width":1,"height":1,"data":[2,0,0,255]}
                ]
            }]
        }
    }).to_string();

    let doc = AsepriteDoc::from_json(&json).unwrap();
    // Each frame gets its own copy so the layers panel stays frame-accurate.
    assert_eq!(doc.frame_layers(0).len(), 1);
    assert_eq!(doc.frame_layers(1).len(), 1);
    let first = doc.frame_layers(0)[0];
    let second = doc.frame_layers(1)[0];
    assert_eq!(doc.layer_frame(first), Some(0));
    assert_eq!(doc.layer_frame(second), Some(1));
    assert_eq!(doc.get_pixel(first, 0, 0, 0).r, 1);
    assert_eq!(doc.get_pixel(second, 1, 0, 0).r, 2);
    // Legacy content still composites identically per frame.
    assert_eq!(doc.composite_frame(0)[0], 1);
    assert_eq!(doc.composite_frame(1)[0], 2);
}

#[test]
fn reorder_frame_preserves_layer_stacks_timing_and_undo() {
    let mut doc = AsepriteDoc::new(2, 2, &[]);
    doc.add_layer(Some("overlay"));
    doc.add_frame(250);
    doc.add_frame(500);
    // A distinct marker on each frame's own top layer.
    for frame in 0..3 {
        let top = *doc.frame_layers(frame).last().unwrap();
        doc.set_pixel(top, frame, 0, 0, rgba((frame + 1) as u8, 0, 0, 255));
    }
    let layer_count = doc.layers.len();
    doc.snapshot();
    doc.reorder_frame(0, 2);
    assert_eq!(doc.frames.iter().map(|f| f.duration_ms).collect::<Vec<_>>(), vec![250, 500, 125]);
    for (index, frame) in doc.frames.iter().enumerate() {
        assert_eq!(frame.index, index);
    }
    // The old frame 0 stack (marker 1) now lives at frame 2.
    let moved = *doc.frame_layers(2).last().unwrap();
    assert_eq!(doc.layer_frame(moved), Some(2));
    assert_eq!(doc.get_pixel(moved, 2, 0, 0).r, 1);
    // Frame 0 now holds the old frame 1 stack (marker 2).
    let now_first = *doc.frame_layers(0).last().unwrap();
    assert_eq!(doc.get_pixel(now_first, 0, 0, 0).r, 2);
    assert_eq!(doc.layers.len(), layer_count);
    assert!(doc.undo());
    let original_first = *doc.frame_layers(0).last().unwrap();
    assert_eq!(doc.get_pixel(original_first, 0, 0, 0).r, 1);
    assert!(doc.redo());
    doc.reorder_frame(2, 0);
    assert_eq!(doc.frames.iter().map(|f| f.duration_ms).collect::<Vec<_>>(), vec![125, 250, 500]);
    doc.reorder_frame(0, 99);
    doc.reorder_frame(99, 0);
    doc.reorder_frame(0, 0);
    assert_eq!(doc.frames.len(), 3);
}
