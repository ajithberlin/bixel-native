//! Headless tile-layer paint math, patterns, autotile and minimap projection
//! (port of `web/mapcore.js`). Pure data — no DOM, no rendering.

/// A tile layer: a width×height grid of tile GIDs.
#[derive(Debug, Clone, Default)]
pub struct TileLayer {
    pub width: usize,
    pub height: usize,
    /// Row-major tile GIDs. Missing entries read as 0.
    pub data: Vec<u32>,
}

impl TileLayer {
    pub fn new(width: usize, height: usize) -> Self {
        TileLayer {
            width,
            height,
            data: vec![0; width * height],
        }
    }
}

/// A tile-grid coordinate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub x: usize,
    pub y: usize,
}

/// An inclusive rectangle in cell coordinates.
#[derive(Debug, Clone, Copy)]
pub struct Rect {
    pub x0: usize,
    pub y0: usize,
    pub x1: usize,
    pub y1: usize,
}

/// A rectangular tile pattern.
#[derive(Debug, Clone)]
pub struct Pattern {
    pub w: usize,
    pub h: usize,
    pub tiles: Vec<u32>,
}

pub fn clamp(v: f64, min: f64, max: f64) -> f64 {
    v.max(min).min(max)
}

pub fn in_layer(layer: &TileLayer, x: isize, y: isize) -> bool {
    x >= 0 && y >= 0 && (x as usize) < layer.width && (y as usize) < layer.height
}

pub fn cell_index(layer: &TileLayer, x: usize, y: usize) -> usize {
    y * layer.width + x
}

pub fn get_tile(layer: &TileLayer, x: isize, y: isize) -> u32 {
    if in_layer(layer, x, y) {
        layer.data[cell_index(layer, x as usize, y as usize)]
    } else {
        0
    }
}

/// Mutate one cell. Returns true when the value actually changed.
pub fn set_tile(layer: &mut TileLayer, x: isize, y: isize, raw: u32) -> bool {
    if !in_layer(layer, x, y) {
        return false;
    }
    let i = cell_index(layer, x as usize, y as usize);
    if layer.data[i] == raw {
        return false;
    }
    layer.data[i] = raw;
    true
}

/// Map-pixel point -> integer tile grid coordinate.
pub fn grid_cell(tw: usize, th: usize, x: f64, y: f64) -> Cell {
    Cell {
        x: (x / tw as f64).floor() as usize,
        y: (y / th as f64).floor() as usize,
    }
}

/// Integer tile grid coordinate -> map-pixel origin.
pub fn grid_px(tw: usize, th: usize, cx: usize, cy: usize) -> (usize, usize) {
    (cx * tw, cy * th)
}

/// Inclusive rectangle paint; returns the list of changed data indices.
pub fn paint_rect(layer: &mut TileLayer, x0: isize, y0: isize, x1: isize, y1: isize, raw: u32) -> Vec<usize> {
    let mut changed = Vec::new();
    let (xa, xb) = (x0.min(x1), x0.max(x1));
    let (ya, yb) = (y0.min(y1), y0.max(y1));
    for y in ya..=yb {
        for x in xa..=xb {
            if set_tile(layer, x, y, raw) {
                changed.push(cell_index(layer, x as usize, y as usize));
            }
        }
    }
    changed
}

/// Connected-region fill (4-way). `raw` may be 0 to clear a region.
pub fn flood_fill(layer: &mut TileLayer, x: isize, y: isize, raw: u32) -> Vec<usize> {
    if !in_layer(layer, x, y) {
        return Vec::new();
    }
    let target = get_tile(layer, x, y);
    if target == raw {
        return Vec::new();
    }
    let mut changed = Vec::new();
    let mut stack = vec![(x, y)];
    let mut seen = vec![false; layer.width * layer.height];
    while let Some((cx, cy)) = stack.pop() {
        if !in_layer(layer, cx, cy) {
            continue;
        }
        let key = cell_index(layer, cx as usize, cy as usize);
        if seen[key] {
            continue;
        }
        seen[key] = true;
        if layer.data[key] != target {
            continue;
        }
        layer.data[key] = raw;
        changed.push(key);
        stack.push((cx + 1, cy));
        stack.push((cx - 1, cy));
        stack.push((cx, cy + 1));
        stack.push((cx, cy - 1));
    }
    changed
}

