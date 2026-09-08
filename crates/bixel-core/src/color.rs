//! Color primitives and blend math shared by the document compositor and
//! palette engine.

/// An 8-bit RGBA color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const TRANSPARENT: Rgba = Rgba { r: 0, g: 0, b: 0, a: 0 };

    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {
        Rgba { r, g, b, a }
    }

    /// Euclidean distance in RGBA space (0 for identical colors).
    pub fn distance(self, other: Rgba) -> f32 {
        let dr = self.r as f32 - other.r as f32;
        let dg = self.g as f32 - other.g as f32;
        let db = self.b as f32 - other.b as f32;
        let da = self.a as f32 - other.a as f32;
        (dr * dr + dg * dg + db * db + da * da).sqrt()
    }

    pub fn to_hex(self) -> String {
        format!("#{:02x}{:02x}{:02x}{:02x}", self.r, self.g, self.b, self.a)
    }
}

impl From<[u8; 4]> for Rgba {
    fn from(v: [u8; 4]) -> Self {
        Rgba { r: v[0], g: v[1], b: v[2], a: v[3] }
    }
}

impl From<Rgba> for [u8; 4] {
    fn from(v: Rgba) -> Self {
        [v.r, v.g, v.b, v.a]
    }
}

fn clamp_byte(v: f64) -> u8 {
    (v.round() as i64).clamp(0, 255) as u8
}

/// RGB [0..255] to HSV (h: 0..360, s: 0..1, v: 0..1).
pub fn rgb_to_hsv(r: u8, g: u8, b: u8) -> (f64, f64, f64) {
    let rn = r as f64 / 255.0;
    let gn = g as f64 / 255.0;
    let bn = b as f64 / 255.0;
    let max = rn.max(gn).max(bn);
    let min = rn.min(gn).min(bn);
    let delta = max - min;

    let h = if delta == 0.0 {
        0.0
    } else if max == rn {
        60.0 * (((gn - bn) / delta + 6.0) % 6.0)
    } else if max == gn {
        60.0 * ((bn - rn) / delta + 2.0)
    } else {
        60.0 * ((rn - gn) / delta + 4.0)
    };
    let h = ((h % 360.0) + 360.0) % 360.0;
    let s = if max == 0.0 { 0.0 } else { delta / max };
    (h, s, max)
}

/// HSV (h: 0..360, s: 0..1, v: 0..1) to RGB [0..255].
pub fn hsv_to_rgb(h: f64, s: f64, v: f64) -> (u8, u8, u8) {
    let hue = ((h % 360.0) + 360.0) % 360.0;
    let sat = s.clamp(0.0, 1.0);
    let val = v.clamp(0.0, 1.0);

    let c = val * sat;
    let h_div_60 = hue / 60.0;
    let x = c * (1.0 - ((h_div_60 % 2.0) - 1.0).abs());
    let m = val - c;

    let (r1, g1, b1) = if h_div_60 < 1.0 {
        (c, x, 0.0)
    } else if h_div_60 < 2.0 {
        (x, c, 0.0)
    } else if h_div_60 < 3.0 {
        (0.0, c, x)
    } else if h_div_60 < 4.0 {
        (0.0, x, c)
    } else if h_div_60 < 5.0 {
        (x, 0.0, c)
    } else {
        (c, 0.0, x)
    };

    (
        clamp_byte((r1 + m) * 255.0),
        clamp_byte((g1 + m) * 255.0),
        clamp_byte((b1 + m) * 255.0),
    )
}
