//! Sprite-sheet import planning.
//!
//! A sheet arrives as raw RGBA plus a JSON manifest. Three manifest shapes are
//! recognized and normalized into a [`SheetPlan`] (canvas size + frame rects +
//! tags) that the document importer can apply without re-parsing:
//!
//! * **Bixel export** — the round-trip form written by `exportSpriteSheet`:
//!   `{ frame_width, frame_height, columns, frames: [{x,y,width,height,duration_ms}] }`.
//! * **Atlas / actions** — the packer/player schema validated by [`crate::atlas`]:
//!   `{ size, cell, actions: { name: { frames: [{x,y,w,h,...}] } } }`. Each action
//!   becomes a timeline tag.
//! * **Grid** — `{ cell: {w,h}, cols, rows, margin, spacing }` or explicit
//!   `cell_width`/`cell_height` parameters.
//!
//! This module is pure data (no codecs, no I/O) so it is testable under
//! `cargo test` and shared by both the file importer and the AI skill registry.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Hard cap on imported frames, mirroring `import_sheet_data`.
pub const MAX_FRAMES: usize = 4096;
const MAX_BYTES: u64 = 256 * 1024 * 1024;
const DEFAULT_DURATION_MS: u32 = 100;

/// Default tag colors, cycled by tag order when an atlas action omits one.
const TAG_COLORS: [&str; 6] = ["#ff6b6b", "#4ecdc4", "#ffd93d", "#a78bfa", "#6bcb77", "#ff9f45"];

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum SheetError {
    #[error("sheet manifest is not valid JSON: {0}")]
    Json(String),
    #[error("{0}")]
    Invalid(String),
}

impl SheetError {
    fn invalid(msg: impl Into<String>) -> Self {
        SheetError::Invalid(msg.into())
    }
}

/// Where a plan's geometry came from (surfaced in previews / UI).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SheetSource {
    BixelExport,
    Atlas,
    Grid,
}

/// One sprite region on the sheet, in image pixel coordinates.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SheetFrame {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub duration_ms: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
}

/// A named frame range, applied as a timeline tag.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SheetTag {
    pub name: String,
    pub from: u32,
    pub to: u32,
    pub color: String,
}

/// Normalized import plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SheetPlan {
    pub canvas_width: u32,
    pub canvas_height: u32,
    pub frames: Vec<SheetFrame>,
    pub tags: Vec<SheetTag>,
    pub source: SheetSource,
}

/// Result of appending a plan to an existing document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SheetImportReport {
    pub layer: usize,
    pub first_frame: usize,
    pub frames_added: usize,
    pub tags_added: usize,
}

fn number(obj: &Value, keys: &[&str]) -> Option<u32> {
    for key in keys {
        if let Some(n) = obj.get(*key).and_then(Value::as_u64) {
            if n <= u32::MAX as u64 {
                return Some(n as u32);
            }
        }
    }
    None
}

fn rect(frame: &Value, default_w: u32, default_h: u32) -> Result<(u32, u32, u32, u32), SheetError> {
    let x = number(frame, &["x"]).unwrap_or(0);
    let y = number(frame, &["y"]).unwrap_or(0);
    let w = number(frame, &["w", "width"]).unwrap_or(default_w);
    let h = number(frame, &["h", "height"]).unwrap_or(default_h);
    if w == 0 || h == 0 {
        return Err(SheetError::invalid("sheet frame has a zero width or height"));
    }
    Ok((x, y, w, h))
}

fn duration(frame: &Value) -> u32 {
    number(frame, &["duration_ms", "duration"])
        .filter(|d| *d > 0)
        .unwrap_or(DEFAULT_DURATION_MS)
}

fn pair(obj: &Value, keys: [&str; 2]) -> Option<(u32, u32)> {
    let a = number(obj, &[keys[0], if keys[0] == "w" { "width" } else { keys[0] }])?;
    let b = number(obj, &[keys[1], if keys[1] == "h" { "height" } else { keys[1] }])?;
    Some((a, b))
}

