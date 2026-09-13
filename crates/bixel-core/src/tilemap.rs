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

// -------------------------------------------------------------- orientation
//
// Tiled-compatible projection math shared by the map editor and the composite
// renderer. The formulas mirror libtiled's `IsometricRenderer` /
// `StaggeredRenderer` so files authored in Tiled land in the same screen
// coordinates. `Staggered` is Tiled's isometric-staggered layout (diamond
// tiles on a half-offset grid); `Hexagonal` is parse-only and not rendered.

/// Tiled map orientation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Orientation {
    Orthogonal,
    Isometric,
    Staggered,
    Hexagonal,
}

impl Orientation {
    pub fn as_tiled(self) -> &'static str {
        match self {
            Orientation::Orthogonal => "orthogonal",
            Orientation::Isometric => "isometric",
            Orientation::Staggered => "staggered",
            Orientation::Hexagonal => "hexagonal",
        }
    }

    /// Parse the Tiled `orientation` string. `isometric_staggered` is accepted
    /// as an alias for Tiled's `staggered` layout (used by some exporters).
    pub fn from_tiled(s: &str) -> Option<Self> {
        match s {
            "orthogonal" => Some(Orientation::Orthogonal),
            "isometric" => Some(Orientation::Isometric),
            "staggered" | "isometric_staggered" | "isometric-staggered" => Some(Orientation::Staggered),
            "hexagonal" => Some(Orientation::Hexagonal),
            _ => None,
        }
    }

    pub fn is_isometric(self) -> bool {
        matches!(self, Orientation::Isometric | Orientation::Staggered)
    }
}

/// Painter's-algorithm order for overlapping isometric tiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderOrder {
    RightDown,
    RightUp,
    LeftDown,
    LeftUp,
}

impl RenderOrder {
    pub fn as_tiled(self) -> &'static str {
        match self {
            RenderOrder::RightDown => "right-down",
            RenderOrder::RightUp => "right-up",
            RenderOrder::LeftDown => "left-down",
            RenderOrder::LeftUp => "left-up",
        }
    }

    pub fn from_tiled(s: &str) -> Self {
        match s {
            "right-up" => RenderOrder::RightUp,
            "left-down" => RenderOrder::LeftDown,
            "left-up" => RenderOrder::LeftUp,
            _ => RenderOrder::RightDown,
        }
    }
}

/// Axis along which staggered rows/columns are offset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaggerAxis {
    X,
    Y,
}

impl StaggerAxis {
    pub fn as_tiled(self) -> &'static str {
        match self {
            StaggerAxis::X => "x",
            StaggerAxis::Y => "y",
        }
    }
    pub fn from_tiled(s: &str) -> Self {
        if s == "x" {
            StaggerAxis::X
        } else {
            StaggerAxis::Y
        }
    }
}

/// Which rows/columns get the half-tile offset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaggerIndex {
    Odd,
    Even,
}

impl StaggerIndex {
    pub fn as_tiled(self) -> &'static str {
        match self {
            StaggerIndex::Odd => "odd",
            StaggerIndex::Even => "even",
        }
    }
    pub fn from_tiled(s: &str) -> Self {
        if s == "even" {
            StaggerIndex::Even
        } else {
            StaggerIndex::Odd
        }
    }
}

/// Everything the projection math needs about a map. Cheap to copy; build one
/// per operation with [`MapGeometry::new`].
#[derive(Debug, Clone, Copy)]
pub struct MapGeometry {
    pub orientation: Orientation,
    pub columns: usize,
    pub rows: usize,
    pub tile_width: usize,
    pub tile_height: usize,
    pub stagger_axis: StaggerAxis,
    pub stagger_index: StaggerIndex,
    /// Infinite maps project around an absolute origin (cell 0,0) instead of
    /// shifting the map so its bounds start at pixel 0, so content never moves
    /// as the map grows.
    pub infinite: bool,
}

