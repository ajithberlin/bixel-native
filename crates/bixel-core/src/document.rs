//! Aseprite-compatible sprite document data model.
//!
//! Headless port of `web/aseprite/document.js`. Manages cels, layers, frames,
//! tags, pixel buffers, undo/redo history and frame compositing. Pure data —
//! no rendering or I/O — so it can be unit-tested and driven from any frontend
//! (Swift/Metal, WebGPU, …).

use crate::color::Rgba;
use serde::{Serialize, Deserialize};

/// Layer blend mode. Only the modes Aseprite supports here are implemented.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlendMode {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    Addition,
    Difference,
}

impl BlendMode {
    pub fn from_str(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "multiply" => BlendMode::Multiply,
            "screen" => BlendMode::Screen,
            "overlay" => BlendMode::Overlay,
            "darken" => BlendMode::Darken,
            "lighten" => BlendMode::Lighten,
            "addition" | "add" => BlendMode::Addition,
            "difference" => BlendMode::Difference,
            _ => BlendMode::Normal,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            BlendMode::Normal => "normal",
            BlendMode::Multiply => "multiply",
            BlendMode::Screen => "screen",
            BlendMode::Overlay => "overlay",
            BlendMode::Darken => "darken",
            BlendMode::Lighten => "lighten",
            BlendMode::Addition => "addition",
            BlendMode::Difference => "difference",
        }
    }
}

/// A single cel: one image on one layer at one frame. Pixels are packed RGBA.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cel {
    pub layer_index: usize,
    pub frame_index: usize,
    pub width: usize,
    pub height: usize,
    /// RGBA bytes, `width * height * 4` long.
    pub data: Vec<u8>,
}

impl Cel {
    pub fn new(layer_index: usize, frame_index: usize, width: usize, height: usize) -> Self {
        Cel {
            layer_index,
            frame_index,
            width,
            height,
            data: vec![0; width * height * 4],
        }
    }

    pub fn with_data(
        layer_index: usize,
        frame_index: usize,
        width: usize,
        height: usize,
        data: Vec<u8>,
    ) -> Self {
        let mut data = data;
        data.resize(width * height * 4, 0);
        Cel {
            layer_index,
            frame_index,
            width,
            height,
            data,
        }
    }

    pub fn get_pixel(&self, x: usize, y: usize) -> Rgba {
        let idx = (y * self.width + x) * 4;
        Rgba {
            r: self.data[idx],
            g: self.data[idx + 1],
            b: self.data[idx + 2],
            a: self.data[idx + 3],
        }
    }

    pub fn set_pixel(&mut self, x: usize, y: usize, c: Rgba) {
        let idx = (y * self.width + x) * 4;
        self.data[idx] = c.r;
        self.data[idx + 1] = c.g;
        self.data[idx + 2] = c.b;
        self.data[idx + 3] = c.a;
    }
}

/// A layer in the document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Layer {
    pub name: String,
    pub visible: bool,
    pub locked: bool,
    /// 0.0..1.0 (matches the JS `opacity` field, which may also arrive as 0..255
    /// and is normalized during compositing).
    pub opacity: f32,
    pub blend_mode: BlendMode,
    /// One slot per frame; `None` means "empty cel" (lazily materialised).
    pub cels: Vec<Option<Cel>>,
}

impl Layer {
    pub fn new(name: impl Into<String>) -> Self {
        Layer {
            name: name.into(),
            visible: true,
            locked: false,
            opacity: 1.0,
            blend_mode: BlendMode::Normal,
            cels: Vec::new(),
        }
    }
}

/// A single animation frame.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Frame {
    pub index: usize,
    pub duration_ms: u32,
}

impl Frame {
    pub fn new(index: usize, duration_ms: u32) -> Self {
        Frame { index, duration_ms }
    }
}

/// A named range of frames (a "tag" in Aseprite terms).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tag {
    pub name: String,
    pub from: usize,
    pub to: usize,
    pub color: String,
}

