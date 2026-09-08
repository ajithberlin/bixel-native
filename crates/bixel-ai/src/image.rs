//! Image primitives: PNG encode/decode plus deterministic pixel operations used
//! by the local (no-network) skills — color quantization and background removal.

use std::io::Cursor;

use crate::error::AiError;

/// A decoded RGBA image.
#[derive(Debug, Clone, PartialEq)]
pub struct RgbaImage {
    pub width: usize,
    pub height: usize,
    /// `width * height * 4` bytes of packed RGBA.
    pub data: Vec<u8>,
}

impl RgbaImage {
    pub fn new(width: usize, height: usize) -> Self {
        RgbaImage { width, height, data: vec![0; width * height * 4] }
    }

    pub fn from_rgba(width: usize, height: usize, data: Vec<u8>) -> Self {
        let mut data = data;
        data.resize(width * height * 4, 0);
        RgbaImage { width, height, data }
    }

    #[inline]
    pub fn pixel(&self, x: usize, y: usize) -> [u8; 4] {
        let i = (y * self.width + x) * 4;
        [self.data[i], self.data[i + 1], self.data[i + 2], self.data[i + 3]]
    }

    #[inline]
    pub fn set_pixel(&mut self, x: usize, y: usize, c: [u8; 4]) {
        let i = (y * self.width + x) * 4;
        self.data[i..i + 4].copy_from_slice(&c);
    }

    /// A transparent image with the same dimensions.
    pub fn blank(width: usize, height: usize) -> Self {
        RgbaImage::new(width, height)
    }
}

/// Encode an RGBA image to a PNG byte buffer.
pub fn encode_png(img: &RgbaImage) -> Result<Vec<u8>, AiError> {
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, img.width as u32, img.height as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header()?;
        writer.write_image_data(&img.data)?;
    }
    Ok(out)
}

/// Decode any supported image format (PNG/JPEG/WebP) into RGBA.
pub fn decode_any(bytes: &[u8]) -> Result<RgbaImage, AiError> {
    let img = image::load_from_memory(bytes).map_err(|e| AiError::Image(e.to_string()))?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Ok(RgbaImage::from_rgba(w as usize, h as usize, rgba.into_raw()))
}

/// Decode a PNG byte buffer into an RGBA image.
pub fn decode_png(bytes: &[u8]) -> Result<RgbaImage, AiError> {
    let decoder = png::Decoder::new(Cursor::new(bytes));
    let mut reader = decoder.read_info()?;
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf)?;
    let data = &buf[..info.buffer_size()];
    match info.color_type {
        png::ColorType::Rgba => Ok(RgbaImage::from_rgba(info.width as usize, info.height as usize, data.to_vec())),
        png::ColorType::Rgb => {
            // Expand RGB -> RGBA.
            let w = info.width as usize;
            let h = info.height as usize;
            let mut rgba = vec![0u8; w * h * 4];
            for y in 0..h {
                for x in 0..w {
                    let src = (y * w + x) * 3;
                    let dst = (y * w + x) * 4;
                    rgba[dst..dst + 3].copy_from_slice(&data[src..src + 3]);
                    rgba[dst + 3] = 255;
                }
            }
            Ok(RgbaImage::from_rgba(w, h, rgba))
        }
        png::ColorType::Grayscale => {
            let w = info.width as usize;
            let h = info.height as usize;
            let mut rgba = vec![0u8; w * h * 4];
            for i in 0..w * h {
                let g = data[i];
                rgba[i * 4] = g;
                rgba[i * 4 + 1] = g;
                rgba[i * 4 + 2] = g;
                rgba[i * 4 + 3] = 255;
            }
            Ok(RgbaImage::from_rgba(w, h, rgba))
        }
        png::ColorType::GrayscaleAlpha => {
            let w = info.width as usize;
            let h = info.height as usize;
            let mut rgba = vec![0u8; w * h * 4];
            for i in 0..w * h {
                let g = data[i * 2];
                let a = data[i * 2 + 1];
                rgba[i * 4] = g;
                rgba[i * 4 + 1] = g;
                rgba[i * 4 + 2] = g;
                rgba[i * 4 + 3] = a;
            }
            Ok(RgbaImage::from_rgba(w, h, rgba))
        }
        other => Err(AiError::Image(format!("unsupported PNG color type: {other:?}"))),
    }
}