/// Normalize two corner cells into an inclusive rect.
pub fn norm_rect(a: Cell, b: Cell) -> Rect {
    Rect {
        x0: a.x.min(b.x),
        y0: a.y.min(b.y),
        x1: a.x.max(b.x),
        y1: a.y.max(b.y),
    }
}

/// Every cell inside an inclusive rectangle.
pub fn rect_cells(rect: Rect) -> Vec<Cell> {
    let mut out = Vec::new();
    for y in rect.y0..=rect.y1 {
        for x in rect.x0..=rect.x1 {
            out.push(Cell { x, y });
        }
    }
    out
}

/// Supercover Bresenham line between two cells so fast strokes never skip.
pub fn line_cells(a: Cell, b: Cell) -> Vec<Cell> {
    let mut pts = Vec::new();
    let (mut x0, mut y0) = (a.x as isize, a.y as isize);
    let (x1, y1) = (b.x as isize, b.y as isize);
    let dx = (x1 - x0).abs();
    let dy = (y1 - y0).abs();
    let sx: isize = if x0 < x1 { 1 } else { -1 };
    let sy: isize = if y0 < y1 { 1 } else { -1 };
    let mut err = dx - dy;
    loop {
        pts.push(Cell { x: x0 as usize, y: y0 as usize });
        if x0 == x1 && y0 == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 > -dy {
            err -= dy;
            x0 += sx;
        }
        if e2 < dx {
            err += dx;
            y0 += sy;
        }
    }
    pts
}

/// Read a rectangular region as a flat row-major pattern.
pub fn read_region(layer: &TileLayer, rect: Rect) -> Pattern {
    let w = rect.x1 - rect.x0 + 1;
    let h = rect.y1 - rect.y0 + 1;
    let mut tiles = vec![0u32; w * h];
    for y in 0..h {
        for x in 0..w {
            tiles[y * w + x] = get_tile(layer, (rect.x0 + x) as isize, (rect.y0 + y) as isize);
        }
    }
    Pattern { w, h, tiles }
}

/// Write a pattern with its top-left at `(x, y)`. `skip_empty` (default true)
/// skips cells whose value is 0 so brushes never erase. Returns changed indices.
pub fn write_region(layer: &mut TileLayer, x: usize, y: usize, pattern: &Pattern, skip_empty: bool) -> Vec<usize> {
    let mut changed = Vec::new();
    for py in 0..pattern.h {
        for px in 0..pattern.w {
            let raw = pattern.tiles[py * pattern.w + px];
            if skip_empty && raw == 0 {
                continue;
            }
            let tx = (x + px) as isize;
            let ty = (y + py) as isize;
            if set_tile(layer, tx, ty, raw) {
                changed.push(cell_index(layer, x + px, y + py));
            }
        }
    }
    changed
}

pub fn flip_pattern_h(p: &Pattern) -> Pattern {
    let mut t = vec![0u32; p.w * p.h];
    for y in 0..p.h {
        for x in 0..p.w {
            t[y * p.w + x] = p.tiles[y * p.w + (p.w - 1 - x)];
        }
    }
    Pattern { w: p.w, h: p.h, tiles: t }
}

pub fn flip_pattern_v(p: &Pattern) -> Pattern {
    let mut t = vec![0u32; p.w * p.h];
    for y in 0..p.h {
        for x in 0..p.w {
            t[y * p.w + x] = p.tiles[(p.h - 1 - y) * p.w + x];
        }
    }
    Pattern { w: p.w, h: p.h, tiles: t }
}

