//! TileMap designer engine — a Tiled-parity editor for `.map` documents.
//!
//! The project document **is** a Tiled 1.10 orthogonal JSON map (uncompressed
//! GID arrays) so saving/exporting share one format that any engine with a
//! Tiled importer can read directly. This module aggregates the low-level
//! primitives from [`crate::tilemap`] (stamps, flood fill, line walking,
//! replace) into a multi-layer map with tileset slicing, object layers, custom
//! properties, undo/redo, whole-map compositing and CSV output.
//!
//! Pure data + JSON, no UI, no I/O (callers own files). Unknown Tiled fields
//! are preserved per node so files produced by the real Tiled editor
//! round-trip losslessly even when Bixel does not model the field yet.

use std::sync::Arc;

use serde_json::{json, Map, Value};

use crate::tilemap::{self, MapGeometry, Pattern, TileLayer};

pub use crate::tilemap::{Orientation, RenderOrder, StaggerAxis, StaggerIndex};

// Tiled GID flag bits (high bits of a raw GID).
pub const GID_H_FLIP: u32 = 0x8000_0000;
pub const GID_V_FLIP: u32 = 0x4000_0000;
pub const GID_D_FLIP: u32 = 0x2000_0000;
const GID_FLAGS: u32 = GID_H_FLIP | GID_V_FLIP | GID_D_FLIP;
const GID_MASK: u32 = !GID_FLAGS;

/// Sane cap on map cells per side (mirrors the 4096² sprite document cap).
pub const MAX_MAP_DIM: usize = 4096;
/// Safety cap on the dense storage an infinite map may grow to per side.
pub const MAX_INF_DIM: usize = 2048;
pub const MAX_UNDO: usize = 50;
/// Maximum display dimension for an interactively resized reference image.
pub const MAX_IMAGE_DISPLAY_DIM: u32 = 16_384;

fn prop_type(value: &Value) -> &'static str {
    match value {
        Value::Bool(_) => "bool",
        Value::Number(n) if n.is_i64() || n.is_u64() => "int",
        Value::Number(_) => "float",
        _ => "string",
    }
}

// ------------------------------------------------------------------ model

/// A tileset reference plus the pixel slice needed to composite it.
#[derive(Debug, Clone)]
pub struct Tileset {
    pub first_gid: u32,
    pub name: String,
    /// Relative image path (`assets/…`), as Tiled stores it.
    pub image: String,
    pub image_width: u32,
    pub image_height: u32,
    pub tile_width: u32,
    pub tile_height: u32,
    pub margin: u32,
    pub spacing: u32,
    pub columns: u32,
    pub tile_count: u32,
    /// Per-tileset pixel offset applied when drawing each tile (Tiled
    /// `tileoffset`). Commonly `(0, -tile_height/2)` for isometric art whose
    /// diamond sits in the upper half of the tile image.
    pub tile_offset: (i32, i32),
    /// RGBA pixels (`image_width*image_height*4`). Not serialized; uploaded by
    /// the host after load so the file stays a relative-path reference. Stored
    /// behind an `Arc` so undo/redo snapshots share the buffer instead of
    /// deep-cloning a full tileset image per stroke.
    pub pixels: Arc<Vec<u8>>,
    pub properties: Vec<Property>,
    /// Optional edge-based autotile set: `autotile[mask]` is the local tile id
    /// (None = untouched) resolving a 4-bit N/E/S/W membership mask. Persisted
    /// as a `bixel.autotile` string property so real Tiled keeps it.
    pub autotile: Vec<Option<u32>>,
    /// Unknown top-level tileset keys preserved from a Tiled-authored file.
    pub extra: Map<String, Value>,
}

impl Default for Tileset {
    fn default() -> Self {
        Tileset {
            first_gid: 1,
            name: String::new(),
            image: String::new(),
            image_width: 0,
            image_height: 0,
            tile_width: 16,
            tile_height: 16,
            margin: 0,
            spacing: 0,
            columns: 0,
            tile_count: 0,
            tile_offset: (0, 0),
            pixels: Arc::new(Vec::new()),
            properties: Vec::new(),
            autotile: Vec::new(),
            extra: Map::new(),
        }
    }
}

impl Tileset {
    /// `(column, row)` of a local tile id in the sheet, when valid.
    pub fn cell_of_local(&self, local: u32) -> Option<(u32, u32)> {
        if self.columns == 0 {
            return None;
        }
        let rows = (self.tile_count + self.columns - 1) / self.columns;
        let col = local % self.columns;
        let row = local / self.columns;
        if row >= rows {
            return None;
        }
        Some((col, row))
    }

    /// Copy the RGBA pixels of tile `local` into `out`
    /// (`tile_width*tile_height*4`). Returns false when unavailable.
    pub fn tile_rgba(&self, local: u32, out: &mut [u8]) -> bool {
        let tw = self.tile_width as usize;
        let th = self.tile_height as usize;
        if out.len() < tw * th * 4 {
            return false;
        }
        let Some((col, row)) = self.cell_of_local(local) else {
            return false;
        };
        let img_w = self.image_width as usize;
        let img_h = self.image_height as usize;
        if self.pixels.len() < img_w * img_h * 4 {
            return false;
        }
        let margin = self.margin as usize;
        let spacing = self.spacing as usize;
        let stride = tw + spacing;
        let src_x = margin + col as usize * stride;
        let src_y = margin + row as usize * stride;
        if src_x + tw > img_w || src_y + th > img_h {
            return false;
        }
        for y in 0..th {
            let s = ((src_y + y) * img_w + src_x) * 4;
            let d = y * tw * 4;
            out[d..d + tw * 4].copy_from_slice(&self.pixels[s..s + tw * 4]);
        }
        true
    }
}

/// Tiled custom property.
#[derive(Debug, Clone)]
pub struct Property {
    pub name: String,
    /// One of "string", "int", "float", "bool", "color", "file", "object".
    pub kind: String,
    pub value: Value,
}

impl Property {
    pub fn new(name: &str, value: Value) -> Self {
        Property {
            name: name.to_string(),
            kind: prop_type(&value).to_string(),
            value,
        }
    }
}

/// Map object on an object layer (rect or point in tile-pixel coordinates).
#[derive(Debug, Clone)]
pub struct MapObject {
    pub id: u32,
    pub name: String,
    pub kind: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub visible: bool,
    pub properties: Vec<Property>,
    /// Unknown object keys (e.g. `point`, `rotation`, `ellipse`) preserved.
    pub extra: Map<String, Value>,
}

