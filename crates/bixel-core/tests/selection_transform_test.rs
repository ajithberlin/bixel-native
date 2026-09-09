use bixel_core::color::Rgba;
use bixel_core::document::AsepriteDoc;

#[test]
fn transform_moves_selection_and_is_undoable() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    doc.set_pixel(0, 0, 1, 1, Rgba { r: 255, g: 0, b: 0, a: 255 });
    doc.snapshot();
    doc.transform_rect(0, 0, 1, 1, 1, 1, 4, 3, 1, 1, 0).unwrap();
    assert_eq!(doc.get_pixel(0, 0, 1, 1).a, 0);
    assert_eq!(doc.get_pixel(0, 0, 4, 3).r, 255);
    assert!(doc.undo());
    assert_eq!(doc.get_pixel(0, 0, 1, 1).r, 255);
}

#[test]
fn transform_scales_with_nearest_neighbor() {
    let mut doc = AsepriteDoc::new(8, 8, &[]);
    doc.set_pixel(0, 0, 1, 1, Rgba { r: 1, g: 2, b: 3, a: 255 });
    doc.set_pixel(0, 0, 2, 1, Rgba { r: 4, g: 5, b: 6, a: 255 });
    doc.transform_rect(0, 0, 1, 1, 2, 1, 3, 3, 4, 2, 0).unwrap();
    assert_eq!(doc.get_pixel(0, 0, 3, 3).r, 1);
    assert_eq!(doc.get_pixel(0, 0, 6, 4).r, 4);
}