pub fn rotate_pattern_cw(p: &Pattern) -> Pattern {
    let (w, h) = (p.h, p.w);
    let mut t = vec![0u32; w * h];
    for y in 0..p.h {
        for x in 0..p.w {
            t[x * h + (h - 1 - y)] = p.tiles[y * p.w + x];
        }
    }
    Pattern { w, h, tiles: t }
}

pub fn rotate_pattern_ccw(p: &Pattern) -> Pattern {
    let (w, h) = (p.h, p.w);
    let mut t = vec![0u32; w * h];
    for y in 0..p.h {
        for x in 0..p.w {
            t[(w - 1 - x) * h + y] = p.tiles[y * p.w + x];
        }
    }
    Pattern { w, h, tiles: t }
}

/// Replace every occurrence of `from` with `to` across an inclusive rect.
/// `from` may be a single value or a slice of acceptable values.
pub fn replace_tiles(layer: &mut TileLayer, rect: Rect, from: &[u32], to: u32) -> Vec<usize> {
    let mut changed = Vec::new();
    for y in rect.y0..=rect.y1 {
        for x in rect.x0..=rect.x1 {
            let cur = get_tile(layer, x as isize, y as isize);
            if from.contains(&cur) && set_tile(layer, x as isize, y as isize, to) {
                changed.push(cell_index(layer, x, y));
            }
        }
    }
    changed
}

/// 4-bit neighbourhood mask for the terrain/autotile brush: N=1 E=2 S=4 W=8.
pub fn terrain_mask<F: Fn(isize, isize) -> bool>(x: isize, y: isize, is_same: F) -> u8 {
    let mut m = 0;
    if is_same(x, y - 1) {
        m |= 1;
    }
    if is_same(x + 1, y) {
        m |= 2;
    }
    if is_same(x, y + 1) {
        m |= 4;
    }
    if is_same(x - 1, y) {
        m |= 8;
    }
    m
}

/// Map a 4-bit terrain mask onto a Wang variant set. A full 16-tile set uses
/// `index == mask`; smaller sets wrap via modulo.
pub fn mask_to_index(mask: u8, count: usize) -> usize {
    if count == 0 {
        return 0;
    }
    if count >= 16 {
        mask as usize
    } else {
        (mask as usize) % count
    }
}

// ------------------------------------------------------------------ minimap

pub fn mini_scale(map_w: usize, map_h: usize, box_w: usize, box_h: usize, pad: usize) -> f64 {
    let w = box_w.saturating_sub(pad * 2).max(1);
    let h = box_h.saturating_sub(pad * 2).max(1);
    (w as f64 / map_w as f64).min(h as f64 / map_h as f64)
}

pub fn visible_map_rect(
    map_w: usize,
    map_h: usize,
    zoom: f64,
    view_x: f64,
    view_y: f64,
    vp_w: usize,
    vp_h: usize,
) -> (f64, f64, f64, f64) {
    let w = clamp(vp_w as f64 / zoom, 0.0, map_w as f64);
    let h = clamp(vp_h as f64 / zoom, 0.0, map_h as f64);
    (
        clamp(-view_x / zoom, 0.0, (map_w as f64 - w).max(0.0)),
        clamp(-view_y / zoom, 0.0, (map_h as f64 - h).max(0.0)),
        w,
        h,
    )
}

pub fn mini_from_map(map_x: f64, map_y: f64, scale: f64, origin_x: f64, origin_y: f64) -> (f64, f64) {
    (origin_x + map_x * scale, origin_y + map_y * scale)
}

pub fn map_from_mini(mini_x: f64, mini_y: f64, scale: f64, origin_x: f64, origin_y: f64) -> (f64, f64) {
    ((mini_x - origin_x) / scale, (mini_y - origin_y) / scale)
}

pub fn mini_origin(map_w: usize, map_h: usize, scale: f64, box_w: usize, box_h: usize) -> (f64, f64) {
    (
        (box_w as f64 - map_w as f64 * scale) / 2.0,
        (box_h as f64 - map_h as f64 * scale) / 2.0,
    )
}
