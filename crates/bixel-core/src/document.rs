//! Aseprite-compatible sprite document data model.
//!
//! Headless port of `web/aseprite/document.js`. Manages cels, layers, frames,
//! tags, pixel buffers, undo/redo history and frame compositing. Pure data —
//! no rendering or I/O — so it can be unit-tested and driven from any frontend
//! (Swift/Metal, WebGPU, …).

use crate::color::Rgba;
use crate::sheet::{SheetFrame, SheetImportReport, SheetPlan};
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
///
/// Layers are owned by a single frame (see [`AsepriteDoc::frame_of_layer`]) so
/// each animation frame has an independent layer stack, Procreate-Dreams style.
/// `cels` is still one slot per frame for storage/format compatibility, but only
/// the owning frame's slot is ever populated; all others stay `None`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Layer {
    /// Stable identity, preserved across reorders/undo so the host can animate
    /// list moves. Assigned by the document when the layer is created.
    #[serde(default)]
    pub uid: u64,
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
            uid: 0,
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
    /// Owning frame of each layer, parallel to `layers`. Absent in schema-1
    /// documents saved before per-frame layers existed; reconstructed on load.
    #[serde(default)]
    frame_of_layer: Vec<usize>,
}

/// Rewrite a legacy global-layer document into per-frame layer stacks. Every
/// frame that a layer had a cel on gets its own copy of that layer, preserving
/// compositing while making the layers panel frame-accurate.
fn migrate_legacy_layers(state: &mut DocumentState) {
    let frame_count = state.frames.len();
    let old_layers = std::mem::take(&mut state.layers);
    let mut new_layers = Vec::new();
    let mut ownership = Vec::new();
    for frame in 0..frame_count {
        for old in &old_layers {
            let Some(cel) = old.cels.get(frame).and_then(|c| c.as_ref()) else { continue };
            let mut layer = old.clone();
            layer.uid = 0;
            let mut cels = vec![None; frame_count];
            cels[frame] = Some(cel.clone());
            layer.cels = cels;
            new_layers.push(layer);
            ownership.push(frame);
        }
    }
    if new_layers.is_empty() {
        if let Some(mut old) = old_layers.into_iter().next() {
            old.uid = 0;
            old.cels = vec![None; frame_count];
            new_layers.push(old);
            ownership.push(0);
        }
    }
    state.layers = new_layers;
    state.frame_of_layer = ownership;
}