impl Tag {
    pub fn new(name: impl Into<String>, from: usize, to: usize, color: impl Into<String>) -> Self {
        Tag {
            name: name.into(),
            from,
            to,
            color: color.into(),
        }
    }
}

/// A serializable snapshot used by undo/redo. Kept separate from `AsepriteDoc`
/// so a snapshot can never accidentally share the live document's stacks.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct DocumentState {
    width: usize,
    height: usize,
    palette: Vec<String>,
    layers: Vec<Layer>,
    frames: Vec<Frame>,
    tags: Vec<Tag>,
}

/// The sprite document.
#[derive(Debug, Clone)]
pub struct AsepriteDoc {
    pub width: usize,
    pub height: usize,
    pub palette: Vec<String>,
    pub layers: Vec<Layer>,
    pub frames: Vec<Frame>,
    pub tags: Vec<Tag>,
    pub max_undo: usize,
    undo_stack: Vec<DocumentState>,
    redo_stack: Vec<DocumentState>,
}

impl Default for AsepriteDoc {
    fn default() -> Self {
        Self::new(32, 32, &[])
    }
}

impl AsepriteDoc {
    /// A copy for background persistence that excludes potentially large undo stacks.
    pub fn persistence_copy(&self) -> Self {
        let mut doc = Self::new(1, 1, &[]);
        doc.restore_state(self.serialize_state());
        doc
    }

    /// Versioned, lossless document persistence; undo buffers are intentionally excluded.
    pub fn to_json(&self) -> Result<String, String> {
        serde_json::to_string(&serde_json::json!({"schema":1,"document":self.serialize_state()})).map_err(|e| e.to_string())
    }

    pub fn from_json(text: &str) -> Result<Self, String> {
        let value: serde_json::Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if value["schema"] != 1 { return Err("Unsupported document version".into()); }
        let state: DocumentState = serde_json::from_value(value["document"].clone()).map_err(|e| e.to_string())?;
        let bytes = state.width.checked_mul(state.height).and_then(|n| n.checked_mul(4)).ok_or("Invalid dimensions")?;
        if state.width == 0 || state.height == 0 || bytes > 256 * 1024 * 1024 || state.layers.is_empty() || state.frames.is_empty() {
            return Err("Invalid document dimensions or empty layers/frames".into());
        }
        for layer in &state.layers {
            if layer.cels.len() > state.frames.len() || !layer.opacity.is_finite() { return Err("Invalid layer".into()); }
            for cel in layer.cels.iter().flatten() {
                if cel.width != state.width || cel.height != state.height || cel.data.len() != bytes { return Err("Invalid cel dimensions or data".into()); }
            }
        }
        for (index, frame) in state.frames.iter().enumerate() {
            if frame.index != index || frame.duration_ms == 0 { return Err("Invalid frame".into()); }
        }
        for tag in &state.tags {
            if tag.from > tag.to || tag.to >= state.frames.len() { return Err("Invalid tag".into()); }
        }
        let mut doc = Self::new(1, 1, &[]);
        doc.restore_state(state);
        Ok(doc)
    }

    pub fn new(width: usize, height: usize, palette: &[String]) -> Self {
        let width = width.max(1);
        let height = height.max(1);
        let mut doc = AsepriteDoc {
            width,
            height,
            palette: palette.to_vec(),
            layers: Vec::new(),
            frames: Vec::new(),
            tags: Vec::new(),
            max_undo: 50,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        };
        doc.frames.push(Frame::new(0, 125));
        let mut layer = Layer::new("Layer 1");
        layer.cels.push(Some(Cel::new(0, 0, width, height)));
        doc.layers.push(layer);
        doc
    }

    fn sync_cel_indices(&mut self) {
        for (l, layer) in self.layers.iter_mut().enumerate() {
            for (f, cel) in layer.cels.iter_mut().enumerate() {
                if let Some(cel) = cel {
                    cel.layer_index = l;
                    cel.frame_index = f;
                }
            }
        }
    }