impl Default for MapObject {
    fn default() -> Self {
        MapObject {
            id: 0,
            name: String::new(),
            kind: String::new(),
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            visible: true,
            properties: Vec::new(),
            extra: Map::new(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ObjectLayer {
    pub id: u32,
    pub name: String,
    pub visible: bool,
    pub opacity: f32,
    pub objects: Vec<MapObject>,
    pub properties: Vec<Property>,
    pub extra: Map<String, Value>,
}

/// A named tile layer over the whole map. Raw cell GIDs include flip flags.
#[derive(Debug, Clone, Default)]
pub struct TileLayerData {
    pub id: u32,
    pub name: String,
    pub visible: bool,
    pub opacity: f32,
    pub layer: TileLayer,
    pub properties: Vec<Property>,
    pub extra: Map<String, Value>,
}

/// A single image composited over the map (Tiled `imagelayer`). Pixels are
/// stored in-engine like tileset pixels: the file stays a relative-path
/// reference and the host uploads the decoded RGBA after load.
#[derive(Debug, Clone, Default)]
pub struct ImageLayerData {
    pub id: u32,
    pub name: String,
    pub visible: bool,
    pub opacity: f32,
    /// Relative image path (`assets/…`), as Tiled stores it.
    pub image: String,
    pub image_width: u32,
    pub image_height: u32,
    /// Display dimensions in map pixels. The source pixels remain at their
    /// original size so resizing uses nearest-neighbour sampling.
    pub display_width: u32,
    pub display_height: u32,
    /// Pixel offset from the map origin (Tiled `x`/`y`).
    pub x: f64,
    pub y: f64,
    /// RGBA pixels (`image_width*image_height*4`). Not serialized.
    pub pixels: Arc<Vec<u8>>,
    pub properties: Vec<Property>,
    pub extra: Map<String, Value>,
}

/// Layers are a tagged union so object/image layers slot in without a schema break.
#[derive(Debug, Clone)]
pub enum MapLayer {
    Tile(TileLayerData),
    Objects(ObjectLayer),
    Image(ImageLayerData),
}

impl MapLayer {
    pub fn id(&self) -> u32 {
        match self {
            MapLayer::Tile(l) => l.id,
            MapLayer::Objects(l) => l.id,
            MapLayer::Image(l) => l.id,
        }
    }
    pub fn name(&self) -> &str {
        match self {
            MapLayer::Tile(l) => &l.name,
            MapLayer::Objects(l) => &l.name,
            MapLayer::Image(l) => &l.name,
        }
    }
    pub fn name_mut(&mut self) -> &mut String {
        match self {
            MapLayer::Tile(l) => &mut l.name,
            MapLayer::Objects(l) => &mut l.name,
            MapLayer::Image(l) => &mut l.name,
        }
    }
    pub fn visible(&self) -> bool {
        match self {
            MapLayer::Tile(l) => l.visible,
            MapLayer::Objects(l) => l.visible,
            MapLayer::Image(l) => l.visible,
        }
    }
    pub fn set_visible(&mut self, v: bool) {
        match self {
            MapLayer::Tile(l) => l.visible = v,
            MapLayer::Objects(l) => l.visible = v,
            MapLayer::Image(l) => l.visible = v,
        }
    }
    pub fn opacity(&self) -> f32 {
        match self {
            MapLayer::Tile(l) => l.opacity,
            MapLayer::Objects(l) => l.opacity,
            MapLayer::Image(l) => l.opacity,
        }
    }
    pub fn set_opacity(&mut self, v: f32) {
        let v = v.clamp(0.0, 1.0);
        match self {
            MapLayer::Tile(l) => l.opacity = v,
            MapLayer::Objects(l) => l.opacity = v,
            MapLayer::Image(l) => l.opacity = v,
        }
    }
    pub fn properties_mut(&mut self) -> &mut Vec<Property> {
        match self {
            MapLayer::Tile(l) => &mut l.properties,
            MapLayer::Objects(l) => &mut l.properties,
            MapLayer::Image(l) => &mut l.properties,
        }
    }
    pub fn is_objects(&self) -> bool {
        matches!(self, MapLayer::Objects(_))
    }
    pub fn is_image(&self) -> bool {
        matches!(self, MapLayer::Image(_))
    }
}

/// A serializable snapshot (tileset pixels included — the maps are small).
#[derive(Debug, Clone)]
struct MapState {
    width: usize,
    height: usize,
    tile_width: usize,
    tile_height: usize,
    infinite: bool,
    origin_x: i32,
    origin_y: i32,
    orientation: Orientation,
    render_order: RenderOrder,
    stagger_axis: StaggerAxis,
    stagger_index: StaggerIndex,
    tilesets: Vec<Tileset>,
    layers: Vec<MapLayer>,
    next_layer_id: u32,
    next_object_id: u32,
    properties: Vec<Property>,
    extra: Map<String, Value>,
}

/// The tile-map aggregate.
#[derive(Debug, Clone)]
pub struct TileMap {
    /// Dense storage width in cells. Infinite maps grow this as content is
    /// painted; `origin_x`/`origin_y` are the world cell of storage `(0, 0)`.
    pub width: usize,
    pub height: usize,
    pub tile_width: usize,
    pub tile_height: usize,
    /// Tiled `"infinite"`: unbounded canvas with chunked serialization.
    pub infinite: bool,
    pub origin_x: i32,
    pub origin_y: i32,
    pub orientation: Orientation,
    pub render_order: RenderOrder,
    pub stagger_axis: StaggerAxis,
    pub stagger_index: StaggerIndex,
    pub tilesets: Vec<Tileset>,
    pub layers: Vec<MapLayer>,
    pub next_layer_id: u32,
    pub next_object_id: u32,
    pub max_undo: usize,
    undo_stack: Vec<MapState>,
    redo_stack: Vec<MapState>,
    pub properties: Vec<Property>,
    /// Unknown map-level keys preserved from a Tiled-authored file.
    pub extra: Map<String, Value>,
}

impl Default for TileMap {
    fn default() -> Self {
        Self::new(40, 25, 16, 16)
    }
}

// --------------------------------------------------------------- lifecycle

impl TileMap {
    pub fn new(width: usize, height: usize, tile_width: usize, tile_height: usize) -> Self {
        let width = width.clamp(1, MAX_MAP_DIM);
        let height = height.clamp(1, MAX_MAP_DIM);
        let tile_width = tile_width.max(1);
        let tile_height = tile_height.max(1);
        let mut map = TileMap {
            width,
            height,
            tile_width,
            tile_height,
            infinite: false,
            origin_x: 0,
            origin_y: 0,
            orientation: Orientation::Orthogonal,
            render_order: RenderOrder::RightDown,
            stagger_axis: StaggerAxis::Y,
            stagger_index: StaggerIndex::Odd,
            tilesets: Vec::new(),
            layers: Vec::new(),
            next_layer_id: 1,
            next_object_id: 1,
            max_undo: MAX_UNDO,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            properties: Vec::new(),
            extra: Map::new(),
        };
        map.add_tile_layer(None);
        map
    }

    /// A Tiled infinite map: no fixed dimensions, chunked serialization and an
    /// unbounded canvas that grows as content is painted. Starts with an empty
    /// tile layer (storage `0 × 0`, growing on the first paint).
    pub fn new_infinite(tile_width: usize, tile_height: usize, orientation: Orientation) -> Self {
        let mut map = TileMap {
            width: 0,
            height: 0,
            tile_width: tile_width.max(1),
            tile_height: tile_height.max(1),
            infinite: true,
            origin_x: 0,
            origin_y: 0,
            orientation,
            render_order: RenderOrder::RightDown,
            stagger_axis: StaggerAxis::Y,
            stagger_index: StaggerIndex::Odd,
            tilesets: Vec::new(),
            layers: Vec::new(),
            next_layer_id: 1,
            next_object_id: 1,
            max_undo: MAX_UNDO,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            properties: Vec::new(),
            extra: Map::new(),
        };
        map.add_tile_layer(None);
        map
    }

    pub fn pixel_width(&self) -> usize {
        if self.infinite {
            self.content_pixel_bounds().map(|b| b.2).unwrap_or(0)
        } else {
            self.geometry().pixel_size().0
        }
    }
    pub fn pixel_height(&self) -> usize {
        if self.infinite {
            self.content_pixel_bounds().map(|b| b.3).unwrap_or(0)
        } else {
            self.geometry().pixel_size().1
        }
    }

    /// Projection parameters for the current orientation.
    pub fn geometry(&self) -> MapGeometry {
        let mut geo = MapGeometry::new(
            self.orientation,
            self.width,
            self.height,
            self.tile_width,
            self.tile_height,
            self.stagger_axis,
            self.stagger_index,
        );
        geo.infinite = self.infinite;
        geo
    }

    /// Inclusive world-cell bounds of storage (`origin .. origin + dims - 1`).
    pub fn storage_bounds(&self) -> (i32, i32, i32, i32) {
        if self.width == 0 || self.height == 0 {
            return (0, 0, -1, -1);
        }
        (
            self.origin_x,
            self.origin_y,
            self.origin_x + self.width as i32 - 1,
            self.origin_y + self.height as i32 - 1,
        )
    }

    fn in_storage(&self, x: isize, y: isize) -> bool {
        x >= self.origin_x as isize
            && y >= self.origin_y as isize
            && x < self.origin_x as isize + self.width as isize
            && y < self.origin_y as isize + self.height as isize
    }

    /// Grow the dense storage (all tile layers together) so `(x, y)` fits,
    /// keeping a margin so a stroke doesn't reallocate per cell. Returns false
    /// for finite maps or when the safety cap would be exceeded.
    fn ensure_world_bounds(&mut self, x: i32, y: i32) -> bool {
        if !self.infinite {
            return false;
        }
        const MARGIN: i32 = 32;
        let (min_x, min_y, max_x, max_y) = if self.width == 0 || self.height == 0 {
            (x - MARGIN, y - MARGIN, x + MARGIN, y + MARGIN)
        } else {
            let (a, b, c, d) = self.storage_bounds();
            (a.min(x - MARGIN), b.min(y - MARGIN), c.max(x + MARGIN), d.max(y + MARGIN))
        };
        let new_w = (max_x - min_x + 1) as usize;
        let new_h = (max_y - min_y + 1) as usize;
        if new_w > MAX_INF_DIM || new_h > MAX_INF_DIM {
            return false;
        }
        let old_w = self.width;
        let old_h = self.height;
        let (old_ox, old_oy) = (self.origin_x, self.origin_y);
        for layer in &mut self.layers {
            if let MapLayer::Tile(data) = layer {
                let mut next = vec![0u32; new_w * new_h];
                for yy in 0..old_h {
                    for xx in 0..old_w {
                        let v = data.layer.data[yy * old_w + xx];
                        if v == 0 {
                            continue;
                        }
                        let gx = old_ox + xx as i32;
                        let gy = old_oy + yy as i32;
                        next[((gy - min_y) as usize) * new_w + (gx - min_x) as usize] = v;
                    }
                }
                data.layer.width = new_w;
                data.layer.height = new_h;
                data.layer.data = next;
            }
        }
        self.origin_x = min_x;
        self.origin_y = min_y;
        self.width = new_w;
        self.height = new_h;
        true
    }

    /// Inclusive world-cell bounds of all non-empty tile cells.
    pub fn content_cell_bounds(&self) -> Option<(i32, i32, i32, i32)> {
        let mut bounds: Option<(i32, i32, i32, i32)> = None;
        for layer in &self.layers {
            if let MapLayer::Tile(data) = layer {
                if data.layer.width == 0 || data.layer.height == 0 {
                    continue;
                }
                for (i, &gid) in data.layer.data.iter().enumerate() {
                    if gid & GID_MASK == 0 {
                        continue;
                    }
                    let x = self.origin_x + (i % data.layer.width) as i32;
                    let y = self.origin_y + (i / data.layer.width) as i32;
                    bounds = Some(match bounds {
                        None => (x, y, x, y),
                        Some((a, b, c, d)) => (a.min(x), b.min(y), c.max(x), d.max(y)),
                    });
                }
            }
        }
        bounds
    }

    /// Pixel-space bounds `(x, y, width, height)` of everything that would be
    /// composited. `None` for an empty infinite map.
    pub fn content_pixel_bounds(&self) -> Option<(i64, i64, usize, usize)> {
        let geo = self.geometry();
        let mut min_x = i64::MAX;
        let mut min_y = i64::MAX;
        let mut max_x = i64::MIN;
        let mut max_y = i64::MIN;
        let mut any = false;
        for layer in &self.layers {
            match layer {
                MapLayer::Tile(data) => {
                    if data.layer.width == 0 || data.layer.height == 0 {
                        continue;
                    }
                    for (i, &gid) in data.layer.data.iter().enumerate() {
                        if gid & GID_MASK == 0 {
                            continue;
                        }
                        let cx = self.origin_x as i64 + (i % data.layer.width) as i64;
                        let cy = self.origin_y as i64 + (i / data.layer.width) as i64;
                        let (ox, oy) = geo.tile_origin(cx, cy);
                        let (dx, dy) = self
                            .gid_lookup(gid)
                            .and_then(|(t, _, _)| self.tilesets.get(t))
                            .map(|ts| (ts.tile_offset.0 as i64, ts.tile_offset.1 as i64))
                            .unwrap_or((0, 0));
                        min_x = min_x.min(ox + dx);
                        min_y = min_y.min(oy + dy);
                        max_x = max_x.max(ox + dx + self.tile_width as i64);
                        max_y = max_y.max(oy + dy + self.tile_height as i64);
                        any = true;
                    }
                }
                MapLayer::Image(data) => {
                    if data.image_width == 0 || data.image_height == 0 {
                        continue;
                    }
                    let x = data.x.floor() as i64;
                    let y = data.y.floor() as i64;
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x + data.display_width as i64);
                    max_y = max_y.max(y + data.display_height as i64);
                    any = true;
                }
                MapLayer::Objects(_) => {}
            }
        }
        if !any {
            return None;
        }
        Some((min_x, min_y, (max_x - min_x).max(0) as usize, (max_y - min_y).max(0) as usize))
    }

    pub fn validate_dims(&self) -> Result<(), String> {
        if self.infinite {
            // Infinite maps are composited region-by-region; only guard the
            // dense storage cap.
            if self.width > MAX_INF_DIM || self.height > MAX_INF_DIM {
                return Err("Infinite scene exceeded its maximum editable area".into());
            }
            return Ok(());
        }
        if self.width == 0 || self.height == 0 || self.width > MAX_MAP_DIM || self.height > MAX_MAP_DIM {
            return Err("Invalid map dimensions".into());
        }
        let pixels = self
            .pixel_width()
            .checked_mul(self.pixel_height())
            .and_then(|n| n.checked_mul(4));
        if pixels.map(|p| p > 256 * 1024 * 1024).unwrap_or(true) {
            return Err("Map exceeds 256 MB when composited".into());
        }
        Ok(())
    }

    // ------------------------------------------------------------- history

    fn serialize_state(&self) -> MapState {
        MapState {
            width: self.width,
            height: self.height,
            tile_width: self.tile_width,
            tile_height: self.tile_height,
            infinite: self.infinite,
            origin_x: self.origin_x,
            origin_y: self.origin_y,
            orientation: self.orientation,
            render_order: self.render_order,
            stagger_axis: self.stagger_axis,
            stagger_index: self.stagger_index,
            tilesets: self.tilesets.clone(),
            layers: self.layers.clone(),
            next_layer_id: self.next_layer_id,
            next_object_id: self.next_object_id,
            properties: self.properties.clone(),
            extra: self.extra.clone(),
        }
    }

    fn restore_state(&mut self, state: MapState) {
        self.width = state.width;
        self.height = state.height;
        self.tile_width = state.tile_width;
        self.tile_height = state.tile_height;
        self.infinite = state.infinite;
        self.origin_x = state.origin_x;
        self.origin_y = state.origin_y;
        self.orientation = state.orientation;
        self.render_order = state.render_order;
        self.stagger_axis = state.stagger_axis;
        self.stagger_index = state.stagger_index;
        self.tilesets = state.tilesets;
        self.layers = state.layers;
        self.next_layer_id = state.next_layer_id;
        self.next_object_id = state.next_object_id;
        self.properties = state.properties;
        self.extra = state.extra;
    }

    /// Push an undo step before a discrete mutation (host-driven, matching the
    /// sprite document's snapshot convention).
    pub fn snapshot(&mut self) {
        self.undo_stack.push(self.serialize_state());
        if self.undo_stack.len() > self.max_undo {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    pub fn undo(&mut self) -> bool {
        let Some(prev) = self.undo_stack.pop() else {
            return false;
        };
        self.redo_stack.push(self.serialize_state());
        self.restore_state(prev);
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(next) = self.redo_stack.pop() else {
            return false;
        };
        self.undo_stack.push(self.serialize_state());
        self.restore_state(next);
        true
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    // ------------------------------------------------------------- layers

    pub fn layer_index_by_id(&self, id: u32) -> Option<usize> {
        self.layers.iter().position(|l| l.id() == id)
    }

    pub fn add_tile_layer(&mut self, name: Option<&str>) -> usize {
        let name = match name {
            Some(n) if !n.trim().is_empty() => n.trim().to_string(),
            _ => format!("Tile Layer {}", self.layers.len() + 1),
        };
        let data = TileLayerData {
            id: self.next_layer_id,
            name,
            visible: true,
            opacity: 1.0,
            layer: TileLayer::new(self.width, self.height),
            properties: Vec::new(),
            extra: Map::new(),
        };
        self.next_layer_id += 1;
        self.layers.push(MapLayer::Tile(data));
        self.layers.len() - 1
    }

    pub fn add_object_layer(&mut self, name: Option<&str>) -> usize {
        let name = match name {
            Some(n) if !n.trim().is_empty() => n.trim().to_string(),
            _ => format!("Object Layer {}", self.layers.len() + 1),
        };
        let data = ObjectLayer {
            id: self.next_layer_id,
            name,
            visible: true,
            opacity: 1.0,
            objects: Vec::new(),
            properties: Vec::new(),
            extra: Map::new(),
        };
        self.next_layer_id += 1;
        self.layers.push(MapLayer::Objects(data));
        self.layers.len() - 1
    }

    pub fn remove_layer(&mut self, index: usize) -> bool {
        if index < self.layers.len() {
            self.layers.remove(index);
            true
        } else {
            false
        }
    }

    pub fn reorder_layer(&mut self, from: usize, to: usize) -> bool {
        if from >= self.layers.len() || to >= self.layers.len() || from == to {
            return false;
        }
        let layer = self.layers.remove(from);
        self.layers.insert(to, layer);
        true
    }

    pub fn rename_layer(&mut self, index: usize, name: &str) -> bool {
        let name = name.trim();
        if name.is_empty() {
            return false;
        }
        if let Some(layer) = self.layers.get_mut(index) {
            *layer.name_mut() = name.to_string();
            true
        } else {
            false
        }
    }

    pub fn tile_layer_mut(&mut self, index: usize) -> Option<&mut TileLayer> {
        match self.layers.get_mut(index) {
            Some(MapLayer::Tile(data)) => Some(&mut data.layer),
            _ => None,
        }
    }

    pub fn tile_layer(&self, index: usize) -> Option<&TileLayer> {
        match self.layers.get(index) {
            Some(MapLayer::Tile(data)) => Some(&data.layer),
            _ => None,
        }
    }

    pub fn object_layer_mut(&mut self, index: usize) -> Option<&mut ObjectLayer> {
        match self.layers.get_mut(index) {
            Some(MapLayer::Objects(data)) => Some(data),
            _ => None,
        }
    }

    pub fn object_layer(&self, index: usize) -> Option<&ObjectLayer> {
        match self.layers.get(index) {
            Some(MapLayer::Objects(data)) => Some(data),
            _ => None,
        }
    }

    /// Add an image layer at pixel offset `(x, y)`. Pixels are uploaded after
    /// creation via [`TileMap::set_image_layer_pixels`].
    pub fn add_image_layer(
        &mut self,
        name: Option<&str>,
        image: &str,
        image_width: u32,
        image_height: u32,
        x: f64,
        y: f64,
    ) -> usize {
        let name = match name {
            Some(n) if !n.trim().is_empty() => n.trim().to_string(),
            _ => format!("Image Layer {}", self.layers.len() + 1),
        };
        let data = ImageLayerData {
            id: self.next_layer_id,
            name,
            visible: true,
            opacity: 1.0,
            image: image.to_string(),
            image_width,
            image_height,
            display_width: image_width,
            display_height: image_height,
            x,
            y,
            pixels: Arc::new(Vec::new()),
            properties: Vec::new(),
            extra: Map::new(),
        };
        self.next_layer_id += 1;
        self.layers.push(MapLayer::Image(data));
        self.layers.len() - 1
    }

    pub fn image_layer_mut(&mut self, index: usize) -> Option<&mut ImageLayerData> {
        match self.layers.get_mut(index) {
            Some(MapLayer::Image(data)) => Some(data),
            _ => None,
        }
    }

    pub fn image_layer(&self, index: usize) -> Option<&ImageLayerData> {
        match self.layers.get(index) {
            Some(MapLayer::Image(data)) => Some(data),
            _ => None,
        }
    }

    /// Move and/or resize an image layer in map-pixel coordinates. The source
    /// pixels stay unchanged; compositing scales them with nearest-neighbour
    /// sampling to keep pixel-art references crisp.
    pub fn set_image_layer_transform(
        &mut self,
        index: usize,
        x: f64,
        y: f64,
        display_width: u32,
        display_height: u32,
    ) -> bool {
        if !x.is_finite()
            || !y.is_finite()
            || display_width == 0
            || display_height == 0
            || display_width > MAX_IMAGE_DISPLAY_DIM
            || display_height > MAX_IMAGE_DISPLAY_DIM
        {
            return false;
        }
        let Some(data) = self.image_layer_mut(index) else {
            return false;
        };
        data.x = x;
        data.y = y;
        data.display_width = display_width;
        data.display_height = display_height;
        true
    }

    /// Store an image layer's RGBA pixels used for compositing.
    pub fn set_image_layer_pixels(&mut self, index: usize, rgba: &[u8]) -> bool {
        let Some(data) = self.image_layer_mut(index) else {
            return false;
        };
        let expected = data.image_width as usize * data.image_height as usize * 4;
        if expected == 0 || rgba.len() != expected {
            return false;
        }
        data.pixels = Arc::new(rgba.to_vec());
        true
    }

    pub fn image_layer_pixels(&self, index: usize, out: &mut [u8]) -> bool {
        let Some(data) = self.image_layer(index) else {
            return false;
        };
        if out.len() < data.pixels.len() {
            return false;
        }
        out[..data.pixels.len()].copy_from_slice(&data.pixels[..]);
        !data.pixels.is_empty()
    }

    // ------------------------------------------------------------- tilesets

    /// Pure slicing math: `(columns, tile_count)` for a `w × h` sheet sliced
    /// at `tw × th` with outer `margin` and inter-tile `spacing`. Unit-tested.
    pub fn slice_tileset_math(
        img_w: u32,
        img_h: u32,
        tw: u32,
        th: u32,
        margin: u32,
        spacing: u32,
    ) -> (u32, u32) {
        if tw == 0 || th == 0 {
            return (0, 0);
        }
        let num_w = img_w as i64 - 2 * margin as i64 + spacing as i64;
        let num_h = img_h as i64 - 2 * margin as i64 + spacing as i64;
        let denom_w = tw as i64 + spacing as i64;
        let denom_h = th as i64 + spacing as i64;
        if num_w < tw as i64 || num_h < th as i64 || denom_w <= 0 || denom_h <= 0 {
            return (0, 0);
        }
        let cols = num_w / denom_w;
        let rows = num_h / denom_h;
        if cols == 0 || rows == 0 {
            return (0, 0);
        }
        (cols as u32, (cols * rows) as u32)
    }

    /// Register a tileset and assign `first_gid` after the previous one.
    pub fn add_tileset(
        &mut self,
        name: &str,
        image: &str,
        image_width: u32,
        image_height: u32,
        tile_width: u32,
        tile_height: u32,
        margin: u32,
        spacing: u32,
    ) -> Result<usize, String> {
        let (columns, tile_count) = Self::slice_tileset_math(
            image_width, image_height, tile_width, tile_height, margin, spacing,
        );
        if columns == 0 || tile_count == 0 {
            return Err("Tileset image is too small for the requested tile size and spacing.".into());
        }
        if tile_count > 4096 {
            return Err("Tileset exceeds 4096 tiles.".into());
        }
        let first_gid = self
            .tilesets
            .last()
            .map(|t| t.first_gid + t.tile_count)
            .unwrap_or(1);
        if u64::from(first_gid) + u64::from(tile_count) > u64::from(GID_MASK) {
            return Err("Tileset exceeds the GID space.".into());
        }
        self.tilesets.push(Tileset {
            first_gid,
            name: name.trim().to_string(),
            image: image.to_string(),
            image_width,
            image_height,
            tile_width: tile_width.max(1),
            tile_height: tile_height.max(1),
            margin,
            spacing,
            columns,
            tile_count,
            tile_offset: (0, 0),
            pixels: Arc::new(Vec::new()),
            properties: Vec::new(),
            autotile: Vec::new(),
            extra: Map::new(),
        });
        Ok(self.tilesets.len() - 1)
    }

    /// Set a tileset's draw offset (Tiled `tileoffset`), in pixels.
    pub fn set_tileset_tile_offset(&mut self, index: usize, x: i32, y: i32) -> bool {
        match self.tilesets.get_mut(index) {
            Some(ts) => {
                ts.tile_offset = (x, y);
                true
            }
            None => false,
        }
    }

    pub fn tileset_tile_offset(&self, index: usize) -> Option<(i32, i32)> {
        self.tilesets.get(index).map(|ts| ts.tile_offset)
    }

    /// Remove a tileset, clearing cells that referenced it and re-basing the
    /// remaining `first_gid` chain. GIDs that pointed at later tilesets are
    /// shifted down so their artwork is preserved.
    pub fn remove_tileset(&mut self, index: usize) -> bool {
        if index >= self.tilesets.len() {
            return false;
        }
        let first = self.tilesets[index].first_gid;
        let count = self.tilesets[index].tile_count;
        let last = first + count;
        for layer in &mut self.layers {
            if let MapLayer::Tile(data) = layer {
                for gid in data.layer.data.iter_mut() {
                    let flags = *gid & GID_FLAGS;
                    let raw = *gid & GID_MASK;
                    if raw == 0 {
                        continue;
                    }
                    if raw >= first && raw < last {
                        *gid = 0;
                    } else if raw >= last {
                        *gid = (raw - count) | flags;
                    }
                }
            }
        }
        self.tilesets.remove(index);
        let mut next = 1u32;
        for ts in &mut self.tilesets {
            ts.first_gid = next;
            next += ts.tile_count;
        }
        true
    }

    /// Store the tileset image RGBA used for compositing.
    pub fn set_tileset_pixels(&mut self, index: usize, rgba: &[u8]) -> bool {
        let Some(ts) = self.tilesets.get_mut(index) else {
            return false;
        };
        let expected = ts.image_width as usize * ts.image_height as usize * 4;
        if rgba.len() != expected {
            return false;
        }
        ts.pixels = Arc::new(rgba.to_vec());
        true
    }

    pub fn tileset_pixels(&self, index: usize, out: &mut [u8]) -> bool {
        let Some(ts) = self.tilesets.get(index) else {
            return false;
        };
        if out.len() < ts.pixels.len() {
            return false;
        }
        out[..ts.pixels.len()].copy_from_slice(&ts.pixels[..]);
        !ts.pixels.is_empty()
    }

    /// Set autotile mask slot `mask` (0..16) to local tile `local`, or None to clear.
    pub fn set_autotile(&mut self, tileset: usize, mask: u8, local: Option<u32>) -> bool {
        let Some(ts) = self.tilesets.get_mut(tileset) else {
            return false;
        };
        if ts.autotile.is_empty() {
            ts.autotile = vec![None; 16];
        }
        if let Some(local) = local {
            if local >= ts.tile_count {
                return false;
            }
            ts.autotile[mask as usize % 16] = Some(local);
        } else {
            ts.autotile[mask as usize % 16] = None;
        }
        true
    }

    pub fn autotile_slots(&self, tileset: usize) -> Vec<Option<u32>> {
        self.tilesets
            .get(tileset)
            .map(|t| t.autotile.clone())
            .unwrap_or_default()
    }

    // -------------------------------------------------------------- GID math

    pub fn encode_gid(local_id: u32, first_gid: u32, flags: u32) -> u32 {
        (first_gid + local_id) | (flags & GID_FLAGS)
    }

    pub fn gid_flags(gid: u32) -> u32 {
        gid & GID_FLAGS
    }

    /// Resolve a raw GID into `(tileset_index, local_id, flags)`.
    pub fn gid_lookup(&self, gid: u32) -> Option<(usize, u32, u32)> {
        let raw = gid & GID_MASK;
        if raw == 0 {
            return None;
        }
        let flags = gid & GID_FLAGS;
        for (i, ts) in self.tilesets.iter().enumerate() {
            if raw >= ts.first_gid && raw < ts.first_gid + ts.tile_count {
                return Some((i, raw - ts.first_gid, flags));
            }
        }
        None
    }

    // ------------------------------------------------------------ edit ops

    /// Set a cell by **world** coordinate. Infinite maps grow their dense
    /// storage to fit.
    pub fn set_tile(&mut self, layer: usize, x: isize, y: isize, gid: u32) -> bool {
        if !self.in_storage(x, y) {
            let fits = x >= i32::MIN as isize && x <= i32::MAX as isize
                && y >= i32::MIN as isize && y <= i32::MAX as isize;
            if !self.infinite || !fits || !self.ensure_world_bounds(x as i32, y as i32) {
                return false;
            }
        }
        let dx = x - self.origin_x as isize;
        let dy = y - self.origin_y as isize;
        match self.tile_layer_mut(layer) {
            Some(l) => tilemap::set_tile(l, dx, dy, gid),
            None => false,
        }
    }

    /// Read a cell by **world** coordinate (0 outside the map).
    pub fn get_tile(&self, layer: usize, x: isize, y: isize) -> u32 {
        if !self.in_storage(x, y) {
            return 0;
        }
        let dx = x - self.origin_x as isize;
        let dy = y - self.origin_y as isize;
        self.tile_layer(layer)
            .map(|l| tilemap::get_tile(l, dx, dy))
            .unwrap_or(0)
    }

    /// Stamp a raw-GID pattern with its top-left at world `(x, y)`.
    pub fn stamp(&mut self, layer: usize, x: isize, y: isize, pattern: &Pattern, skip_empty: bool) -> usize {
        let mut changed = 0;
        for py in 0..pattern.h {
            for px in 0..pattern.w {
                let raw = pattern.tiles[py * pattern.w + px];
                if skip_empty && raw == 0 {
                    continue;
                }
                if self.set_tile(layer, x + px as isize, y + py as isize, raw) {
                    changed += 1;
                }
            }
        }
        changed
    }

    /// Flood fill bounded to the current dense storage, so an empty infinite
    /// plane cannot be filled without limit.
    pub fn fill(&mut self, layer: usize, x: isize, y: isize, gid: u32) -> usize {
        if !self.in_storage(x, y) {
            return 0;
        }
        let target = self.get_tile(layer, x, y);
        if target == gid {
            return 0;
        }
        let mut changed = 0;
        let mut seen = std::collections::HashSet::new();
        let mut stack = vec![(x, y)];
        while let Some((cx, cy)) = stack.pop() {
            if !self.in_storage(cx, cy) || !seen.insert((cx, cy)) {
                continue;
            }
            if self.get_tile(layer, cx, cy) != target {
                continue;
            }
            if self.set_tile(layer, cx, cy, gid) {
                changed += 1;
            }
            stack.push((cx + 1, cy));
            stack.push((cx - 1, cy));
            stack.push((cx, cy + 1));
            stack.push((cx, cy - 1));
        }
        changed
    }

    pub fn paint_rect(&mut self, layer: usize, x0: isize, y0: isize, x1: isize, y1: isize, gid: u32) -> usize {
        let (xa, xb) = (x0.min(x1), x0.max(x1));
        let (ya, yb) = (y0.min(y1), y0.max(y1));
        let mut changed = 0;
        for y in ya..=yb {
            for x in xa..=xb {
                if self.set_tile(layer, x, y, gid) {
                    changed += 1;
                }
            }
        }
        changed
    }

    /// Paint a straight inclusive line between two world cells (signed).
    pub fn paint_line(&mut self, layer: usize, x0: isize, y0: isize, x1: isize, y1: isize, gid: u32) -> usize {
        let (mut cx, mut cy) = (x0, y0);
        let dx = (x1 - x0).abs();
        let dy = (y1 - y0).abs();
        let sx = if cx < x1 { 1 } else { -1 };
        let sy = if cy < y1 { 1 } else { -1 };
        let mut err = dx - dy;
        let mut changed = 0;
        loop {
            if self.set_tile(layer, cx, cy, gid) {
                changed += 1;
            }
            if cx == x1 && cy == y1 {
                break;
            }
            let e2 = 2 * err;
            if e2 > -dy {
                err -= dy;
                cx += sx;
            }
            if e2 < dx {
                err += dx;
                cy += sy;
            }
        }
        changed
    }

    /// Copy a rectangular world region as a raw-GID pattern. Out-of-storage
    /// cells read as 0, so infinite maps copy cleanly past their content.
    pub fn read_region(&self, layer: usize, x: isize, y: isize, w: usize, h: usize) -> Pattern {
        if w == 0 || h == 0 || self.tile_layer(layer).is_none() {
            return Pattern { w: 0, h: 0, tiles: Vec::new() };
        }
        let mut tiles = vec![0u32; w * h];
        for py in 0..h {
            for px in 0..w {
                tiles[py * w + px] = self.get_tile(layer, x + px as isize, y + py as isize);
            }
        }
        Pattern { w, h, tiles }
    }

    /// Replace every tile equal to `from` by `to` across a world rect.
    pub fn replace(&mut self, layer: usize, x: isize, y: isize, w: usize, h: usize, from: u32, to: u32) -> usize {
        if w == 0 || h == 0 || self.tile_layer(layer).is_none() {
            return 0;
        }
        let mut changed = 0;
        for py in 0..h {
            for px in 0..w {
                let (cx, cy) = (x + px as isize, y + py as isize);
                if self.get_tile(layer, cx, cy) == from && self.set_tile(layer, cx, cy, to) {
                    changed += 1;
                }
            }
        }
        changed
    }

    /// Raw GID row-major data of a whole tile layer (bulk FFI ferry).
    pub fn layer_data(&self, layer: usize) -> Vec<u32> {
        self.tile_layer(layer).map(|l| l.data.clone()).unwrap_or_default()
    }

    /// 4-way same-tile region mask over the dense storage: writes 1 into `mask`
    /// (len `width*height`) for every cell reachable from world `(x, y)` sharing
    /// its raw GID. Callers translate storage indices back to world with
    /// [`TileMap::origin_x`] / [`TileMap::origin_y`].
    pub fn wand_mask(&self, layer: usize, x: isize, y: isize, mask: &mut [u8]) -> usize {
        let Some(l) = self.tile_layer(layer) else {
            return 0;
        };
        if l.width == 0 || l.height == 0 {
            return 0;
        }
        let dx = x - self.origin_x as isize;
        let dy = y - self.origin_y as isize;
        if mask.len() < l.width * l.height || !tilemap::in_layer(l, dx, dy) {
            return 0;
        }
        let target = tilemap::get_tile(l, dx, dy);
        let mut count = 0;
        let mut stack = vec![(dx, dy)];
        while let Some((cx, cy)) = stack.pop() {
            if !tilemap::in_layer(l, cx, cy) {
                continue;
            }
            let i = tilemap::cell_index(l, cx as usize, cy as usize);
            if mask[i] != 0 {
                continue;
            }
            if tilemap::get_tile(l, cx, cy) != target {
                continue;
            }
            mask[i] = 1;
            count += 1;
            stack.push((cx + 1, cy));
            stack.push((cx - 1, cy));
            stack.push((cx, cy + 1));
            stack.push((cx, cy - 1));
        }
        count
    }

    // --------------------------------------------------------- autotile

    /// Re-resolve a painted region's borders for `tileset`: every cell in the
    /// region (expanded by one so shared edges with neighbours agree) that
    /// holds a tile from `tileset` is replaced by the autotile slot for its
    /// 4-bit N/E/S/W membership mask. Empty slots leave the tile untouched.
    /// Returns the number of cells changed. Call after the host paints a
    /// stroke of "ground" tiles.
    pub fn autotile(&mut self, layer: usize, tileset: usize, x: isize, y: isize, w: usize, h: usize) -> usize {
        if w == 0 || h == 0 || self.tilesets.get(tileset).map(|t| t.autotile.is_empty()).unwrap_or(true) {
            return 0;
        }
        let Some(base) = self.tile_layer(layer) else {
            return 0;
        };
        let (map_w, map_h) = (base.width, base.height);
        if map_w == 0 || map_h == 0 {
            return 0;
        }
        // Convert the world-coordinate region start to dense storage coords.
        let x = (x - self.origin_x as isize).max(0) as usize;
        let y = (y - self.origin_y as isize).max(0) as usize;
        let data = base.data.clone();
        // Membership snapshot: a cell is "ground" when it holds any tile of
        // this tileset. Computed once so all masks agree before any write.
        let mut members = vec![false; map_w * map_h];
        for (i, gid) in data.iter().enumerate() {
            if let Some((found, _, _)) = self.gid_lookup(*gid) {
                members[i] = found == tileset;
            }
        }
        let first = self.tilesets[tileset].first_gid;
        let slots = self.tilesets[tileset].autotile.clone();
        let x0 = x.min(map_w.saturating_sub(1));
        let y0 = y.min(map_h.saturating_sub(1));
        let x1 = x.saturating_add(w.saturating_sub(1)).min(map_w.saturating_sub(1));
        let y1 = y.saturating_add(h.saturating_sub(1)).min(map_h.saturating_sub(1));
        let (r0x, r0y) = (x0.saturating_sub(1), y0.saturating_sub(1));
        let (r1x, r1y) = ((x1 + 1).min(map_w - 1), (y1 + 1).min(map_h - 1));
        let same = |members: &[bool], nx: isize, ny: isize| -> bool {
            if nx < 0 || ny < 0 {
                return false;
            }
            let (nx, ny) = (nx as usize, ny as usize);
            nx < map_w && ny < map_h && members[ny * map_w + nx]
        };
        let mut writes: Vec<(usize, u32)> = Vec::new();
        for cy in r0y..=r1y {
            for cx in r0x..=r1x {
                let i = cy * map_w + cx;
                let gid = data[i];
                if gid & GID_MASK == 0 {
                    continue;
                }
                let Some((found, _, flags)) = self.gid_lookup(gid) else {
                    continue;
                };
                if found != tileset {
                    continue;
                }
                let mask = tilemap::terrain_mask(cx as isize, cy as isize, |nx, ny| same(&members, nx, ny));
                let Some(target) = slots.get(mask as usize).copied().flatten() else {
                    continue;
                };
                let next = Self::encode_gid(target, first, flags);
                if next != gid {
                    writes.push((i, next));
                }
            }
        }
        let mut changed = 0;
        if !writes.is_empty() {
            if let Some(l) = self.tile_layer_mut(layer) {
                for (i, gid) in writes {
                    l.data[i] = gid;
                    changed += 1;
                }
            }
        }
        changed
    }

    // -------------------------------------------------------------- objects

    pub fn add_object(
        &mut self,
        layer: usize,
        name: &str,
        kind: &str,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    ) -> Option<u32> {
        let id = self.next_object_id;
        self.next_object_id += 1;
        let layer = self.object_layer_mut(layer)?;
        let point = kind.eq_ignore_ascii_case("point");
        let mut extra = Map::new();
        if point {
            extra.insert("point".into(), Value::Bool(true));
        }
        layer.objects.push(MapObject {
            id,
            name: if name.trim().is_empty() {
                format!("Object {id}")
            } else {
                name.trim().to_string()
            },
            kind: if point { String::new() } else { kind.to_string() },
            x,
            y,
            width: w.max(0.0),
            height: h.max(0.0),
            visible: true,
            properties: Vec::new(),
            extra,
        });
        Some(id)
    }

    pub fn remove_object(&mut self, layer: usize, object_id: u32) -> bool {
        let Some(layer) = self.object_layer_mut(layer) else {
            return false;
        };
        let before = layer.objects.len();
        layer.objects.retain(|o| o.id != object_id);
        before != layer.objects.len()
    }

    /// Update an object's geometry/name/type. Returns false on a bad index/id.
    #[allow(clippy::too_many_arguments)]
    pub fn set_object(
        &mut self,
        layer: usize,
        object_id: u32,
        name: &str,
        kind: &str,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    ) -> bool {
        let Some(layer) = self.object_layer_mut(layer) else {
            return false;
        };
        let Some(obj) = layer.objects.iter_mut().find(|o| o.id == object_id) else {
            return false;
        };
        if !name.trim().is_empty() {
            obj.name = name.trim().to_string();
        }
        let point = kind.eq_ignore_ascii_case("point");
        obj.kind = if point { String::new() } else { kind.to_string() };
        if point {
            obj.extra.insert("point".into(), Value::Bool(true));
        } else {
            obj.extra.remove("point");
        }
        obj.x = x;
        obj.y = y;
        obj.width = w.max(0.0);
        obj.height = h.max(0.0);
        true
    }

    // ---------------------------------------------------------- properties

    /// Replace the property list on a node. `target`: 0 map, 1 layer, 2 object.
    pub fn set_properties(
        &mut self,
        target: u8,
        layer: Option<usize>,
        object_id: Option<u32>,
        props: Vec<Property>,
    ) -> bool {
        match target {
            0 => {
                self.properties = props;
                true
            }
            1 => match self.layers.get_mut(layer.unwrap_or(usize::MAX)) {
                Some(l) => {
                    *l.properties_mut() = props;
                    true
                }
                None => false,
            },
            2 => match (layer, object_id) {
                (Some(layer), Some(id)) => match self.object_layer_mut(layer) {
                    Some(layer) => match layer.objects.iter_mut().find(|o| o.id == id) {
                        Some(obj) => {
                            obj.properties = props;
                            true
                        }
                        None => false,
                    },
                    None => false,
                },
                _ => false,
            },
            _ => false,
        }
    }

    pub fn map_properties(&self) -> &[Property] {
        &self.properties
    }

    pub fn layer_properties(&self, layer: usize) -> Option<&[Property]> {
        self.layers.get(layer).map(|l| match l {
            MapLayer::Tile(data) => data.properties.as_slice(),
            MapLayer::Objects(data) => data.properties.as_slice(),
            MapLayer::Image(data) => data.properties.as_slice(),
        })
    }

    pub fn object_properties(&self, layer: usize, object_id: u32) -> Option<&[Property]> {
        self.object_layer(layer)?
            .objects
            .iter()
            .find(|o| o.id == object_id)
            .map(|o| o.properties.as_slice())
    }

    // ------------------------------------------------------------ resize

    /// Regrid every tile layer to a new size anchored to the top-left. No-op for
    /// infinite maps, whose storage grows automatically.
    pub fn resize(&mut self, new_w: usize, new_h: usize) {
        if self.infinite {
            return;
        }
        let new_w = new_w.clamp(1, MAX_MAP_DIM);
        let new_h = new_h.clamp(1, MAX_MAP_DIM);
        if new_w == self.width && new_h == self.height {
            return;
        }
        let (copy_w, copy_h) = (self.width.min(new_w), self.height.min(new_h));
        let old_w = self.width;
        for layer in &mut self.layers {
            if let MapLayer::Tile(data) = layer {
                let mut next = vec![0u32; new_w * new_h];
                for y in 0..copy_h {
                    let s = y * old_w;
                    let d = y * new_w;
                    next[d..d + copy_w].copy_from_slice(&data.layer.data[s..s + copy_w]);
                }
                data.layer.width = new_w;
                data.layer.height = new_h;
                data.layer.data = next;
            }
        }
        self.width = new_w;
        self.height = new_h;
    }

    // ------------------------------------------------------------- export

    /// Flatten visible content into a whole-map RGBA buffer. For finite maps the
    /// buffer is `pixel_width × pixel_height`; for infinite maps it covers the
    /// current content bounds.
    pub fn composite(&self) -> Vec<u8> {
        if self.infinite {
            return match self.content_pixel_bounds() {
                Some((x, y, w, h)) => self.composite_region(x, y, w, h),
                None => Vec::new(),
            };
        }
        if self.validate_dims().is_err() {
            return Vec::new();
        }
        self.composite_region(0, 0, self.pixel_width(), self.pixel_height())
    }

    /// Composite visible content intersecting the world-pixel region
    /// `(x0, y0, w, h)` into an RGBA buffer. Infinite maps use this to render
    /// only what the viewport shows.
    pub fn composite_region(&self, x0: i64, y0: i64, w: usize, h: usize) -> Vec<u8> {
        if w == 0 || h == 0 {
            return Vec::new();
        }
        let tw = self.tile_width;
        let th = self.tile_height;
        let mut out = vec![0u8; w * h * 4];
        if tw == 0 || th == 0 {
            return out;
        }
        let mut tile_buf = vec![0u8; tw * th * 4];
        let geo = self.geometry();
        let x1 = x0 + w as i64;
        let y1 = y0 + h as i64;

        // World-cell range that can touch the region. Isometric/staggered use
        // the inverse projection; expand by 2 for tall tiles and tile offsets.
        let (mut min_cx, mut min_cy, mut max_cx, mut max_cy) = match self.orientation {
            Orientation::Orthogonal | Orientation::Hexagonal => {
                let tw_i = tw as i64;
                let th_i = th as i64;
                (
                    x0.div_euclid(tw_i),
                    y0.div_euclid(th_i),
                    (x1 - 1).div_euclid(tw_i),
                    (y1 - 1).div_euclid(th_i),
                )
            }
            _ => {
                let (mut a, mut b, mut c, mut d) = (i64::MAX, i64::MAX, i64::MIN, i64::MIN);
                for (px, py) in [
                    (x0 as f64, y0 as f64),
                    (x1 as f64, y0 as f64),
                    (x0 as f64, y1 as f64),
                    (x1 as f64, y1 as f64),
                ] {
                    let (cx, cy) = geo.pixel_to_cell(px, py);
                    a = a.min(cx);
                    b = b.min(cy);
                    c = c.max(cx);
                    d = d.max(cy);
                }
                (a - 2, b - 2, c + 2, d + 2)
            }
        };
        let (smin_x, smin_y, smax_x, smax_y) = self.storage_bounds();
        if smin_x <= smax_x && smin_y <= smax_y {
            min_cx = min_cx.max(smin_x as i64);
            min_cy = min_cy.max(smin_y as i64);
            max_cx = max_cx.min(smax_x as i64);
            max_cy = max_cy.min(smax_y as i64);
        }

        for layer in &self.layers {
            match layer {
                MapLayer::Tile(data) => {
                    if !data.visible || data.opacity <= 0.0 || data.layer.width == 0 {
                        continue;
                    }
                    let alpha = (data.opacity * 255.0).round().clamp(0.0, 255.0) as u32;
                    geo.for_each_cell_in(min_cx, min_cy, max_cx, max_cy, self.render_order, |cx, cy| {
                        let dx = cx - self.origin_x as i64;
                        let dy = cy - self.origin_y as i64;
                        if dx < 0 || dy < 0 {
                            return;
                        }
                        let i = (dy as usize) * data.layer.width + dx as usize;
                        let Some(&gid) = data.layer.data.get(i) else {
                            return;
                        };
                        if gid & GID_MASK == 0 {
                            return;
                        }
                        let Some((ts_idx, local, flags)) = self.gid_lookup(gid) else {
                            return;
                        };
                        let Some(ts) = self.tilesets.get(ts_idx) else {
                            return;
                        };
                        if !ts.tile_rgba(local, &mut tile_buf) {
                            return;
                        }
                        let (ox, oy) = geo.tile_origin(cx, cy);
                        blit_tile(
                            &mut out,
                            w,
                            h,
                            ox + ts.tile_offset.0 as i64 - x0,
                            oy + ts.tile_offset.1 as i64 - y0,
                            tw,
                            th,
                            flags,
                            alpha,
                            &tile_buf,
                        );
                    });
                }
                MapLayer::Image(data) => {
                    if !data.visible || data.opacity <= 0.0 {
                        continue;
                    }
                    let (iw, ih) = (data.image_width as usize, data.image_height as usize);
                    let (dw, dh) = (data.display_width as usize, data.display_height as usize);
                    if iw == 0 || ih == 0 || dw == 0 || dh == 0 || data.pixels.len() < iw * ih * 4 {
                        continue;
                    }
                    let alpha = (data.opacity * 255.0).round().clamp(0.0, 255.0) as u32;
                    blit_image(
                        &mut out,
                        w,
                        h,
                        data.x - x0 as f64,
                        data.y - y0 as f64,
                        iw,
                        ih,
                        dw,
                        dh,
                        alpha,
                        &data.pixels,
                    );
                }
                MapLayer::Objects(_) => {}
            }
        }
        out
    }

    /// One CSV row per map row of a tile layer's raw GIDs.
    pub fn layer_to_csv(&self, layer: usize) -> String {
        let Some(l) = self.tile_layer(layer) else {
            return String::new();
        };
        let mut lines: Vec<String> = Vec::with_capacity(l.height);
        for y in 0..l.height {
            let row: Vec<String> = (0..l.width).map(|x| l.data[y * l.width + x].to_string()).collect();
            lines.push(row.join(","));
        }
        lines.join("\n")
    }

    // ------------------------------------------------------- Tiled JSON

    /// Serialize this map to Tiled 1.10 orthogonal JSON.
    pub fn to_tiled_json(&self) -> Result<String, String> {
        serde_json::to_string(&self.to_tiled_value()).map_err(|e| e.to_string())
    }

    /// Build the full Tiled JSON `Value`; unknown preserved fields are merged
    /// under typed output so real Tiled keeps fields Bixel does not model.
    pub fn to_tiled_value(&self) -> Value {
        let mut root = self.extra.clone();
        root.insert("type".into(), json!("map"));
        root.insert("version".into(), json!("1.10"));
        root.insert("orientation".into(), json!(self.orientation.as_tiled()));
        root.insert("renderorder".into(), json!(self.render_order.as_tiled()));
        root.insert("infinite".into(), json!(self.infinite));
        root.insert("width".into(), json!(if self.infinite { 0 } else { self.width }));
        root.insert("height".into(), json!(if self.infinite { 0 } else { self.height }));
        root.insert("tilewidth".into(), json!(self.tile_width));
        root.insert("tileheight".into(), json!(self.tile_height));
        root.insert("nextlayerid".into(), json!(self.next_layer_id));
        root.insert("nextobjectid".into(), json!(self.next_object_id));
        if matches!(self.orientation, Orientation::Staggered | Orientation::Hexagonal) {
            root.insert("staggeraxis".into(), json!(self.stagger_axis.as_tiled()));
            root.insert("staggerindex".into(), json!(self.stagger_index.as_tiled()));
        }
        if !self.properties.is_empty() {
            root.insert("properties".into(), properties_json(&self.properties));
        }
        root.insert("tilesets".into(), Value::Array(self.tilesets.iter().map(tileset_json).collect()));
        root.insert("layers".into(), Value::Array(self.layers.iter().map(|l| layer_json(l, self.infinite, self.origin_x, self.origin_y)).collect()));
        Value::Object(root)
    }

    /// Parse Tiled JSON, preserving unknown fields per node.
    pub fn from_tiled_json(text: &str) -> Result<TileMap, String> {
        let value: Value = serde_json::from_str(text).map_err(|e| format!("Invalid Tiled JSON: {e}"))?;
        Self::from_tiled_value(&value)
    }

    pub fn from_tiled_value(value: &Value) -> Result<TileMap, String> {
        let get = |k: &str| value.get(k);
        if get("type").and_then(Value::as_str) != Some("map") {
            return Err("Not a Tiled map (missing \"type\": \"map\").".into());
        }
        let width = get("width").and_then(Value::as_u64).unwrap_or(0) as usize;
        let height = get("height").and_then(Value::as_u64).unwrap_or(0) as usize;
        let tile_width = get("tilewidth").and_then(Value::as_u64).unwrap_or(16) as usize;
        let tile_height = get("tileheight").and_then(Value::as_u64).unwrap_or(tile_width as u64) as usize;
        let infinite = get("infinite").and_then(Value::as_bool).unwrap_or(false)
            || get("layers")
                .and_then(Value::as_array)
                .map(|ls| ls.iter().any(|l| l.get("chunks").is_some()))
                .unwrap_or(false);
        if infinite {
            if width > MAX_MAP_DIM || height > MAX_MAP_DIM {
                return Err(format!(
                    "Map dimensions are invalid ({width} x {height}); expected at most {MAX_MAP_DIM} cells per side."
                ));
            }
        } else if width == 0 || height == 0 || width > MAX_MAP_DIM || height > MAX_MAP_DIM {
            return Err(format!(
                "Map dimensions are invalid ({width} x {height}); expected 1..={MAX_MAP_DIM} cells per side."
            ));
        }

        let orientation = match get("orientation").and_then(Value::as_str) {
            None => Orientation::Orthogonal,
            Some(s) => Orientation::from_tiled(s).ok_or_else(|| {
                format!("Unsupported map orientation {s:?}; expected orthogonal, isometric or staggered.")
            })?,
        };
        if orientation == Orientation::Hexagonal {
            return Err("Hexagonal maps are not supported yet; use orthogonal, isometric or staggered.".into());
        }
        let render_order = get("renderorder")
            .and_then(Value::as_str)
            .map(RenderOrder::from_tiled)
            .unwrap_or(RenderOrder::RightDown);
        let stagger_axis = get("staggeraxis")
            .and_then(Value::as_str)
            .map(StaggerAxis::from_tiled)
            .unwrap_or(StaggerAxis::Y);
        let stagger_index = get("staggerindex")
            .and_then(Value::as_str)
            .map(StaggerIndex::from_tiled)
            .unwrap_or(StaggerIndex::Odd);

        let mut tilesets: Vec<Tileset> = Vec::new();
        for ts in get("tilesets").and_then(Value::as_array).cloned().unwrap_or_default() {
            let mut parsed = Tileset::default();
            parsed.first_gid = ts.get("firstgid").and_then(Value::as_u64).unwrap_or(1).max(1) as u32;
            parsed.name = ts.get("name").and_then(Value::as_str).unwrap_or("").to_string();
            parsed.image = ts.get("image").and_then(Value::as_str).unwrap_or("").to_string();
            parsed.image_width = ts.get("imagewidth").and_then(Value::as_u64).unwrap_or(0) as u32;
            parsed.image_height = ts.get("imageheight").and_then(Value::as_u64).unwrap_or(0) as u32;
            parsed.tile_width = ts.get("tilewidth").and_then(Value::as_u64).unwrap_or(16) as u32;
            parsed.tile_height = ts.get("tileheight").and_then(Value::as_u64).unwrap_or(16) as u32;
            parsed.margin = ts.get("margin").and_then(Value::as_u64).unwrap_or(0) as u32;
            parsed.spacing = ts.get("spacing").and_then(Value::as_u64).unwrap_or(0) as u32;
            parsed.columns = ts.get("columns").and_then(Value::as_u64).unwrap_or(0) as u32;
            parsed.tile_count = ts.get("tilecount").and_then(Value::as_u64).unwrap_or(0) as u32;
            if let Some(offset) = ts.get("tileoffset") {
                parsed.tile_offset = (
                    offset.get("x").and_then(Value::as_i64).unwrap_or(0) as i32,
                    offset.get("y").and_then(Value::as_i64).unwrap_or(0) as i32,
                );
            }
            parsed.properties = props_from_json(ts.get("properties"));
            if (parsed.columns == 0 || parsed.tile_count == 0) && parsed.image_width > 0 {
                let (c, n) = Self::slice_tileset_math(
                    parsed.image_width, parsed.image_height,
                    parsed.tile_width, parsed.tile_height, parsed.margin, parsed.spacing,
                );
                if parsed.columns == 0 {
                    parsed.columns = c;
                }
                if parsed.tile_count == 0 {
                    parsed.tile_count = n;
                }
            }
            parsed.extra = preserve(&ts, &[
                "firstgid", "name", "image", "imagewidth", "imageheight",
                "tilewidth", "tileheight", "margin", "spacing", "columns", "tilecount", "properties",
                "tileoffset",
            ]);
            // Recover the Bixel autotile table carried as a tileset property.
            if let Some(autotile) = parsed
                .properties
                .iter()
                .find(|p| p.name == "bixel.autotile")
                .and_then(|p| p.value.as_str())
            {
                if let Ok(arr) = serde_json::from_str::<Vec<Value>>(autotile) {
                    let mut slots = vec![None; 16];
                    for (i, v) in arr.iter().enumerate().take(16) {
                        slots[i] = v.as_u64().map(|n| n as u32);
                    }
                    parsed.autotile = slots;
                }
                parsed.properties.retain(|p| p.name != "bixel.autotile");
            }
            tilesets.push(parsed);
        }

        let mut layers: Vec<MapLayer> = Vec::new();
        let mut next_layer_id = 1u32;
        let mut next_object_id = 1u32;
        // Non-empty cells of infinite tile layers, keyed by layer index. Dense
        // storage bounds are computed once after every layer is parsed.
        let mut infinite_cells: Vec<(usize, Vec<(i32, i32, u32)>)> = Vec::new();
        for raw in get("layers").and_then(Value::as_array).cloned().unwrap_or_default() {
            let kind = raw.get("type").and_then(Value::as_str).unwrap_or("");
            let id = raw.get("id").and_then(Value::as_u64).unwrap_or(0) as u32;
            let visible = raw.get("visible").and_then(Value::as_bool).unwrap_or(true);
            let opacity = raw.get("opacity").and_then(Value::as_f64).unwrap_or(1.0) as f32;
            let name = raw.get("name").and_then(Value::as_str).unwrap_or("").to_string();
            match kind {
                "tilelayer" => {
                    let id = if id >= next_layer_id { id } else { next_layer_id };
                    if id >= next_layer_id {
                        next_layer_id = id + 1;
                    }
                    if infinite {
                        // Infinite layers store sparse chunks; collect their
                        // non-empty cells and allocate dense storage afterwards.
                        let mut cells: Vec<(i32, i32, u32)> = Vec::new();
                        for chunk in raw.get("chunks").and_then(Value::as_array).cloned().unwrap_or_default() {
                            let cx = chunk.get("x").and_then(Value::as_i64).unwrap_or(0) as i32;
                            let cy = chunk.get("y").and_then(Value::as_i64).unwrap_or(0) as i32;
                            let cw = chunk.get("width").and_then(Value::as_u64).unwrap_or(16).max(1) as usize;
                            if let Some(list) = chunk.get("data").and_then(Value::as_array) {
                                for (i, g) in list.iter().enumerate() {
                                    let gid = g.as_u64().unwrap_or(0) as u32;
                                    if gid == 0 {
                                        continue;
                                    }
                                    cells.push((cx + (i % cw) as i32, cy + (i / cw) as i32, gid));
                                }
                            } else if let Some(enc) = chunk.get("data").and_then(Value::as_str) {
                                for (i, part) in enc
                                    .split([',', '\n'])
                                    .filter(|s| !s.trim().is_empty())
                                    .enumerate()
                                {
                                    let gid = part.trim().parse::<u32>().unwrap_or(0);
                                    if gid == 0 {
                                        continue;
                                    }
                                    cells.push((cx + (i % cw) as i32, cy + (i / cw) as i32, gid));
                                }
                            }
                        }
                        let extra = preserve(&raw, &[
                            "id", "name", "type", "width", "height", "data", "chunks",
                            "visible", "opacity", "properties", "x", "y", "startx", "starty",
                        ]);
                        infinite_cells.push((layers.len(), cells));
                        layers.push(MapLayer::Tile(TileLayerData {
                            id,
                            name,
                            visible,
                            opacity,
                            layer: TileLayer::new(0, 0),
                            properties: props_from_json(raw.get("properties")),
                            extra,
                        }));
                        continue;
                    }
                    let lw = raw.get("width").and_then(Value::as_u64).unwrap_or(width as u64) as usize;
                    let lh = raw.get("height").and_then(Value::as_u64).unwrap_or(height as u64) as usize;
                    if lw != width || lh != height {
                        return Err(format!(
                            "Layer \"{name}\" is {lw} x {lh} cells but the map is {width} x {height}. \
                             Infinite/chunked maps must be flattened before loading."
                        ));
                    }
                    let mut layer = TileLayer::new(lw, lh);
                    let data = raw.get("data");
                    if let Some(list) = data.and_then(Value::as_array) {
                        for (i, g) in list.iter().enumerate().take(layer.data.len()) {
                            layer.data[i] = g.as_u64().unwrap_or(0) as u32;
                        }
                    } else if let Some(enc) = data.and_then(Value::as_str) {
                        if !enc.contains(',') && !enc.contains('\n') {
                            return Err(format!(
                                "Layer \"{name}\" uses encoded (base64/compressed) tile data, which is not supported. \
                                 Re-export the map as CSV or uncompressed JSON."
                            ));
                        }
                        for (i, part) in enc
                            .split([',', '\n'])
                            .filter(|s| !s.trim().is_empty())
                            .enumerate()
                            .take(layer.data.len())
                        {
                            layer.data[i] = part.trim().parse::<u32>().unwrap_or(0);
                        }
                    }
                    let extra = preserve(&raw, &[
                        "id", "name", "type", "width", "height", "data", "chunks",
                        "visible", "opacity", "properties", "x", "y",
                    ]);
                    layers.push(MapLayer::Tile(TileLayerData {
                        id,
                        name,
                        visible,
                        opacity,
                        layer,
                        properties: props_from_json(raw.get("properties")),
                        extra,
                    }));
                }
                "objectgroup" => {
                    let mut data = ObjectLayer {
                        id: if id >= next_layer_id { id } else { next_layer_id },
                        name,
                        visible,
                        opacity,
                        objects: Vec::new(),
                        properties: props_from_json(raw.get("properties")),
                        extra: Map::new(),
                    };
                    if data.id >= next_layer_id {
                        next_layer_id = data.id + 1;
                    }
                    for obj in raw.get("objects").and_then(Value::as_array).cloned().unwrap_or_default() {
                        let oid = obj.get("id").and_then(Value::as_u64).unwrap_or(0) as u32;
                        if oid >= next_object_id {
                            next_object_id = oid + 1;
                        }
                        let point = obj.get("point").and_then(Value::as_bool).unwrap_or(false);
                        let o = MapObject {
                            id: oid,
                            name: obj.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
                            kind: obj
                                .get("type")
                                .or_else(|| obj.get("class"))
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            x: obj.get("x").and_then(Value::as_f64).unwrap_or(0.0),
                            y: obj.get("y").and_then(Value::as_f64).unwrap_or(0.0),
                            width: obj.get("width").and_then(Value::as_f64).unwrap_or(0.0),
                            height: obj.get("height").and_then(Value::as_f64).unwrap_or(0.0),
                            visible: obj.get("visible").and_then(Value::as_bool).unwrap_or(true),
                            properties: props_from_json(obj.get("properties")),
                            extra: preserve(&obj, &[
                                "id", "name", "type", "class", "x", "y", "width", "height",
                                "visible", "properties", "point",
                            ]),
                        };
                        let mut o = o;
                        if point {
                            o.extra.insert("point".into(), Value::Bool(true));
                        }
                        data.objects.push(o);
                    }
                    data.extra = preserve(&raw, &[
                        "id", "name", "type", "objects", "visible", "opacity",
                        "properties", "draworder", "x", "y",
                    ]);
                    layers.push(MapLayer::Objects(data));
                }
                "imagelayer" => {
                    let image = raw.get("image").and_then(Value::as_str).unwrap_or("").to_string();
                    let image_width = raw.get("imagewidth").and_then(Value::as_u64).unwrap_or(0) as u32;
                    let image_height = raw.get("imageheight").and_then(Value::as_u64).unwrap_or(0) as u32;
                    let id = if id >= next_layer_id { id } else { next_layer_id };
                    if id >= next_layer_id {
                        next_layer_id = id + 1;
                    }
                    let extra = preserve(&raw, &[
                        "id", "name", "type", "image", "imagewidth", "imageheight",
                        "x", "y", "visible", "opacity", "properties",
                        "bixel_display_width", "bixel_display_height",
                    ]);
                    layers.push(MapLayer::Image(ImageLayerData {
                        id,
                        name,
                        visible,
                        opacity,
                        image,
                        image_width,
                        image_height,
                        display_width: raw
                            .get("bixel_display_width")
                            .and_then(Value::as_u64)
                            .map(|v| v.min(u32::MAX as u64) as u32)
                            .unwrap_or(image_width),
                        display_height: raw
                            .get("bixel_display_height")
                            .and_then(Value::as_u64)
                            .map(|v| v.min(u32::MAX as u64) as u32)
                            .unwrap_or(image_height),
                        x: raw.get("x").and_then(Value::as_f64).unwrap_or(0.0),
                        y: raw.get("y").and_then(Value::as_f64).unwrap_or(0.0),
                        pixels: Arc::new(Vec::new()),
                        properties: props_from_json(raw.get("properties")),
                        extra,
                    }));
                }
                other => {
                    return Err(format!(
                        "Layer \"{name}\" has unsupported type {other:?}. Only tile, object and image layers are supported."
                    ))
                }
            }
        }

        let next_layer_id = get("nextlayerid")
            .and_then(Value::as_u64)
            .map(|n| n as u32)
            .unwrap_or(next_layer_id)
            .max(next_layer_id);
        let next_object_id = get("nextobjectid")
            .and_then(Value::as_u64)
            .map(|n| n as u32)
            .unwrap_or(next_object_id)
            .max(next_object_id);
        let properties = props_from_json(get("properties"));
        let extra = preserve(value, &[
            "type", "version", "orientation", "renderorder", "infinite",
            "width", "height", "tilewidth", "tileheight", "nextlayerid",
            "nextobjectid", "properties", "tilesets", "layers",
            "staggeraxis", "staggerindex",
        ]);

        // Infinite maps: derive shared dense storage bounds from the parsed
        // chunks, then fill each tile layer.
        let (mut dense_w, mut dense_h, mut origin_x, mut origin_y) = (width, height, 0i32, 0i32);
        if infinite {
            let (mut min_x, mut min_y, mut max_x, mut max_y) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
            for (_, cells) in &infinite_cells {
                for &(x, y, _) in cells {
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x);
                    max_y = max_y.max(y);
                }
            }
            if min_x > max_x {
                dense_w = 0;
                dense_h = 0;
            } else {
                origin_x = min_x;
                origin_y = min_y;
                dense_w = (max_x - min_x + 1) as usize;
                dense_h = (max_y - min_y + 1) as usize;
                if dense_w > MAX_INF_DIM || dense_h > MAX_INF_DIM {
                    return Err("Infinite scene is larger than the maximum editable area".into());
                }
            }
            for (layer_index, cells) in infinite_cells {
                if dense_w == 0 || dense_h == 0 {
                    continue;
                }
                if let Some(MapLayer::Tile(data)) = layers.get_mut(layer_index) {
                    let mut next = vec![0u32; dense_w * dense_h];
                    for (x, y, gid) in cells {
                        let dx = (x - origin_x) as usize;
                        let dy = (y - origin_y) as usize;
                        if dx < dense_w && dy < dense_h {
                            next[dy * dense_w + dx] = gid;
                        }
                    }
                    data.layer.width = dense_w;
                    data.layer.height = dense_h;
                    data.layer.data = next;
                }
            }
        }

        let map = TileMap {
            width: dense_w,
            height: dense_h,
            tile_width,
            tile_height,
            infinite,
            origin_x,
            origin_y,
            orientation,
            render_order,
            stagger_axis,
            stagger_index,
            tilesets,
            layers,
            next_layer_id,
            next_object_id,
            max_undo: MAX_UNDO,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            properties,
            extra,
        };
        Ok(map)
    }
}

// ------------------------------------------------------- JSON helpers

fn tileset_json(ts: &Tileset) -> Value {
    let mut obj = ts.extra.clone();
    merge_json(&mut obj, json!({
        "firstgid": ts.first_gid,
        "name": ts.name,
        "image": ts.image,
        "imagewidth": ts.image_width,
        "imageheight": ts.image_height,
        "tilewidth": ts.tile_width,
        "tileheight": ts.tile_height,
        "margin": ts.margin,
        "spacing": ts.spacing,
        "columns": ts.columns,
        "tilecount": ts.tile_count,
    }));
    if ts.tile_offset != (0, 0) {
        obj.insert(
            "tileoffset".into(),
            json!({ "x": ts.tile_offset.0, "y": ts.tile_offset.1 }),
        );
    }
    let mut props = ts.properties.clone();
    if ts.autotile.iter().any(Option::is_some) {
        props.push(Property {
            name: "bixel.autotile".to_string(),
            kind: "string".to_string(),
            value: Value::String(
                serde_json::to_string(&Value::Array(
                    ts.autotile.iter().map(|s| s.map(Value::from).unwrap_or(Value::Null)).collect(),
                ))
                .unwrap_or_else(|_| "[]".into()),
            ),
        });
    }
    if !props.is_empty() {
        obj.insert("properties".into(), properties_json(&props));
    }
    Value::Object(obj)
}

const CHUNK: i32 = 16;

/// Tiled infinite-layer chunks (16×16, absolute cell coords, uncompressed JSON).
fn chunks_json(origin_x: i32, origin_y: i32, width: usize, height: usize, data: &[u32]) -> Value {
    if width == 0 || height == 0 {
        return Value::Array(Vec::new());
    }
    let min_cx = origin_x.div_euclid(CHUNK);
    let max_cx = (origin_x + width as i32 - 1).div_euclid(CHUNK);
    let min_cy = origin_y.div_euclid(CHUNK);
    let max_cy = (origin_y + height as i32 - 1).div_euclid(CHUNK);
    let mut chunks = Vec::new();
    for ccy in min_cy..=max_cy {
        for ccx in min_cx..=max_cx {
            let base_x = ccx * CHUNK;
            let base_y = ccy * CHUNK;
            let mut arr: Vec<Value> = Vec::with_capacity((CHUNK * CHUNK) as usize);
            let mut any = false;
            for ly in 0..CHUNK {
                for lx in 0..CHUNK {
                    let dx = base_x + lx - origin_x;
                    let dy = base_y + ly - origin_y;
                    let gid = if dx >= 0 && dy >= 0 && (dx as usize) < width && (dy as usize) < height {
                        data[dy as usize * width + dx as usize]
                    } else {
                        0
                    };
                    if gid != 0 {
                        any = true;
                    }
                    arr.push(json!(gid));
                }
            }
            if any {
                chunks.push(json!({
                    "x": base_x,
                    "y": base_y,
                    "width": CHUNK,
                    "height": CHUNK,
                    "data": arr,
                }));
            }
        }
    }
    Value::Array(chunks)
}

fn layer_json(layer: &MapLayer, infinite: bool, origin_x: i32, origin_y: i32) -> Value {
    match layer {
        MapLayer::Tile(data) => {
            let mut obj = data.extra.clone();
            let mut base = json!({
                "id": data.id,
                "name": data.name,
                "type": "tilelayer",
                "x": 0,
                "y": 0,
                "visible": data.visible,
                "opacity": data.opacity,
            });
            if infinite {
                base["chunks"] = chunks_json(
                    origin_x,
                    origin_y,
                    data.layer.width,
                    data.layer.height,
                    &data.layer.data,
                );
            } else {
                base["width"] = json!(data.layer.width);
                base["height"] = json!(data.layer.height);
                base["data"] = json!(data.layer.data.iter().map(|g| json!(g)).collect::<Vec<_>>());
            }
            merge_json(&mut obj, base);
            if !data.properties.is_empty() {
                obj.insert("properties".into(), properties_json(&data.properties));
            }
            Value::Object(obj)
        }
        MapLayer::Objects(data) => {
            let mut obj = data.extra.clone();
            merge_json(&mut obj, json!({
                "id": data.id,
                "name": data.name,
                "type": "objectgroup",
                "draworder": "topdown",
                "x": 0,
                "y": 0,
                "visible": data.visible,
                "opacity": data.opacity,
                "objects": Value::Array(data.objects.iter().map(object_json).collect()),
            }));
            if !data.properties.is_empty() {
                obj.insert("properties".into(), properties_json(&data.properties));
            }
            Value::Object(obj)
        }
        MapLayer::Image(data) => {
            let mut obj = data.extra.clone();
            merge_json(&mut obj, json!({
                "id": data.id,
                "name": data.name,
                "type": "imagelayer",
                "image": data.image,
                "x": data.x,
                "y": data.y,
                "bixel_display_width": data.display_width,
                "bixel_display_height": data.display_height,
                "visible": data.visible,
                "opacity": data.opacity,
            }));
            if data.image_width > 0 {
                obj.insert("imagewidth".into(), json!(data.image_width));
            }
            if data.image_height > 0 {
                obj.insert("imageheight".into(), json!(data.image_height));
            }
            if !data.properties.is_empty() {
                obj.insert("properties".into(), properties_json(&data.properties));
            }
            Value::Object(obj)
        }
    }
}

fn object_json(o: &MapObject) -> Value {
    let mut obj = o.extra.clone();
    merge_json(&mut obj, json!({
        "id": o.id,
        "name": o.name,
        "x": o.x,
        "y": o.y,
        "width": o.width,
        "height": o.height,
        "visible": o.visible,
    }));
    if !o.kind.is_empty() {
        obj.insert("type".into(), json!(o.kind));
    }
    if !o.properties.is_empty() {
        obj.insert("properties".into(), properties_json(&o.properties));
    }
    Value::Object(obj)
}

fn properties_json(props: &[Property]) -> Value {
    Value::Array(
        props
            .iter()
            .map(|p| {
                let kind = if p.kind.is_empty() { prop_type(&p.value) } else { p.kind.as_str() };
                json!({ "name": p.name, "type": kind, "value": p.value.clone() })
            })
            .collect(),
    )
}

fn props_from_json(value: Option<&Value>) -> Vec<Property> {
    let mut out = Vec::new();
    if let Some(props) = value.and_then(Value::as_array) {
        for p in props {
            let name = p.get("name").and_then(Value::as_str).unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            let kind = p.get("type").and_then(Value::as_str).unwrap_or("string").to_string();
            let value = p.get("value").cloned().unwrap_or(Value::Null);
            out.push(Property { name, kind, value });
        }
    }
    out
}

fn preserve(node: &Value, known: &[&str]) -> Map<String, Value> {
    let mut extra = Map::new();
    if let Some(obj) = node.as_object() {
        for (k, v) in obj {
            if !known.contains(&k.as_str()) {
                extra.insert(k.clone(), v.clone());
            }
        }
    }
    extra
}

/// Merge a `json!({ ... })` object literal into a target map (unknown-key
/// preservation helpers build the typed output by layering literals last).
fn merge_json(base: &mut Map<String, Value>, extra: Value) {
    if let Value::Object(obj) = extra {
        for (k, v) in obj {
            base.insert(k, v);
        }
    }
}

/// Nearest-neighbour source-over blit of one tile into the map at pixel
/// `(x0, y0)`, honouring the Tiled flip flags and per-layer opacity. The
/// position may be negative (isometric diamonds overhang the canvas edges), so
/// pixels are clipped to the destination bounds.
#[allow(clippy::too_many_arguments)]
fn blit_tile(
    out: &mut [u8],
    map_px_w: usize,
    map_px_h: usize,
    x0: i64,
    y0: i64,
    tw: usize,
    th: usize,
    flags: u32,
    layer_alpha: u32,
    tile_buf: &[u8],
) {
    let flip_h = flags & GID_H_FLIP != 0;
    let flip_v = flags & GID_V_FLIP != 0;
    let flip_d = flags & GID_D_FLIP != 0;
    for y in 0..th {
        let dy = y0 + y as i64;
        if dy < 0 || dy >= map_px_h as i64 {
            continue;
        }
        for x in 0..tw {
            let dx = x0 + x as i64;
            if dx < 0 || dx >= map_px_w as i64 {
                continue;
            }
            // Map destination pixel → source pixel given the flip flags
            // (diagonal first, then horizontal/vertical — Tiled's order).
            let (mut sx, mut sy) = (x, y);
            if flip_d {
                std::mem::swap(&mut sx, &mut sy);
            }
            if flip_h {
                sx = tw - 1 - sx;
            }
            if flip_v {
                sy = th - 1 - sy;
            }
            let src = (sy * tw + sx) * 4;
            if tile_buf[src + 3] == 0 {
                continue;
            }
            let a = (tile_buf[src + 3] as u32 * layer_alpha) / 255;
            if a == 0 {
                continue;
            }
            let dst = (dy as usize * map_px_w + dx as usize) * 4;
            blend_pixel(out, dst, tile_buf[src], tile_buf[src + 1], tile_buf[src + 2], a);
        }
    }
}

/// Source-over composite one RGBA image onto the map at pixel offset `(ox, oy)`,
/// clipped to the map bounds and nearest-neighbour scaled to the display size.
fn blit_image(
    out: &mut [u8],
    map_px_w: usize,
    map_px_h: usize,
    ox: f64,
    oy: f64,
    src_w: usize,
    src_h: usize,
    dst_w: usize,
    dst_h: usize,
    layer_alpha: u32,
    src: &[u8],
) {
    let ox = ox.round() as i64;
    let oy = oy.round() as i64;
    for y in 0..dst_h {
        let dy = oy + y as i64;
        if dy < 0 || dy >= map_px_h as i64 {
            continue;
        }
        let sy = y * src_h / dst_h;
        for x in 0..dst_w {
            let dx = ox + x as i64;
            if dx < 0 || dx >= map_px_w as i64 {
                continue;
            }
            let sx = x * src_w / dst_w;
            let s = (sy * src_w + sx) * 4;
            let sa = src[s + 3] as u32;
            if sa == 0 {
                continue;
            }
            let a = sa * layer_alpha / 255;
            if a == 0 {
                continue;
            }
            let dst = (dy as usize * map_px_w + dx as usize) * 4;
            blend_pixel(out, dst, src[s], src[s + 1], src[s + 2], a);
        }
    }
}

/// Source-over blend a single pixel (`a` is the already-scaled source alpha).
fn blend_pixel(out: &mut [u8], dst: usize, sr: u8, sg: u8, sb: u8, a: u32) {
    let da = out[dst + 3] as u32;
    let oa = a + da * (255 - a) / 255;
    if da == 0 {
        out[dst] = sr;
        out[dst + 1] = sg;
        out[dst + 2] = sb;
        out[dst + 3] = a as u8;
        return;
    }
    for (c, s) in [sr, sg, sb].into_iter().enumerate() {
        let s = s as u32;
        let d = out[dst + c] as u32;
        out[dst + c] = ((s * a + d * da * (255 - a) / 255) / oa) as u8;
    }
    out[dst + 3] = oa as u8;
}

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn slice_math_basic() {
        assert_eq!(TileMap::slice_tileset_math(128, 128, 16, 16, 0, 0), (8, 64));
        assert_eq!(TileMap::slice_tileset_math(32, 64, 16, 16, 0, 0), (2, 8));
        assert_eq!(TileMap::slice_tileset_math(16, 16, 16, 16, 0, 0), (1, 1));
        assert_eq!(TileMap::slice_tileset_math(16, 16, 8, 8, 0, 0), (2, 4));
    }

    #[test]
    fn slice_math_margin_spacing() {
        assert_eq!(TileMap::slice_tileset_math(60, 60, 16, 16, 1, 2), (3, 9));
        assert_eq!(TileMap::slice_tileset_math(15, 60, 16, 16, 0, 0), (0, 0));
        assert_eq!(TileMap::slice_tileset_math(128, 128, 16, 16, 0, 0), (8, 64));
    }

    #[test]
    fn gid_flag_math() {
        let gid = TileMap::encode_gid(3, 1, GID_H_FLIP | GID_V_FLIP);
        assert_eq!(TileMap::gid_flags(gid), GID_H_FLIP | GID_V_FLIP);
        assert_eq!(gid & GID_MASK, 4);
    }
}