// ---------------------------------------------------------------- quantize

/// Reduce an image to at most `max_colors` colors using a median-cut palette
/// followed by nearest-color mapping. Preserves alpha.
pub fn quantize(img: &RgbaImage, max_colors: usize) -> RgbaImage {
    let max_colors = max_colors.max(1);

    // Collect unique opaque RGB values.
    let mut unique: Vec<[u8; 3]> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for i in (0..img.data.len()).step_by(4) {
        let a = img.data[i + 3];
        if a == 0 {
            continue;
        }
        let key = [img.data[i], img.data[i + 1], img.data[i + 2]];
        if seen.insert(key) {
            unique.push(key);
        }
    }

    let palette: Vec<[u8; 3]> = if unique.len() <= max_colors {
        unique
    } else {
        median_cut(&unique, max_colors)
    };

    // Map every pixel to the nearest palette entry.
    let mut out = img.clone();
    let mut i = 0;
    while i < out.data.len() {
        if out.data[i + 3] == 0 {
            i += 4;
            continue;
        }
        let target = [out.data[i], out.data[i + 1], out.data[i + 2]];
        let mut best = 0;
        let mut best_d = u32::MAX;
        for (idx, p) in palette.iter().enumerate() {
            let d = color_dist(&target, p);
            if d < best_d {
                best_d = d;
                best = idx;
                if d == 0 {
                    break;
                }
            }
        }
        let p = palette[best];
        out.data[i] = p[0];
        out.data[i + 1] = p[1];
        out.data[i + 2] = p[2];
        i += 4;
    }
    out
}

fn color_dist(a: &[u8; 3], b: &[u8; 3]) -> u32 {
    let dr = a[0] as i32 - b[0] as i32;
    let dg = a[1] as i32 - b[1] as i32;
    let db = a[2] as i32 - b[2] as i32;
    (dr * dr + dg * dg + db * db) as u32
}

/// Median-cut: recursively split the color box along its widest axis until the
/// box count reaches `max_colors`, then average each box.
fn median_cut(colors: &[[u8; 3]], max_colors: usize) -> Vec<[u8; 3]> {
    let mut boxes: Vec<Vec<[u8; 3]>> = vec![colors.to_vec()];
    while boxes.len() < max_colors {
        // Find the box with the largest range.
        let mut split_idx = 0;
        let mut split_range = -1i32;
        for (i, b) in boxes.iter().enumerate() {
            let (rmin, rmax, gmin, gmax, bmin, bmax) = box_range(b);
            let r = (rmax as i32 - rmin as i32)
                .max(gmax as i32 - gmin as i32)
                .max(bmax as i32 - bmin as i32);
            if r > split_range {
                split_range = r;
                split_idx = i;
            }
        }
        if split_range <= 0 {
            break;
        }
        let b = boxes.swap_remove(split_idx);
        // Split along the widest axis at the median.
        let (rmin, rmax, gmin, gmax, bmin, bmax) = box_range(&b);
        let rr = rmax - rmin;
        let gr = gmax - gmin;
        let br = bmax - bmin;
        let mut v: Vec<[u8; 3]> = b;
        if rr >= gr && rr >= br {
            v.sort_by_key(|c| c[0]);
        } else if gr >= br {
            v.sort_by_key(|c| c[1]);
        } else {
            v.sort_by_key(|c| c[2]);
        }
        let mid = v.len() / 2;
        let right = v.split_off(mid.max(1));
        boxes.push(v);
        boxes.push(right);
    }
    boxes.iter().map(|b| box_average(b)).collect()
}

fn box_range(b: &[[u8; 3]]) -> (u8, u8, u8, u8, u8, u8) {
    let mut rmin = 255;
    let mut rmax = 0;
    let mut gmin = 255;
    let mut gmax = 0;
    let mut bmin = 255;
    let mut bmax = 0;
    for c in b {
        rmin = rmin.min(c[0]);
        rmax = rmax.max(c[0]);
        gmin = gmin.min(c[1]);
        gmax = gmax.max(c[1]);
        bmin = bmin.min(c[2]);
        bmax = bmax.max(c[2]);
    }
    (rmin, rmax, gmin, gmax, bmin, bmax)
}