    /// Returns (and lazily creates) the cel at `(layer, frame)`.
    pub fn cel_mut(&mut self, layer_idx: usize, frame_idx: usize) -> Option<&mut Cel> {
        let layer = self.layers.get_mut(layer_idx)?;
        while layer.cels.len() <= frame_idx {
            layer.cels.push(None);
        }
        if layer.cels[frame_idx].is_none() {
            layer.cels[frame_idx] = Some(Cel::new(layer_idx, frame_idx, self.width, self.height));
        }
        layer.cels[frame_idx].as_mut()
    }

    pub fn set_pixel(&mut self, layer_idx: usize, frame_idx: usize, x: usize, y: usize, c: Rgba) {
        if x >= self.width || y >= self.height {
            return;
        }
        if let Some(cel) = self.cel_mut(layer_idx, frame_idx) {
            cel.set_pixel(x, y, c);
        }
    }

    pub fn get_pixel(&self, layer_idx: usize, frame_idx: usize, x: usize, y: usize) -> Rgba {
        if x >= self.width || y >= self.height {
            return Rgba::TRANSPARENT;
        }
        let Some(layer) = self.layers.get(layer_idx) else {
            return Rgba::TRANSPARENT;
        };
        let Some(Some(cel)) = layer.cels.get(frame_idx) else {
            return Rgba::TRANSPARENT;
        };
        cel.get_pixel(x, y)
    }

    pub fn add_layer(&mut self, name: Option<&str>) -> usize {
        let name = match name {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => format!("Layer {}", self.layers.len() + 1),
        };
        let idx = self.layers.len();
        let mut layer = Layer::new(name);
        layer.cels = (0..self.frames.len())
            .map(|f| Some(Cel::new(idx, f, self.width, self.height)))
            .collect();
        self.layers.push(layer);
        idx
    }

    pub fn remove_layer(&mut self, layer_idx: usize) {
        if layer_idx < self.layers.len() {
            self.layers.remove(layer_idx);
            self.sync_cel_indices();
        }
    }

    pub fn reorder_layer(&mut self, from: usize, to: usize) {
        if from >= self.layers.len() || to >= self.layers.len() || from == to {
            return;
        }
        let layer = self.layers.remove(from);
        self.layers.insert(to, layer);
        self.sync_cel_indices();
    }

    pub fn rename_layer(&mut self, layer_idx: usize, new_name: &str) {
        if let Some(layer) = self.layers.get_mut(layer_idx) {
            if !new_name.is_empty() {
                layer.name = new_name.to_string();
            }
        }
    }

    pub fn add_frame(&mut self, duration_ms: u32) -> usize {
        let new_idx = self.frames.len();
        self.frames.push(Frame::new(new_idx, duration_ms));
        for (l, layer) in self.layers.iter_mut().enumerate() {
            layer
                .cels
                .push(Some(Cel::new(l, new_idx, self.width, self.height)));
        }
        new_idx
    }

    pub fn remove_frame(&mut self, frame_idx: usize) {
        if frame_idx >= self.frames.len() {
            return;
        }
        self.frames.remove(frame_idx);
        for (i, frame) in self.frames.iter_mut().enumerate() {
            frame.index = i;
        }
        for layer in &mut self.layers {
            if frame_idx < layer.cels.len() {
                layer.cels.remove(frame_idx);
            }
        }
        self.sync_cel_indices();

        let mut i = self.tags.len();
        while i > 0 {
            i -= 1;
            let tag = &mut self.tags[i];
            if tag.from > frame_idx {
                tag.from = tag.from.saturating_sub(1);
            }
            if tag.to >= frame_idx {
                tag.to = tag.to.saturating_sub(1);
            }
            if tag.from >= self.frames.len() || tag.from > tag.to {
                self.tags.remove(i);
            }
        }
    }

    pub fn add_tag(&mut self, name: &str, from: usize, to: usize, color: &str) {
        let tag = Tag::new(name, from, to, color);
        if let Some(existing) = self.tags.iter_mut().find(|t| t.name == name) {
            *existing = tag;
        } else {
            self.tags.push(tag);
        }
    }

