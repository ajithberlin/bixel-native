//! Preset palettes and color conversion (port of `web/aseprite/palette.js`).

use crate::color::Rgba;

/// Dawnbringer 32 (DB32) — the world-standard 32-color pixel-art palette.
pub const DB32: [&str; 32] = [
    "#000000", "#222034", "#45283c", "#663931", "#8f563b", "#df7126", "#d9a066", "#eec39a",
    "#fbf236", "#99e550", "#6abe30", "#37946e", "#4b692f", "#524b24", "#323c39", "#3f3f74",
    "#306082", "#5b6ee1", "#639bff", "#5fcde4", "#cbdbfc", "#ffffff", "#9badb7", "#847e87",
    "#696a6a", "#595652", "#76428a", "#ac3232", "#d95763", "#d77bba", "#8f974a", "#8a6f30",
];

/// PICO-8 16-color palette.
pub const PICO8: [&str; 16] = [
    "#000000", "#1d2b53", "#7e2553", "#008751", "#ab5236", "#5f574f", "#c2c3c7", "#fff1e8",
    "#ff004d", "#ffa300", "#ffec27", "#00e436", "#29adff", "#83769c", "#ff77a8", "#ffccaa",
];

/// Game Boy classic 4-color DMG palette.
pub const GAMEBOY: [&str; 4] = ["#081820", "#346856", "#88c070", "#e0f8cf"];

/// Converts a hex color string (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`) to RGBA.
/// Alpha defaults to 255 when unspecified.
pub fn hex_to_rgba(hex: &str) -> Rgba {
    let clean = hex.trim().strip_prefix('#').unwrap_or(hex.trim());
    let parse = |s: &str| -> u8 { u8::from_str_radix(s, 16).unwrap_or(0) };

    match clean.len() {
        3 | 4 => {
            let bytes = clean.as_bytes();
            let r = parse(&format!("{}{}", bytes[0] as char, bytes[0] as char));
            let g = parse(&format!("{}{}", bytes[1] as char, bytes[1] as char));
            let b = parse(&format!("{}{}", bytes[2] as char, bytes[2] as char));
            let a = if clean.len() == 4 {
                parse(&format!("{}{}", bytes[3] as char, bytes[3] as char))
            } else {
                255
            };
            Rgba::new(r, g, b, a)
        }
        6 | 8 => {
            let r = parse(&clean[0..2]);
            let g = parse(&clean[2..4]);
            let b = parse(&clean[4..6]);
            let a = if clean.len() == 8 { parse(&clean[6..8]) } else { 255 };
            Rgba::new(r, g, b, a)
        }
        _ => Rgba::TRANSPARENT,
    }
}

/// Computes Euclidean distance between two colors in RGBA space.
pub fn color_distance(c1: Rgba, c2: Rgba) -> f32 {
    c1.distance(c2)
}

/// Finds the closest color in `palette` to `color`, returning its index.
pub fn find_nearest_index(color: Rgba, palette: &[Rgba]) -> Option<usize> {
    if palette.is_empty() {
        return None;
    }
    let mut best = 0;
    let mut min_d = f32::INFINITY;
    for (i, &p) in palette.iter().enumerate() {
        let d = color_distance(color, p);
        if d < min_d {
            min_d = d;
            best = i;
            if d == 0.0 {
                break;
            }
        }
    }
    Some(best)
}

/// Parses a palette of hex strings into `Rgba`.
pub fn parse_palette(palette: &[&str]) -> Vec<Rgba> {
    palette.iter().map(|h| hex_to_rgba(h)).collect()
}
