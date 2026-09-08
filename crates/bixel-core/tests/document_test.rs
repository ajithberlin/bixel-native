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
fn add_frame_creates_cels_on_all_layers() {
    let mut doc = AsepriteDoc::new(4, 4, &[]);
    doc.add_layer(Some("bg"));
    doc.add_frame(200);
    assert_eq!(doc.frames.len(), 2);
    assert_eq!(doc.layers.len(), 2);
    assert_eq!(doc.layers[0].cels.len(), 2);
    assert_eq!(doc.layers[1].cels.len(), 2);
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