    pub fn remove_tag(&mut self, name: &str) {
        self.tags.retain(|t| t.name != name);
    }

    fn serialize_state(&self) -> DocumentState {
        DocumentState {
            width: self.width,
            height: self.height,
            palette: self.palette.clone(),
            layers: self.layers.clone(),
            frames: self.frames.clone(),
            tags: self.tags.clone(),
        }
    }

    fn restore_state(&mut self, state: DocumentState) {
        self.width = state.width;
        self.height = state.height;
        self.palette = state.palette;
        self.layers = state.layers;
        self.frames = state.frames;
        self.tags = state.tags;
        self.sync_cel_indices();
    }

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

    pub fn resize(&mut self, new_w: usize, new_h: usize) {
        let new_w = new_w.max(1);
        let new_h = new_h.max(1);
        if new_w == self.width && new_h == self.height {
            return;
        }
        let (old_w, old_h) = (self.width, self.height);
        self.width = new_w;
        self.height = new_h;

        let copy_w = old_w.min(new_w);
        let copy_h = old_h.min(new_h);

        for layer in &mut self.layers {
            for cel in layer.cels.iter_mut().flatten() {
                let old_data = std::mem::take(&mut cel.data);
                let mut new_data = vec![0u8; new_w * new_h * 4];
                for y in 0..copy_h {
                    let old_offset = y * old_w * 4;
                    let new_offset = y * new_w * 4;
                    let row = copy_w * 4;
                    new_data[new_offset..new_offset + row]
                        .copy_from_slice(&old_data[old_offset..old_offset + row]);
                }
                cel.width = new_w;
                cel.height = new_h;
                cel.data = new_data;
            }
        }
    }

    /// Replace the cel at `(layer, frame)` with the given RGBA buffer.
    pub fn load_image_data(
        &mut self,
        data: &[u8],
        w: usize,
        h: usize,
        layer_idx: usize,
        frame_idx: usize,
    ) {
        if w != self.width || h != self.height {
            self.resize(w, h);
        }
        if let Some(cel) = self.cel_mut(layer_idx, frame_idx) {
            let len = cel.data.len().min(data.len());
            cel.data[..len].copy_from_slice(&data[..len]);
        }
    }

    fn validate_image(data: &[u8], w: usize, h: usize) -> Result<(), String> {
        let bytes = w.checked_mul(h).and_then(|n| n.checked_mul(4));
        if w == 0 || h == 0 || bytes != Some(data.len()) || data.len() > 256 * 1024 * 1024 {
            return Err("Invalid RGBA image dimensions or buffer length".into());
        }
        Ok(())
    }

    /// Place pixels on a new layer, clipping to the canvas, as one undo step.
    pub fn place_image_data(
        &mut self, data: &[u8], w: usize, h: usize, x: i32, y: i32,
        frame: usize, name: &str,
    ) -> Result<usize, String> {
        Self::validate_image(data, w, h)?;
        if frame >= self.frames.len() { return Err("Invalid destination frame".into()); }
        let left = (x as i64).max(0) as usize;
        let top = (y as i64).max(0) as usize;
        let right = ((x as i64) + w as i64).min(self.width as i64).max(0) as usize;
        let bottom = ((y as i64) + h as i64).min(self.height as i64).max(0) as usize;
        if left >= right || top >= bottom { return Err("Image is outside the canvas".into()); }
        let index = self.layers.len();
        let mut layer = Layer::new(name);
        layer.cels.resize(self.frames.len(), None);
        let mut cel = Cel::new(index, frame, self.width, self.height);
        for dy in top..bottom {
            let source = (((dy as i64 - y as i64) as usize) * w + (left as i64 - x as i64) as usize) * 4;
            let target = (dy * self.width + left) * 4;
            let count = (right - left) * 4;
            cel.data[target..target + count].copy_from_slice(&data[source..source + count]);
        }
        layer.cels[frame] = Some(cel);
        self.snapshot();
        self.layers.push(layer);
        Ok(index)
    }