/// The sprite document.
#[derive(Debug, Clone)]
pub struct AsepriteDoc {
    pub width: usize,
    pub height: usize,
    pub palette: Vec<String>,
    pub layers: Vec<Layer>,
    /// Owning frame of each entry in `layers`, parallel to it. Each frame owns
    /// an independent, ordered subset of the global layer storage.
    pub frame_of_layer: Vec<usize>,
    pub frames: Vec<Frame>,
    pub tags: Vec<Tag>,
    pub max_undo: usize,
    next_layer_uid: u64,
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
        let mut state: DocumentState = serde_json::from_value(value["document"].clone()).map_err(|e| e.to_string())?;
        let bytes = state.width.checked_mul(state.height).and_then(|n| n.checked_mul(4)).ok_or("Invalid dimensions")?;
        if state.width == 0 || state.height == 0 || bytes > 256 * 1024 * 1024 || state.layers.is_empty() || state.frames.is_empty() {
            return Err("Invalid document dimensions or empty layers/frames".into());
        }
        // Backfill ownership for schema-1 documents saved before per-frame
        // layers: expand each shared layer into a copy per frame it had a cel on.
        if state.frame_of_layer.len() != state.layers.len() {
            migrate_legacy_layers(&mut state);
        }
        for (index, layer) in state.layers.iter().enumerate() {
            if layer.cels.len() > state.frames.len() || !layer.opacity.is_finite() {
                return Err("Invalid layer".into());
            }
            if state.frame_of_layer[index] >= state.frames.len() {
                return Err("Invalid layer ownership".into());
            }
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
            frame_of_layer: Vec::new(),
            frames: Vec::new(),
            tags: Vec::new(),
            max_undo: 50,
            next_layer_uid: 1,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        };
        doc.frames.push(Frame::new(0, 125));
        let mut layer = Layer::new("Layer 1");
        layer.uid = doc.alloc_uid();
        layer.cels.push(Some(Cel::new(0, 0, width, height)));
        doc.layers.push(layer);
        doc.frame_of_layer.push(0);
        doc
    }

    fn alloc_uid(&mut self) -> u64 {
        let uid = self.next_layer_uid;
        self.next_layer_uid = self.next_layer_uid.saturating_add(1);
        uid
    }

    /// Global layer indices owned by `frame`, in stacking order (bottom first).
    pub fn frame_layers(&self, frame: usize) -> Vec<usize> {
        (0..self.layers.len())
            .filter(|&l| self.frame_of_layer.get(l) == Some(&frame))
            .collect()
    }

    /// Owning frame of a global layer index.
    pub fn layer_frame(&self, layer: usize) -> Option<usize> {
        self.frame_of_layer.get(layer).copied()
    }

    /// Append a new layer owned by `frame`. Returns its global index.
    pub fn add_layer_for_frame(&mut self, frame: usize, name: Option<&str>) -> Option<usize> {
        if frame >= self.frames.len() {
            return None;
        }
        let name = match name {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => format!("Layer {}", self.frame_layers(frame).len() + 1),
        };
        let idx = self.layers.len();
        let uid = self.alloc_uid();
        let mut layer = Layer::new(name);
        layer.uid = uid;
        layer.cels = (0..self.frames.len())
            .map(|f| if f == frame { Some(Cel::new(idx, frame, self.width, self.height)) } else { None })
            .collect();
        self.layers.push(layer);
        self.frame_of_layer.push(frame);
        Some(idx)
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

    /// Returns (and lazily creates) the cel at `(layer, frame)`. Layers are
    /// owned by a single frame, so a layer that does not belong to `frame_idx`
    /// has no cel there and this returns `None`.
    pub fn cel_mut(&mut self, layer_idx: usize, frame_idx: usize) -> Option<&mut Cel> {
        if self.frame_of_layer.get(layer_idx).copied() != Some(frame_idx) {
            return None;
        }
        let width = self.width;
        let height = self.height;
        let layer = self.layers.get_mut(layer_idx)?;
        while layer.cels.len() <= frame_idx {
            layer.cels.push(None);
        }
        if layer.cels[frame_idx].is_none() {
            layer.cels[frame_idx] = Some(Cel::new(layer_idx, frame_idx, width, height));
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

    /// Add a layer to frame 0 (legacy helper for single-frame documents).
    pub fn add_layer(&mut self, name: Option<&str>) -> usize {
        self.add_layer_for_frame(0, name).unwrap_or(0)
    }

    pub fn remove_layer(&mut self, layer_idx: usize) {
        if layer_idx < self.layers.len() {
            self.layers.remove(layer_idx);
            if layer_idx < self.frame_of_layer.len() {
                self.frame_of_layer.remove(layer_idx);
            }
            self.sync_cel_indices();
        }
    }

    pub fn reorder_layer(&mut self, from: usize, to: usize) {
        if from >= self.layers.len() || to >= self.layers.len() || from == to {
            return;
        }
        let layer = self.layers.remove(from);
        self.layers.insert(to, layer);
        if from < self.frame_of_layer.len() && to < self.frame_of_layer.len() {
            let owner = self.frame_of_layer.remove(from);
            self.frame_of_layer.insert(to, owner);
        }
        self.sync_cel_indices();
    }

    pub fn rename_layer(&mut self, layer_idx: usize, new_name: &str) {
        if let Some(layer) = self.layers.get_mut(layer_idx) {
            if !new_name.is_empty() {
                layer.name = new_name.to_string();
            }
        }
    }

    /// Append a new frame. Every existing layer grows a `None` cel slot, and the
    /// frame starts with a single fresh empty layer of its own.
    pub fn add_frame(&mut self, duration_ms: u32) -> usize {
        let new_idx = self.frames.len();
        self.frames.push(Frame::new(new_idx, duration_ms));
        for layer in self.layers.iter_mut() {
            layer.cels.push(None);
        }
        self.add_layer_for_frame(new_idx, None);
        new_idx
    }

    /// Move a complete frame, keeping its layer stack, timing, and cels together.
    /// Tags remain anchored to their timeline ranges.
    pub fn reorder_frame(&mut self, from: usize, to: usize) {
        if from >= self.frames.len() || to >= self.frames.len() || from == to {
            return;
        }
        let frame = self.frames.remove(from);
        self.frames.insert(to, frame);
        for (index, frame) in self.frames.iter_mut().enumerate() {
            frame.index = index;
        }
        for layer in &mut self.layers {
            layer.cels.resize(self.frames.len(), None);
            let cel = layer.cels.remove(from);
            layer.cels.insert(to, cel);
        }
        // Remap layer ownership so each stack follows its frame.
        for owner in self.frame_of_layer.iter_mut() {
            if *owner == from {
                *owner = to;
            } else if from < to && *owner > from && *owner <= to {
                *owner -= 1;
            } else if to < from && *owner >= to && *owner < from {
                *owner += 1;
            }
        }
        self.sync_cel_indices();
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
        // Drop every layer owned by the removed frame and shift ownership of
        // later frames down by one.
        let mut removed = Vec::new();
        for (l, owner) in self.frame_of_layer.iter_mut().enumerate() {
            if *owner == frame_idx {
                removed.push(l);
            } else if *owner > frame_idx {
                *owner -= 1;
            }
        }
        for l in removed.into_iter().rev() {
            self.layers.remove(l);
            self.frame_of_layer.remove(l);
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
            frame_of_layer: self.frame_of_layer.clone(),
        }
    }

    fn restore_state(&mut self, state: DocumentState) {
        self.width = state.width;
        self.height = state.height;
        self.palette = state.palette;
        self.layers = state.layers;
        self.frames = state.frames;
        self.tags = state.tags;
        // Reconstruct ownership when absent and guarantee every layer has a
        // unique, non-zero uid so host-side list identities survive undo.
        if state.frame_of_layer.len() == self.layers.len() {
            self.frame_of_layer = state.frame_of_layer;
        } else {
            self.frame_of_layer = self.layers.iter().map(|layer| {
                layer.cels.iter().position(|c| c.is_some()).unwrap_or(0)
            }).collect();
        }
        let mut max_uid = 0u64;
        let mut seen = std::collections::HashSet::new();
        for layer in &mut self.layers {
            if layer.uid == 0 || !seen.insert(layer.uid) {
                layer.uid = 0;
            } else {
                max_uid = max_uid.max(layer.uid);
            }
        }
        for layer in &mut self.layers {
            if layer.uid == 0 {
                max_uid += 1;
                layer.uid = max_uid;
            }
        }
        self.next_layer_uid = max_uid.saturating_add(1);
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

    /// Place pixels on a new layer owned by `frame`, clipping to the canvas, as
    /// one undo step. Returns the new layer's global index.
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
        self.snapshot();
        let index = self
            .add_layer_for_frame(frame, Some(name))
            .ok_or("Invalid destination frame")?;
        let canvas_width = self.width;
        let cel = self.cel_mut(index, frame).ok_or("Invalid layer")?;
        for dy in top..bottom {
            let source = (((dy as i64 - y as i64) as usize) * w + (left as i64 - x as i64) as usize) * 4;
            let target = (dy * canvas_width + left) * 4;
            let count = (right - left) * 4;
            cel.data[target..target + count].copy_from_slice(&data[source..source + count]);
        }
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

    /// Transform a rectangular selection in-place with nearest-neighbor
    /// sampling. The source is cleared first, then the transformed pixels are
    /// clipped to the canvas. Rotation is clockwise in quarter turns.
    pub fn transform_rect(
        &mut self, layer: usize, frame: usize,
        sx: usize, sy: usize, sw: usize, sh: usize,
        dx: i32, dy: i32, dw: usize, dh: usize, rotation: u32,
    ) -> Result<(), String> {
        if rotation > 3 { return Err("Invalid selection transform".into()); }
        self.transform_rect_angle(
            layer, frame, sx, sy, sw, sh, dx, dy, dw, dh,
            rotation as f64 * std::f64::consts::FRAC_PI_2,
        )
    }

    /// Transform a rectangular selection in-place with nearest-neighbor
    /// sampling and an arbitrary clockwise angle in radians. The destination
    /// rectangle is expected to contain the rotated source bounds.
    pub fn transform_rect_angle(
        &mut self, layer: usize, frame: usize,
        sx: usize, sy: usize, sw: usize, sh: usize,
        dx: i32, dy: i32, dw: usize, dh: usize, angle: f64,
    ) -> Result<(), String> {
        if frame >= self.frames.len() || sw == 0 || sh == 0 || dw == 0 || dh == 0
            || sx.checked_add(sw).map_or(true, |v| v > self.width)
            || sy.checked_add(sh).map_or(true, |v| v > self.height)
            || !angle.is_finite() || self.layers.get(layer).map_or(true, |l| l.locked) {
            return Err("Invalid selection transform".into());
        }
        self.snapshot();
        let source = self.layers.get(layer).and_then(|l| l.cels.get(frame)).and_then(|c| c.as_ref())
            .map(|c| c.data.clone()).unwrap_or_else(|| vec![0; self.width * self.height * 4]);
        let mut result = source.clone();
        for y in sy..sy + sh { for x in sx..sx + sw {
            let i = (y * self.width + x) * 4; result[i..i + 4].fill(0);
        }}
        let canvas_w = self.width as i64; let canvas_h = self.height as i64;
        let cos = angle.cos();
        let sin = angle.sin();
        // Only visit destination pixels that land on the canvas. Bounding the
        // loop by the canvas area keeps the work proportional to the document
        // regardless of how large the requested destination rectangle is, so a
        // huge `dw`/`dh` cannot spin or allocate unboundedly. The sampling math
        // below is unchanged for every visible pixel.
        let left = (dx as i64).max(0);
        let top = (dy as i64).max(0);
        let right = (dx as i64 + dw as i64).min(canvas_w);
        let bottom = (dy as i64 + dh as i64).min(canvas_h);
        for py in top..bottom { for px in left..right {
            let tx = px - dx as i64;
            let ty = py - dy as i64;
            let (u, v) = (tx as f64 / dw as f64, ty as f64 / dh as f64);
            let centered_u = u - 0.5;
            let centered_v = v - 0.5;
            let su = centered_u * cos + centered_v * sin + 0.5;
            let sv = -centered_u * sin + centered_v * cos + 0.5;
            if su < 0.0 || su >= 1.0 || sv < 0.0 || sv >= 1.0 { continue; }
            let ox = ((su * sw as f64).floor() as usize).min(sw - 1);
            let oy = ((sv * sh as f64).floor() as usize).min(sh - 1);
            let src_i = ((sy + oy) * self.width + sx + ox) * 4;
            let dst_i = (py as usize * self.width + px as usize) * 4;
            result[dst_i..dst_i + 4].copy_from_slice(&source[src_i..src_i + 4]);
        }}
        let cel = self.cel_mut(layer, frame).ok_or("Invalid layer")?;
        cel.data = result;
        Ok(())
    }

    /// Import a regular sheet row-major from frame zero, giving every frame its
    /// own layer (per-frame layer stacks). Existing layers and canvas dimensions
    /// are preserved; history records one step. Returns the first new layer.
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
        self.snapshot();
        let duration = self.frames.first().map_or(100, |frame| frame.duration_ms);
        while self.frames.len() < count {
            let idx = self.frames.len();
            self.frames.push(Frame::new(idx, duration));
            for existing in &mut self.layers { existing.cels.push(None); }
        }
        let mut first_layer = None;
        for frame in 0..count {
            let index = self
                .add_layer_for_frame(frame, Some(name))
                .ok_or("Invalid frame")?;
            if first_layer.is_none() { first_layer = Some(index); }
            let cel = self.cel_mut(index, frame).ok_or("Invalid layer")?;
            for row in 0..cell_h {
                let source = (((frame / columns) * cell_h + row) * w + (frame % columns) * cell_w) * 4;
                let target = row * cell_w * 4;
                cel.data[target..target + cell_w * 4].copy_from_slice(&data[source..source + cell_w * 4]);
            }
        }
        Ok(first_layer.unwrap_or(0))
    }

    /// Copy one sheet region into a canvas-sized cel, clipped to both the sheet
    /// image and the destination canvas (top-left anchored).
    fn crop_sheet_cel(
        data: &[u8],
        image_w: usize,
        image_h: usize,
        frame: &SheetFrame,
        dst_w: usize,
        dst_h: usize,
        layer_index: usize,
        frame_index: usize,
    ) -> Cel {
        let mut cel = Cel::new(layer_index, frame_index, dst_w, dst_h);
        let src_x = frame.x as usize;
        let src_y = frame.y as usize;
        if src_x >= image_w || src_y >= image_h {
            return cel;
        }
        let copy_w = (frame.width as usize).min(dst_w).min(image_w - src_x);
        let copy_h = (frame.height as usize).min(dst_h).min(image_h - src_y);
        for row in 0..copy_h {
            let source = ((src_y + row) * image_w + src_x) * 4;
            let target = row * dst_w * 4;
            cel.data[target..target + copy_w * 4]
                .copy_from_slice(&data[source..source + copy_w * 4]);
        }
        cel
    }

    /// Build a fresh document from a sheet image and its [`SheetPlan`]: the
    /// canvas is the plan's frame size, each frame becomes a timeline frame with
    /// its duration, and atlas actions become tags. This is the "import a
    /// spritesheet as a project" path.
    pub fn from_sheet(
        data: &[u8],
        image_w: usize,
        image_h: usize,
        plan: &SheetPlan,
        layer_name: &str,
    ) -> Result<Self, String> {
        Self::validate_image(data, image_w, image_h)?;
        plan.validate(image_w as u32, image_h as u32)
            .map_err(|e| e.to_string())?;
        let canvas_w = plan.canvas_width as usize;
        let canvas_h = plan.canvas_height as usize;
        let name = if layer_name.trim().is_empty() { "Sprites" } else { layer_name };

        let mut doc = AsepriteDoc::new(canvas_w, canvas_h, &[]);
        doc.frames.clear();
        doc.layers.clear();
        doc.frame_of_layer.clear();
        for (index, frame) in plan.frames.iter().enumerate() {
            doc.frames.push(Frame::new(index, frame.duration_ms.max(1)));
        }
        let total_frames = doc.frames.len();
        for (index, frame) in plan.frames.iter().enumerate() {
            let layer_index = doc.layers.len();
            let uid = doc.alloc_uid();
            let mut layer = Layer::new(name);
            layer.uid = uid;
            layer.cels = vec![None; total_frames];
            let cel = Self::crop_sheet_cel(data, image_w, image_h, frame, canvas_w, canvas_h, layer_index, index);
            layer.cels[index] = Some(cel);
            doc.layers.push(layer);
            doc.frame_of_layer.push(index);
        }
        for tag in &plan.tags {
            doc.add_tag(&tag.name, tag.from as usize, tag.to as usize, &tag.color);
        }
        Ok(doc)
    }

    /// Append a sheet plan to this document as new timeline frames on a new
    /// layer, preserving the current canvas (frames are clipped to it). When
    /// `replace` is true the existing frames are cleared first. One undo step.
    pub fn append_sheet_frames(
        &mut self,
        data: &[u8],
        image_w: usize,
        image_h: usize,
        plan: &SheetPlan,
        layer_name: &str,
        replace: bool,
    ) -> Result<SheetImportReport, String> {
        Self::validate_image(data, image_w, image_h)?;
        plan.validate(image_w as u32, image_h as u32)
            .map_err(|e| e.to_string())?;

        if replace {
            while !self.frames.is_empty() {
                let last = self.frames.len() - 1;
                self.remove_frame(last);
            }
        }

        self.snapshot();
        let base = self.frames.len();
        let name = if layer_name.trim().is_empty() { "Sprites" } else { layer_name };
        let mut first_layer = None;
        let mut tags_added = 0usize;
        for frame in plan.frames.iter() {
            let frame_index = self.add_frame(frame.duration_ms.max(1));
            // `add_frame` seeds the new frame with one empty layer; reuse it.
            let layer_index = self
                .frame_layers(frame_index)
                .into_iter()
                .next()
                .ok_or("Invalid frame")?;
            self.rename_layer(layer_index, name);
            let cel = Self::crop_sheet_cel(
                data, image_w, image_h, frame, self.width, self.height, layer_index, frame_index,
            );
            self.layers[layer_index].cels[frame_index] = Some(cel);
            if first_layer.is_none() { first_layer = Some(layer_index); }
        }
        for tag in &plan.tags {
            self.add_tag(
                &tag.name,
                base + tag.from as usize,
                base + tag.to as usize,
                &tag.color,
            );
            tags_added += 1;
        }
        Ok(SheetImportReport {
            layer: first_layer.unwrap_or(0),
            first_frame: base,
            frames_added: plan.frames.len(),
            tags_added,
        })
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

    /// Composite animation frames into a regular sheet without modifying the document.
    pub fn pack_frames(&self, columns: usize) -> Result<(Vec<u8>, usize, usize), String> {
        if columns == 0 || self.frames.is_empty() { return Err("No frames or zero columns".into()); }
        let rows = self.frames.len() / columns + usize::from(self.frames.len() % columns != 0);
        let width = self.width.checked_mul(columns).ok_or("Sheet width overflow")?;
        let height = self.height.checked_mul(rows).ok_or("Sheet height overflow")?;
        let bytes = width.checked_mul(height).and_then(|n| n.checked_mul(4)).ok_or("Sheet size overflow")?;
        if bytes == 0 || bytes > 256 * 1024 * 1024 { return Err("Sheet exceeds 256 MB".into()); }
        let mut output = vec![0; bytes];
        for frame in 0..self.frames.len() {
            let pixels = self.composite_frame(frame);
            for row in 0..self.height {
                let target = (((frame / columns) * self.height + row) * width + (frame % columns) * self.width) * 4;
                let source = row * self.width * 4;
                output[target..target + self.width * 4].copy_from_slice(&pixels[source..source + self.width * 4]);
            }
        }
        Ok((output, width, height))
    }

    /// Flatten every visible layer at `frame_idx` into a single RGBA buffer.
    ///
    /// Faithful port of `compositeFrame` — including per-layer opacity and the
    /// Aseprite blend modes.
    pub fn composite_frame(&self, frame_idx: usize) -> Vec<u8> {
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
                let cel = match self.layers[l].cels.get(frame_idx).and_then(Option::as_ref) {
                    Some(c) => c,
                    None => continue,
                };
                // Pad short legacy cel buffers before compositing.
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