/// Canvas priority for grouped atlas manifests: explicit `cell` (frame size),
/// then `size` (image size), then the frame defaults, then the image itself.
fn atlas_canvas(value: &Value, image_w: u32, image_h: u32, fallback_w: u32, fallback_h: u32) -> (u32, u32) {
    if let Some(cell) = value.get("cell") {
        if let Some((w, h)) = pair(cell, ["w", "h"]) {
            return (w.max(1), h.max(1));
        }
    }
    if let Some(size) = value.get("size") {
        if let Some((w, h)) = pair(size, ["w", "h"]) {
            return (w.max(1), h.max(1));
        }
    }
    if fallback_w > 0 && fallback_h > 0 {
        return (fallback_w, fallback_h);
    }
    (image_w.max(1), image_h.max(1))
}

impl SheetPlan {
    /// Parse a manifest against the decoded image dimensions.
    pub fn from_json(value: &Value, image_w: u32, image_h: u32) -> Result<Self, SheetError> {
        if !value.is_object() {
            return Err(SheetError::invalid("sheet manifest must be a JSON object"));
        }

        if let Some(actions) = value.get("actions") {
            return Self::from_actions(value, actions, image_w, image_h);
        }

        if let Some(frames) = value.get("frames").and_then(Value::as_array) {
            if !frames.is_empty() {
                return Self::from_flat_frames(value, frames, image_w, image_h);
            }
        }

        let has_grid = value.get("cell").is_some()
            || value.get("cell_width").is_some()
            || value.get("cell_height").is_some()
            || value.get("cols").is_some()
            || value.get("rows").is_some();
        if has_grid {
            return Self::from_grid_value(value, image_w, image_h);
        }

        Err(SheetError::invalid("sheet manifest has no frames, actions, or cell grid"))
    }

    /// Parse from a JSON string.
    pub fn from_json_str(text: &str, image_w: u32, image_h: u32) -> Result<Self, SheetError> {
        let value: Value = serde_json::from_str(text).map_err(|e| SheetError::Json(e.to_string()))?;
        Self::from_json(&value, image_w, image_h)
    }

    fn from_flat_frames(
        value: &Value,
        frames: &[Value],
        image_w: u32,
        image_h: u32,
    ) -> Result<Self, SheetError> {
        let frame_w = number(value, &["frame_width", "cell_width"]).unwrap_or(0);
        let frame_h = number(value, &["frame_height", "cell_height"]).unwrap_or(0);
        let mut out = Vec::with_capacity(frames.len());
        for frame in frames {
            let (x, y, w, h) = rect(frame, frame_w, frame_h)?;
            out.push(SheetFrame {
                x,
                y,
                width: w,
                height: h,
                duration_ms: duration(frame),
                tag: frame.get("tag").and_then(Value::as_str).map(str::to_string),
            });
        }
        let fallback_w = out.iter().map(|f| f.width).max().unwrap_or(0);
        let fallback_h = out.iter().map(|f| f.height).max().unwrap_or(0);
        let (canvas_width, canvas_height) =
            atlas_canvas(value, image_w, image_h, frame_w.max(fallback_w), frame_h.max(fallback_h));
        let plan = SheetPlan {
            canvas_width,
            canvas_height,
            frames: out,
            tags: Vec::new(),
            source: SheetSource::BixelExport,
        };
        plan.validate(image_w, image_h)?;
        Ok(plan)
    }