    /// Replace an image-sized region on an existing layer. The host snapshots once per stroke.
    pub fn stamp_image_data(
        &mut self, data: &[u8], w: usize, h: usize, x: i32, y: i32,
        layer: usize, frame: usize,
    ) -> Result<(), String> {
        Self::validate_image(data, w, h)?;
        if frame >= self.frames.len() || self.layers.get(layer).map_or(true, |l| l.locked) {
            return Err("Invalid frame or unavailable destination layer".into());
        }
        let left = (x as i64).max(0) as usize;
        let top = (y as i64).max(0) as usize;
        let right = ((x as i64) + w as i64).min(self.width as i64).max(0) as usize;
        let bottom = ((y as i64) + h as i64).min(self.height as i64).max(0) as usize;
        if left >= right || top >= bottom { return Err("Image is outside the canvas".into()); }
        let canvas_width = self.width;
        let cel = self.cel_mut(layer, frame).ok_or("Invalid layer")?;
        for dy in top..bottom {
            let source = (((dy as i64 - y as i64) as usize) * w + (left as i64 - x as i64) as usize) * 4;
            let target = (dy * canvas_width + left) * 4;
            let count = (right - left) * 4;
            cel.data[target..target + count].copy_from_slice(&data[source..source + count]);
        }
        Ok(())
    }

    /// Import a regular sheet to a new layer, row-major from frame zero.
    /// Existing layers and canvas dimensions are preserved; history records one step.
    pub fn import_sheet_data(
        &mut self, data: &[u8], w: usize, h: usize,
        cell_w: usize, cell_h: usize, name: &str,
    ) -> Result<usize, String> {
        Self::validate_image(data, w, h)?;
        if cell_w == 0 || cell_h == 0 || cell_w != self.width || cell_h != self.height {
            return Err("Sheet cell dimensions must match the canvas".into());
        }
        if w % cell_w != 0 || h % cell_h != 0 {
            return Err("Sheet dimensions must be divisible by the cell size".into());
        }
        let columns = w / cell_w;
        let count = columns * (h / cell_h);
        if count > 4096 { return Err("Sheet exceeds 4096 frames".into()); }
        let index = self.layers.len();
        let mut layer = Layer::new(name);
        layer.cels.resize(self.frames.len().max(count), None);
        for frame in 0..count {
            let mut cel = Cel::new(index, frame, cell_w, cell_h);
            for row in 0..cell_h {
                let source = (((frame / columns) * cell_h + row) * w + (frame % columns) * cell_w) * 4;
                let target = row * cell_w * 4;
                cel.data[target..target + cell_w * 4].copy_from_slice(&data[source..source + cell_w * 4]);
            }
            layer.cels[frame] = Some(cel);
        }
        self.snapshot();
        let duration = self.frames.first().map_or(100, |frame| frame.duration_ms);
        while self.frames.len() < count {
            self.frames.push(Frame::new(self.frames.len(), duration));
        }
        for existing in &mut self.layers { existing.cels.resize(self.frames.len(), None); }
        self.layers.push(layer);
        Ok(index)
    }

    /// Draw a polyline stroke with a round brush of the given radius.
    ///
    /// `radius == 0` is a single-pixel pencil. This is the "Swift sends a list
    /// of points, Rust rasterises a whole stroke" entry point — a single FFI
    /// call per gesture, never per-pixel.
    pub fn draw_stroke(
        &mut self,
        layer_idx: usize,
        frame_idx: usize,
        points: &[(usize, usize)],
        color: Rgba,
        radius: u32,
    ) {
        if points.is_empty() {
            return;
        }
        if points.len() == 1 {
            let (x, y) = points[0];
            self.stamp_disc(layer_idx, frame_idx, x, y, radius, color);
            return;
        }
        for w in points.windows(2) {
            for (x, y) in line_points(w[0], w[1]) {
                self.stamp_disc(layer_idx, frame_idx, x, y, radius, color);
            }
        }
    }

