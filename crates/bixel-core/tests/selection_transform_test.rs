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

#[test]
fn transform_supports_arbitrary_rotation_angles() {
    let mut doc = AsepriteDoc::new(16, 16, &[]);
    for y in 4..6 {
        for x in 4..7 {
            doc.set_pixel(0, 0, x, y, Rgba { r: 255, g: 255, b: 255, a: 255 });
        }
    }
    doc.transform_rect_angle(0, 0, 4, 4, 3, 2, 8, 8, 5, 4, std::f64::consts::FRAC_PI_4).unwrap();
    assert_eq!(doc.get_pixel(0, 0, 4, 4).a, 0);
    let mut remaining = 0;
    for y in 0..16 {
        for x in 0..16 {
            if doc.get_pixel(0, 0, x, y).a > 0 { remaining += 1; }
        }
    }
    assert!(remaining > 0);
}
