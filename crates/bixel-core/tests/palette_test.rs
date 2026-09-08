use bixel_core::palette;

#[test]
fn hex_to_rgba_full() {
    assert_eq!(palette::hex_to_rgba("#ff8000ff").r, 255);
    assert_eq!(palette::hex_to_rgba("#ff8000ff").g, 128);
    assert_eq!(palette::hex_to_rgba("#ff8000ff").b, 0);
    assert_eq!(palette::hex_to_rgba("#ff8000ff").a, 255);
}

#[test]
fn hex_to_rgba_short() {
    let c = palette::hex_to_rgba("#f00");
    assert_eq!((c.r, c.g, c.b, c.a), (255, 0, 0, 255));
}

#[test]
fn hex_to_rgba_no_alpha_defaults_255() {
    let c = palette::hex_to_rgba("#123456");
    assert_eq!(c.a, 255);
}

#[test]
fn nearest_color_finds_exact_match() {
    let p = palette::parse_palette(&palette::DB32);
    let target = palette::hex_to_rgba("#df7126");
    let idx = palette::find_nearest_index(target, &p).unwrap();
    assert_eq!(palette::DB32[idx], "#df7126");
}

#[test]
fn color_distance_identical_is_zero() {
    let c1 = palette::hex_to_rgba("#00ff00");
    let c2 = palette::hex_to_rgba("#00ff00");
    assert_eq!(palette::color_distance(c1, c2), 0.0);
}

#[test]
fn color_distance_symmetric() {
    let a = palette::hex_to_rgba("#111111");
    let b = palette::hex_to_rgba("#ffffff");
    assert_eq!(palette::color_distance(a, b), palette::color_distance(b, a));
}

#[test]
fn hsv_roundtrip() {
    let (h, s, v) = bixel_core::color::rgb_to_hsv(255, 0, 0);
    assert!((h - 0.0).abs() < 0.001);
    assert!((s - 1.0).abs() < 0.001);
    let (r, g, b) = bixel_core::color::hsv_to_rgb(h, s, v);
    assert_eq!((r, g, b), (255, 0, 0));
}