    fn stamp_disc(
        &mut self,
        layer_idx: usize,
        frame_idx: usize,
        cx: usize,
        cy: usize,
        radius: u32,
        color: Rgba,
    ) {
        if radius == 0 {
            self.set_pixel(layer_idx, frame_idx, cx, cy, color);
            return;
        }
        // A pixel-perfect disc: include a pixel when its centre is within
        // (radius - 0.5) so a radius of 1 is a single pixel, 2 is a 3x3 round,
        // etc.
        let r = radius as f64 - 0.5;
        let r2 = r * r;
        let r_int = radius as i64;
        for dy in -r_int..=r_int {
            for dx in -r_int..=r_int {
                let dxf = dx as f64;
                let dyf = dy as f64;
                if dxf * dxf + dyf * dyf <= r2 {
                    let x = cx as i64 + dx;
                    let y = cy as i64 + dy;
                    if x >= 0 && y >= 0 {
                        self.set_pixel(layer_idx, frame_idx, x as usize, y as usize, color);
                    }
                }
            }
        }
    }

    /// 4-way flood fill at `(x, y)` replacing the target color with `color`.
    /// Returns the number of pixels changed.
    pub fn flood_fill(
        &mut self,
        layer_idx: usize,
        frame_idx: usize,
        x: usize,
        y: usize,
        color: Rgba,
    ) -> usize {
        if x >= self.width || y >= self.height {
            return 0;
        }
        let target = self.get_pixel(layer_idx, frame_idx, x, y);
        if target == color {
            return 0;
        }
        let mut count = 0usize;
        let mut stack: Vec<(isize, isize)> = vec![(x as isize, y as isize)];
        let mut seen = vec![false; self.width * self.height];
        while let Some((cx, cy)) = stack.pop() {
            if cx < 0 || cy < 0 || (cx as usize) >= self.width || (cy as usize) >= self.height {
                continue;
            }
            let (cxu, cyu) = (cx as usize, cy as usize);
            let key = cyu * self.width + cxu;
            if seen[key] {
                continue;
            }
            seen[key] = true;
            if self.get_pixel(layer_idx, frame_idx, cxu, cyu) != target {
                continue;
            }
            self.set_pixel(layer_idx, frame_idx, cxu, cyu, color);
            count += 1;
            stack.push((cx + 1, cy));
            stack.push((cx - 1, cy));
            stack.push((cx, cy + 1));
            stack.push((cx, cy - 1));
        }
        count
    }