fn box_average(b: &[[u8; 3]]) -> [u8; 3] {
    if b.is_empty() {
        return [0, 0, 0];
    }
    let (mut r, mut g, mut bl) = (0u64, 0u64, 0u64);
    for c in b {
        r += c[0] as u64;
        g += c[1] as u64;
        bl += c[2] as u64;
    }
    let n = b.len() as u64;
    [(r / n) as u8, (g / n) as u8, (bl / n) as u8]
}

/// Compress to a target bit depth: `bits` in 1..=8 means `2^bits` colors.
pub fn compress_to_bits(img: &RgbaImage, bits: u8) -> RgbaImage {
    let bits = bits.clamp(1, 8);
    quantize(img, 1usize << bits)
}

// ---------------------------------------------------------- remove background

/// Remove a near-uniform background by flood-filling from every border pixel.
/// Any border-connected pixel whose color is within `tolerance` (Euclidean RGB
/// distance) of the sampled border colors is set transparent.
pub fn remove_background(img: &RgbaImage, tolerance: f32) -> RgbaImage {
    let mut out = img.clone();
    let (w, h) = (img.width, img.height);
    if w == 0 || h == 0 {
        return out;
    }

    // Sample border colors (opaque only) as the background candidates.
    let mut bg: Vec<[u8; 3]> = Vec::new();
    for x in 0..w {
        push_border(&mut bg, img, x, 0);
        push_border(&mut bg, img, x, h - 1);
    }
    for y in 0..h {
        push_border(&mut bg, img, 0, y);
        push_border(&mut bg, img, w - 1, y);
    }
    if bg.is_empty() {
        return out;
    }

    let matches_bg = |c: [u8; 3]| -> bool {
        bg.iter().any(|b| {
            let dr = b[0] as f32 - c[0] as f32;
            let dg = b[1] as f32 - c[1] as f32;
            let db = b[2] as f32 - c[2] as f32;
            (dr * dr + dg * dg + db * db).sqrt() <= tolerance
        })
    };

    let mut visited = vec![false; w * h];
    let mut stack: Vec<(usize, usize)> = Vec::new();
    for x in 0..w {
        stack.push((x, 0));
        stack.push((x, h - 1));
    }
    for y in 0..h {
        stack.push((0, y));
        stack.push((w - 1, y));
    }

    while let Some((x, y)) = stack.pop() {
        let key = y * w + x;
        if visited[key] {
            continue;
        }
        visited[key] = true;
        let p = out.pixel(x, y);
        if p[3] == 0 {
            continue;
        }
        if !matches_bg([p[0], p[1], p[2]]) {
            continue;
        }
        out.set_pixel(x, y, [0, 0, 0, 0]);
        if x + 1 < w {
            stack.push((x + 1, y));
        }
        if x > 0 {
            stack.push((x - 1, y));
        }
        if y + 1 < h {
            stack.push((x, y + 1));
        }
        if y > 0 {
            stack.push((x, y - 1));
        }
    }
    out
}

fn push_border(out: &mut Vec<[u8; 3]>, img: &RgbaImage, x: usize, y: usize) {
    let p = img.pixel(x, y);
    if p[3] != 0 {
        out.push([p[0], p[1], p[2]]);
    }
}

/// Slice a sprite sheet into a uniform `cols` x `rows` grid of frames.
pub fn slice_grid(img: &RgbaImage, cols: usize, rows: usize) -> Vec<RgbaImage> {
    let cols = cols.max(1);
    let rows = rows.max(1);
    let fw = img.width / cols;
    let fh = img.height / rows;
    if fw == 0 || fh == 0 {
        return vec![img.clone()];
    }
    let mut frames = Vec::with_capacity(cols * rows);
    for gy in 0..rows {
        for gx in 0..cols {
            let mut frame = RgbaImage::blank(fw, fh);
            for y in 0..fh {
                for x in 0..fw {
                    let src = img.pixel(gx * fw + x, gy * fh + y);
                    frame.set_pixel(x, y, src);
                }
            }
            frames.push(frame);
        }
    }
    frames
}