    fn from_actions(
        value: &Value,
        actions: &Value,
        image_w: u32,
        image_h: u32,
    ) -> Result<Self, SheetError> {
        let cell = value.get("cell");
        let default_w = cell.and_then(|c| number(c, &["w", "width"])).or_else(|| number(value, &["frame_width"])).unwrap_or(0);
        let default_h = cell.and_then(|c| number(c, &["h", "height"])).or_else(|| number(value, &["frame_height"])).unwrap_or(0);

        let entries: Vec<(String, Value)> = if let Some(obj) = actions.as_object() {
            obj.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
        } else if let Some(arr) = actions.as_array() {
            arr.iter()
                .filter_map(|action| {
                    let name = action.get("name").and_then(Value::as_str)?.to_string();
                    Some((name, action.clone()))
                })
                .collect()
        } else {
            return Err(SheetError::invalid("atlas.actions must be an object or array"));
        };
        if entries.is_empty() {
            return Err(SheetError::invalid("atlas.actions must contain at least one action"));
        }

        let mut frames = Vec::new();
        let mut tags = Vec::new();
        for (name, action) in entries {
            if name.trim().is_empty() {
                return Err(SheetError::invalid("each action needs a nonempty name"));
            }
            let list = action
                .get("frames")
                .and_then(Value::as_array)
                .filter(|f| !f.is_empty())
                .ok_or_else(|| SheetError::invalid(format!("action {name:?} must contain frames")))?;
            let from = frames.len();
            for frame in list {
                let (x, y, w, h) = rect(frame, default_w, default_h)?;
                frames.push(SheetFrame {
                    x,
                    y,
                    width: w,
                    height: h,
                    duration_ms: duration(frame),
                    tag: Some(name.clone()),
                });
            }
            let color = action
                .get("color")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| TAG_COLORS[tags.len() % TAG_COLORS.len()].to_string());
            tags.push(SheetTag {
                name: name.clone(),
                from: from as u32,
                to: (frames.len() - 1) as u32,
                color,
            });
        }