impl MapGeometry {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        orientation: Orientation,
        columns: usize,
        rows: usize,
        tile_width: usize,
        tile_height: usize,
        stagger_axis: StaggerAxis,
        stagger_index: StaggerIndex,
    ) -> Self {
        MapGeometry {
            orientation,
            columns,
            rows,
            tile_width: tile_width.max(1),
            tile_height: tile_height.max(1),
            stagger_axis,
            stagger_index,
            infinite: false,
        }
    }

    /// The horizontal origin shift that keeps a finite isometric map's content
    /// inside `[0, pixel_width]`. Infinite maps use an absolute origin.
    fn iso_origin_x(&self) -> i64 {
        if self.infinite {
            0
        } else {
            self.rows as i64 * self.tw() / 2
        }
    }

    fn tw(&self) -> i64 {
        self.tile_width as i64
    }
    fn th(&self) -> i64 {
        self.tile_height as i64
    }
    fn stagger_even(&self) -> bool {
        self.stagger_index == StaggerIndex::Even
    }
    fn do_stagger_x(&self, x: i64) -> bool {
        self.stagger_axis == StaggerAxis::X && ((x & 1) != 0) ^ self.stagger_even()
    }
    fn do_stagger_y(&self, y: i64) -> bool {
        self.stagger_axis == StaggerAxis::Y && ((y & 1) != 0) ^ self.stagger_even()
    }

    /// Whole-map pixel bounds. Isometric and staggered canvases are sized to
    /// contain every tile image, including the half-tile stagger margins.
    pub fn pixel_size(&self) -> (usize, usize) {
        let (w, h) = (self.columns as i64, self.rows as i64);
        let (tw, th) = (self.tw(), self.th());
        let (px, py) = match self.orientation {
            Orientation::Orthogonal | Orientation::Hexagonal => (w * tw, h * th),
            Orientation::Isometric => ((w + h + 1) * tw / 2, (w + h) * th / 2),
            Orientation::Staggered => match self.stagger_axis {
                StaggerAxis::Y => ((2 * w + 1) * tw / 2, (h + 1) * th / 2),
                StaggerAxis::X => ((w + 1) * tw / 2, (2 * h + 1) * th / 2),
            },
        };
        (px.max(0) as usize, py.max(0) as usize)
    }

    /// Top-left corner of a cell's tile image in whole-map screen pixels.
    pub fn tile_origin(&self, cx: i64, cy: i64) -> (i64, i64) {
        let (tw, th) = (self.tw(), self.th());
        match self.orientation {
            Orientation::Orthogonal | Orientation::Hexagonal => (cx * tw, cy * th),
            Orientation::Isometric => {
                let origin_x = self.iso_origin_x();
                ((cx - cy) * tw / 2 + origin_x, (cx + cy) * th / 2)
            }
            Orientation::Staggered => match self.stagger_axis {
                StaggerAxis::Y => {
                    let mut x = cx * tw;
                    if self.do_stagger_y(cy) {
                        x += tw / 2;
                    }
                    (x, cy * th / 2)
                }
                StaggerAxis::X => {
                    let mut y = cy * th;
                    if self.do_stagger_x(cx) {
                        y += th / 2;
                    }
                    (cx * tw / 2, y)
                }
            },
        }
    }

    /// Centre of a cell's tile image in whole-map screen pixels.
    pub fn tile_center(&self, cx: i64, cy: i64) -> (i64, i64) {
        let (x, y) = self.tile_origin(cx, cy);
        (x + self.tw() / 2, y + self.th() / 2)
    }

    /// Whole-map screen pixel -> integer cell coordinate (may fall outside the
    /// map bounds; callers clamp).
    pub fn pixel_to_cell(&self, px: f64, py: f64) -> (i64, i64) {
        let (tw, th) = (self.tw() as f64, self.th() as f64);
        match self.orientation {
            Orientation::Orthogonal | Orientation::Hexagonal => {
                ((px / tw).floor() as i64, (py / th).floor() as i64)
            }
            Orientation::Isometric => {
                let origin_x = self.iso_origin_x() as f64;
                let x = (px - origin_x) / (tw / 2.0);
                let y = py / (th / 2.0);
                (
                    ((x + y - 1.0) / 2.0).floor() as i64,
                    ((y - x + 1.0) / 2.0).floor() as i64,
                )
            }
            Orientation::Staggered => self.staggered_pixel_to_cell(px, py),
        }
    }

    fn staggered_pixel_to_cell(&self, px: f64, py: f64) -> (i64, i64) {
        let (tw, th) = (self.tw() as f64, self.th() as f64);
        let even = self.stagger_even();
        match self.stagger_axis {
            StaggerAxis::Y => {
                let aligned_y = py - if even { th / 2.0 } else { 0.0 };
                let mut rx = (px / tw).floor() as i64;
                let ry = (aligned_y / th).floor() as i64;
                let rel_x = px - rx as f64 * tw;
                let rel_y = aligned_y - ry as f64 * th;
                let mut iy = ry * 2;
                if even {
                    iy += 1;
                }
                let y_pos = rel_x * (th / tw);
                let side = th / 2.0;
                if side - y_pos > rel_y {
                    let (a, b) = self.stag_top_left(rx, iy);
                    rx = a;
                    iy = b;
                }
                if -side + y_pos > rel_y {
                    let (a, b) = self.stag_top_right(rx, iy);
                    rx = a;
                    iy = b;
                }
                if side + y_pos < rel_y {
                    let (a, b) = self.stag_bottom_left(rx, iy);
                    rx = a;
                    iy = b;
                }
                if side * 3.0 - y_pos < rel_y {
                    let (a, b) = self.stag_bottom_right(rx, iy);
                    rx = a;
                    iy = b;
                }
                (rx, iy)
            }
            StaggerAxis::X => {
                let aligned_x = px - if even { tw / 2.0 } else { 0.0 };
                let rx = (aligned_x / tw).floor() as i64;
                let mut ry = (py / th).floor() as i64;
                let rel_x = aligned_x - rx as f64 * tw;
                let rel_y = py - ry as f64 * th;
                let mut ix = rx * 2;
                if even {
                    ix += 1;
                }
                let x_pos = rel_y * (tw / th);
                let side = tw / 2.0;
                if side - x_pos > rel_x {
                    let (a, b) = self.stag_top_left(ix, ry);
                    ix = a;
                    ry = b;
                }
                if -side + x_pos > rel_x {
                    let (a, b) = self.stag_top_right(ix, ry);
                    ix = a;
                    ry = b;
                }
                if side + x_pos < rel_x {
                    let (a, b) = self.stag_bottom_left(ix, ry);
                    ix = a;
                    ry = b;
                }
                if side * 3.0 - x_pos < rel_x {
                    let (a, b) = self.stag_bottom_right(ix, ry);
                    ix = a;
                    ry = b;
                }
                (ix, ry)
            }
        }
    }

    fn stag_top_left(&self, x: i64, y: i64) -> (i64, i64) {
        if self.stagger_axis == StaggerAxis::Y {
            if ((y & 1) != 0) ^ self.stagger_even() {
                (x, y - 1)
            } else {
                (x - 1, y - 1)
            }
        } else if ((x & 1) != 0) ^ self.stagger_even() {
            (x - 1, y)
        } else {
            (x - 1, y - 1)
        }
    }

    fn stag_top_right(&self, x: i64, y: i64) -> (i64, i64) {
        if self.stagger_axis == StaggerAxis::Y {
            if ((y & 1) != 0) ^ self.stagger_even() {
                (x + 1, y - 1)
            } else {
                (x, y - 1)
            }
        } else if ((x & 1) != 0) ^ self.stagger_even() {
            (x + 1, y)
        } else {
            (x + 1, y - 1)
        }
    }

    fn stag_bottom_left(&self, x: i64, y: i64) -> (i64, i64) {
        if self.stagger_axis == StaggerAxis::Y {
            if ((y & 1) != 0) ^ self.stagger_even() {
                (x, y + 1)
            } else {
                (x - 1, y + 1)
            }
        } else if ((x & 1) != 0) ^ self.stagger_even() {
            (x - 1, y + 1)
        } else {
            (x - 1, y)
        }
    }

    fn stag_bottom_right(&self, x: i64, y: i64) -> (i64, i64) {
        if self.stagger_axis == StaggerAxis::Y {
            if ((y & 1) != 0) ^ self.stagger_even() {
                (x + 1, y + 1)
            } else {
                (x, y + 1)
            }
        } else if ((x & 1) != 0) ^ self.stagger_even() {
            (x + 1, y + 1)
        } else {
            (x + 1, y)
        }
    }

    /// Visit every cell in painter's order (back to front). For orthogonal maps
    /// the order is a no-op row-major walk; isometric/staggered use it to keep
    /// tall tiles overlapping correctly.
    pub fn for_each_cell<F: FnMut(usize, usize)>(&self, order: RenderOrder, mut f: F) {
        let (w, h) = (self.columns, self.rows);
        if w == 0 || h == 0 {
            return;
        }
        let (x_rev, y_rev) = match order {
            RenderOrder::RightDown => (false, false),
            RenderOrder::RightUp => (false, true),
            RenderOrder::LeftDown => (true, false),
            RenderOrder::LeftUp => (true, true),
        };
        for yi in 0..h {
            let cy = if y_rev { h - 1 - yi } else { yi };
            for xi in 0..w {
                let cx = if x_rev { w - 1 - xi } else { xi };
                f(cx, cy);
            }
        }
    }

    /// Like [`MapGeometry::for_each_cell`] but over an inclusive world-cell
    /// range (which may be negative on infinite maps). Used to composite only
    /// the cells that can touch a requested pixel region.
    pub fn for_each_cell_in<F: FnMut(i64, i64)>(
        &self,
        min_x: i64,
        min_y: i64,
        max_x: i64,
        max_y: i64,
        order: RenderOrder,
        mut f: F,
    ) {
        if max_x < min_x || max_y < min_y {
            return;
        }
        let (x_rev, y_rev) = match order {
            RenderOrder::RightDown => (false, false),
            RenderOrder::RightUp => (false, true),
            RenderOrder::LeftDown => (true, false),
            RenderOrder::LeftUp => (true, true),
        };
        let width = max_x - min_x + 1;
        let height = max_y - min_y + 1;
        for yi in 0..height {
            let cy = if y_rev { max_y - yi } else { min_y + yi };
            for xi in 0..width {
                let cx = if x_rev { max_x - xi } else { min_x + xi };
                f(cx, cy);
            }
        }
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
