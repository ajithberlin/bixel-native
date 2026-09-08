use bixel_ai::image::{self, RgbaImage};

fn pixel(r: u8, g: u8, b: u8, a: u8) -> [u8; 4] {
    [r, g, b, a]
}

#[test]
fn png_roundtrip_preserves_pixels() {
    let mut img = RgbaImage::new(4, 4);
    img.set_pixel(0, 0, pixel(255, 0, 0, 255));
    img.set_pixel(3, 3, pixel(0, 255, 0, 128));
    let bytes = image::encode_png(&img).unwrap();
    assert!(bytes.len() > 8);
    let decoded = image::decode_png(&bytes).unwrap();
    assert_eq!(decoded.width, 4);
    assert_eq!(decoded.height, 4);
    assert_eq!(decoded.pixel(0, 0), pixel(255, 0, 0, 255));
    assert_eq!(decoded.pixel(3, 3), pixel(0, 255, 0, 128));
}

#[test]
fn quantize_reduces_colors() {
    // 4 distinct colors
    let mut img = RgbaImage::new(2, 2);
    img.set_pixel(0, 0, pixel(255, 0, 0, 255));
    img.set_pixel(1, 0, pixel(0, 255, 0, 255));
    img.set_pixel(0, 1, pixel(0, 0, 255, 255));
    img.set_pixel(1, 1, pixel(255, 255, 255, 255));

    let out = image::quantize(&img, 2);
    let mut colors = std::collections::HashSet::new();
    for i in (0..out.data.len()).step_by(4) {
        if out.data[i + 3] != 0 {
            colors.insert((out.data[i], out.data[i + 1], out.data[i + 2]));
        }
    }
    assert!(colors.len() <= 2, "expected <=2 colors, got {}", colors.len());
}

#[test]
fn quantize_keeps_fewer_colors_unchanged() {
    let mut img = RgbaImage::new(2, 1);
    img.set_pixel(0, 0, pixel(255, 0, 0, 255));
    img.set_pixel(1, 0, pixel(0, 255, 0, 255));
    let out = image::quantize(&img, 4);
    assert_eq!(out.pixel(0, 0), pixel(255, 0, 0, 255));
    assert_eq!(out.pixel(1, 0), pixel(0, 255, 0, 255));
}

#[test]
fn compress_to_bits_maps_bit_depth() {
    let mut img = RgbaImage::new(4, 4);
    for y in 0..4 {
        for x in 0..4 {
            img.set_pixel(x, y, pixel((x * 60) as u8, (y * 60) as u8, 128, 255));
        }
    }
    let out = image::compress_to_bits(&img, 1);
    let mut colors = std::collections::HashSet::new();
    for i in (0..out.data.len()).step_by(4) {
        colors.insert((out.data[i], out.data[i + 1], out.data[i + 2]));
    }
    assert!(colors.len() <= 2, "1-bit should map to <=2 colors, got {}", colors.len());
}

#[test]
fn remove_background_strips_border_region() {
    // 4x4 image: white border, red 2x2 center.
    let mut img = RgbaImage::new(4, 4);
    for y in 0..4 {
        for x in 0..4 {
            img.set_pixel(x, y, pixel(255, 255, 255, 255));
        }
    }
    img.set_pixel(1, 1, pixel(255, 0, 0, 255));
    img.set_pixel(2, 1, pixel(255, 0, 0, 255));
    img.set_pixel(1, 2, pixel(255, 0, 0, 255));
    img.set_pixel(2, 2, pixel(255, 0, 0, 255));

    let out = image::remove_background(&img, 16.0);
    assert_eq!(out.pixel(0, 0)[3], 0, "corner should be transparent");
    assert_eq!(out.pixel(3, 3)[3], 0, "corner should be transparent");
    assert_eq!(out.pixel(1, 1), pixel(255, 0, 0, 255), "center stays");
}

#[test]
fn slice_grid_divides_into_frames() {
    let mut img = RgbaImage::new(4, 4);
    // top-left red, top-right green, bottom-left blue, bottom-right white
    img.set_pixel(0, 0, pixel(255, 0, 0, 255));
    img.set_pixel(2, 0, pixel(0, 255, 0, 255));
    img.set_pixel(0, 2, pixel(0, 0, 255, 255));
    img.set_pixel(2, 2, pixel(255, 255, 255, 255));

    let frames = image::slice_grid(&img, 2, 2);
    assert_eq!(frames.len(), 4);
    assert_eq!(frames[0].pixel(0, 0), pixel(255, 0, 0, 255));
    assert_eq!(frames[1].pixel(0, 0), pixel(0, 255, 0, 255));
    assert_eq!(frames[2].pixel(0, 0), pixel(0, 0, 255, 255));
    assert_eq!(frames[3].pixel(0, 0), pixel(255, 255, 255, 255));
}