    /// Flatten every visible layer at `frame_idx` into a single RGBA buffer.
    ///
    /// Faithful port of `compositeFrame` — including per-layer opacity and the
    /// Aseprite blend modes.
    pub fn composite_frame(&mut self, frame_idx: usize) -> Vec<u8> {
        let len = self.width * self.height * 4;
        let mut output = vec![0u8; len];

        for l in 0..self.layers.len() {
            let (visible, opacity, blend) = {
                let layer = &self.layers[l];
                if !layer.visible {
                    continue;
                }
                let mut opacity = layer.opacity;
                if opacity > 1.0 {
                    opacity /= 255.0;
                }
                if opacity <= 0.0 {
                    continue;
                }
                (true, opacity, layer.blend_mode)
            };
            let _ = visible;

            let src = {
                let cel = match self.cel_mut(l, frame_idx) {
                    Some(c) => c,
                    None => continue,
                };
                // Clone the pixels we need while releasing the mutable borrow of
                // `self` so the per-pixel loop below can keep `output` local.
                let mut buf = vec![0u8; len];
                let take = len.min(cel.data.len());
                buf[..take].copy_from_slice(&cel.data[..take]);
                buf
            };

            for i in (0..len).step_by(4) {
                let sr = src[i] as u32;
                let sg = src[i + 1] as u32;
                let sb = src[i + 2] as u32;
                let sa = src[i + 3] as u32;

                if sa == 0 {
                    continue;
                }

                let src_alpha = (sa as f32 / 255.0) * opacity;
                if src_alpha <= 0.0 {
                    continue;
                }

                let dr = output[i] as u32;
                let dg = output[i + 1] as u32;
                let db = output[i + 2] as u32;
                let da = output[i + 3] as u32;

                if da == 0 {
                    output[i] = sr as u8;
                    output[i + 1] = sg as u8;
                    output[i + 2] = sb as u8;
                    output[i + 3] = (src_alpha * 255.0).round() as u8;
                    continue;
                }

                let dst_alpha = da as f32 / 255.0;
                let out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha);
                if out_alpha <= 0.0 {
                    continue;
                }

                let (br, bg, bb) = blend_channels(blend, sr, sg, sb, dr, dg, db);

                let p1 = src_alpha * (1.0 - dst_alpha);
                let p2 = dst_alpha * (1.0 - src_alpha);
                let p3 = src_alpha * dst_alpha;

                output[i] = ((p1 * sr as f32 + p2 * dr as f32 + p3 * br as f32) / out_alpha)
                    .round()
                    .clamp(0.0, 255.0) as u8;
                output[i + 1] = ((p1 * sg as f32 + p2 * dg as f32 + p3 * bg as f32) / out_alpha)
                    .round()
                    .clamp(0.0, 255.0) as u8;
                output[i + 2] = ((p1 * sb as f32 + p2 * db as f32 + p3 * bb as f32) / out_alpha)
                    .round()
                    .clamp(0.0, 255.0) as u8;
                output[i + 3] = (out_alpha * 255.0).round().clamp(0.0, 255.0) as u8;
            }
        }

        output
    }
}

#[inline]
fn blend_channels(mode: BlendMode, sr: u32, sg: u32, sb: u32, dr: u32, dg: u32, db: u32) -> (u32, u32, u32) {
    match mode {
        BlendMode::Multiply => ((sr * dr) / 255, (sg * dg) / 255, (sb * db) / 255),
        BlendMode::Screen => (
            255 - ((255 - sr) * (255 - dr)) / 255,
            255 - ((255 - sg) * (255 - dg)) / 255,
            255 - ((255 - sb) * (255 - db)) / 255,
        ),
        BlendMode::Overlay => (
            if dr < 128 { (2 * dr * sr) / 255 } else { 255 - (2 * (255 - dr) * (255 - sr)) / 255 },
            if dg < 128 { (2 * dg * sg) / 255 } else { 255 - (2 * (255 - dg) * (255 - sg)) / 255 },
            if db < 128 { (2 * db * sb) / 255 } else { 255 - (2 * (255 - db) * (255 - sb)) / 255 },
        ),
        BlendMode::Darken => (sr.min(dr), sg.min(dg), sb.min(db)),
        BlendMode::Lighten => (sr.max(dr), sg.max(dg), sb.max(db)),
        BlendMode::Addition => (255.min(sr + dr), 255.min(sg + dg), 255.min(sb + db)),
        BlendMode::Difference => (dr.abs_diff(sr), dg.abs_diff(sg), db.abs_diff(sb)),
        BlendMode::Normal => (sr, sg, sb),
    }
}

/// Bresenham line between two integer points (inclusive of both endpoints).
fn line_points(a: (usize, usize), b: (usize, usize)) -> Vec<(usize, usize)> {
    let mut pts = Vec::new();
    let (mut x0, mut y0) = (a.0 as isize, a.1 as isize);
    let (x1, y1) = (b.0 as isize, b.1 as isize);
    let dx = (x1 - x0).abs();
    let dy = -(y1 - y0).abs();
    let sx: isize = if x0 < x1 { 1 } else { -1 };
    let sy: isize = if y0 < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    loop {
        pts.push((x0 as usize, y0 as usize));
        if x0 == x1 && y0 == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x0 += sx;
        }
        if e2 <= dx {
            err += dx;
            y0 += sy;
        }
    }
    pts
}