        let (canvas_width, canvas_height) =
            atlas_canvas(value, image_w, image_h, default_w, default_h);
        let plan = SheetPlan {
            canvas_width,
            canvas_height,
            frames,
            tags,
            source: SheetSource::Atlas,
        };
        plan.validate(image_w, image_h)?;
        Ok(plan)
    }

    fn from_grid_value(value: &Value, image_w: u32, image_h: u32) -> Result<Self, SheetError> {
        let (cell_w, cell_h) = value
            .get("cell")
            .and_then(|c| pair(c, ["w", "h"]))
            .or_else(|| Some((number(value, &["cell_width", "cellWidth"])?, number(value, &["cell_height", "cellHeight"])?)))
            .ok_or_else(|| SheetError::invalid("grid manifest needs a cell width and height"))?;
        let margin = number(value, &["margin"]).unwrap_or(0);
        let spacing = number(value, &["spacing", "gap"]).unwrap_or(0);
        let cols = number(value, &["cols", "columns"]).unwrap_or(0);
        let rows = number(value, &["rows"]).unwrap_or(0);
        let duration_ms = number(value, &["duration_ms", "duration"]).filter(|d| *d > 0).unwrap_or(DEFAULT_DURATION_MS);
        Self::from_grid(image_w, image_h, cell_w, cell_h, margin, spacing, cols, rows, duration_ms)
    }

    /// Build a uniform row-major grid plan. `cols`/`rows` of `0` are inferred
    /// from the image dimensions.
    #[allow(clippy::too_many_arguments)]
    pub fn from_grid(
        image_w: u32,
        image_h: u32,
        cell_w: u32,
        cell_h: u32,
        margin: u32,
        spacing: u32,
        cols: u32,
        rows: u32,
        duration_ms: u32,
    ) -> Result<Self, SheetError> {
        if cell_w == 0 || cell_h == 0 {
            return Err(SheetError::invalid("grid cell size must be positive"));
        }
        let inner_w = image_w.saturating_sub(margin.saturating_mul(2));
        let inner_h = image_h.saturating_sub(margin.saturating_mul(2));
        let cols = if cols > 0 { cols } else { (inner_w + spacing) / (cell_w + spacing) };
        let rows = if rows > 0 { rows } else { (inner_h + spacing) / (cell_h + spacing) };
        if cols == 0 || rows == 0 {
            return Err(SheetError::invalid("the grid does not fit inside the sheet image"));
        }
        let mut frames = Vec::with_capacity((cols * rows) as usize);
        for row in 0..rows {
            for col in 0..cols {
                frames.push(SheetFrame {
                    x: margin + col * (cell_w + spacing),
                    y: margin + row * (cell_h + spacing),
                    width: cell_w,
                    height: cell_h,
                    duration_ms,
                    tag: None,
                });
            }
        }
        let plan = SheetPlan {
            canvas_width: cell_w,
            canvas_height: cell_h,
            frames,
            tags: Vec::new(),
            source: SheetSource::Grid,
        };
        plan.validate(image_w, image_h)?;
        Ok(plan)
    }

    /// Reject geometry that cannot be imported.
    pub fn validate(&self, image_w: u32, image_h: u32) -> Result<(), SheetError> {
        if self.canvas_width == 0 || self.canvas_height == 0 {
            return Err(SheetError::invalid("sheet canvas must be positive"));
        }
        if self.canvas_width as u64 * self.canvas_height as u64 * 4 > MAX_BYTES {
            return Err(SheetError::invalid("sheet canvas exceeds 256 MB"));
        }
        if self.frames.is_empty() {
            return Err(SheetError::invalid("sheet contains no frames"));
        }
        if self.frames.len() > MAX_FRAMES {
            return Err(SheetError::invalid(format!("sheet exceeds {MAX_FRAMES} frames")));
        }
        for frame in &self.frames {
            if frame.width == 0 || frame.height == 0 {
                return Err(SheetError::invalid("sheet frame has a zero width or height"));
            }
            let right = frame.x as u64 + frame.width as u64;
            let bottom = frame.y as u64 + frame.height as u64;
            if right > image_w as u64 || bottom > image_h as u64 {
                return Err(SheetError::invalid("a sheet frame extends beyond the image"));
            }
        }
        for tag in &self.tags {
            if tag.name.trim().is_empty() {
                return Err(SheetError::invalid("tag names must be nonempty"));
            }
            if tag.from > tag.to || tag.to as usize >= self.frames.len() {
                return Err(SheetError::invalid("a tag range is outside the frame list"));
            }
        }
        Ok(())
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_bixel_export() {
        let value = json!({
            "frame_width": 16, "frame_height": 16, "columns": 2,
            "frames": [
                {"x":0,"y":0,"width":16,"height":16,"duration_ms":80},
                {"x":16,"y":0,"width":16,"height":16,"duration_ms":120}
            ]
        });
        let plan = SheetPlan::from_json(&value, 32, 16).unwrap();
        assert_eq!(plan.source, SheetSource::BixelExport);
        assert_eq!((plan.canvas_width, plan.canvas_height), (16, 16));
        assert_eq!(plan.frames.len(), 2);
        assert_eq!(plan.frames[1].duration_ms, 120);
        assert!(plan.tags.is_empty());
    }

    #[test]
    fn parses_atlas_actions_into_tags() {
        let value = json!({
            "size": {"w": 32, "h": 16}, "cell": {"w": 16, "h": 16},
            "actions": {
                "idle": {"frames": [{"x":0,"y":0,"w":16,"h":16}]},
                "walk": {"frames": [{"x":16,"y":0,"w":16,"h":16,"duration":60}]}
            }
        });
        let plan = SheetPlan::from_json(&value, 32, 16).unwrap();
        assert_eq!(plan.source, SheetSource::Atlas);
        assert_eq!(plan.frames.len(), 2);
        assert_eq!(plan.frames[0].tag.as_deref(), Some("idle"));
        assert_eq!(plan.frames[1].duration_ms, 60);
        assert_eq!(plan.tags.len(), 2);
        assert_eq!((plan.tags[0].from, plan.tags[0].to), (0, 0));
        assert_eq!((plan.tags[1].from, plan.tags[1].to), (1, 1));
    }

    #[test]
    fn parses_grid_and_infers_counts() {
        let value = json!({"cell": {"w": 8, "h": 8}});
        let plan = SheetPlan::from_json(&value, 24, 16).unwrap();
        assert_eq!(plan.source, SheetSource::Grid);
        assert_eq!(plan.frames.len(), 6);
        assert_eq!((plan.canvas_width, plan.canvas_height), (8, 8));
    }

    #[test]
    fn rejects_out_of_bounds_frames() {
        let value = json!({"frames": [{"x": 20, "y": 0, "width": 16, "height": 16}]});
        assert!(SheetPlan::from_json(&value, 32, 16).is_err());
    }

    #[test]
    fn rejects_unknown_manifest() {
        assert!(SheetPlan::from_json(&json!({"hello": 1}), 16, 16).is_err());
    }
}
