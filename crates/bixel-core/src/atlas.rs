//! Atlas JSON schema validation (port of `core/atlases.py`).
//!
//! Loads/saves the packer/player atlas schema without dropping metadata. Only
//! the *validation* half is needed by the core; the frontend owns serialization.

use std::path::Path;

use serde_json::Value;

#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct AtlasError(pub String);

impl AtlasError {
    pub fn new(msg: impl Into<String>) -> Self {
        AtlasError(msg.into())
    }
}

fn number(v: &Value, label: &str, minimum: Option<i64>, integer: bool) -> Result<i64, AtlasError> {
    let n = v
        .as_i64()
        .ok_or_else(|| AtlasError::new(format!("{label} must be a number")))?;
    if let Some(min) = minimum {
        if n < min {
            return Err(AtlasError::new(format!("{label} must be >= {min}")));
        }
    }
    if integer {
        // as_i64 already guarantees integrality.
    }
    Ok(n)
}

fn pair(v: &Value, label: &str, keys: [&str; 2], minimum: Option<i64>) -> Result<(i64, i64), AtlasError> {
    let obj = v
        .as_object()
        .ok_or_else(|| AtlasError::new(format!("{label} must be an object")))?;
    let a = number(obj.get(keys[0]).unwrap_or(&Value::Null), &format!("{label}.{}", keys[0]), minimum, true)?;
    let b = number(obj.get(keys[1]).unwrap_or(&Value::Null), &format!("{label}.{}", keys[1]), minimum, true)?;
    Ok((a, b))
}

fn check_rect(
    v: &Value,
    label: &str,
    width: Option<i64>,
    height: Option<i64>,
) -> Result<(), AtlasError> {
    let (x, y) = pair(v, label, ["x", "y"], Some(0))?;
    let (w, h) = pair(v, label, ["w", "h"], Some(1))?;
    if let (Some(width), Some(height)) = (width, height) {
        if x + w > width || y + h > height {
            return Err(AtlasError::new(format!("{label} extends beyond the atlas image")));
        }
    }
    Ok(())
}

/// Validate drawable geometry. Returns `()` on success. `image_size` is the
/// decoded size of the atlas sheet image (`None` when unknown, in which case
/// `data.size` is trusted without cross-checking).
pub fn validate(data: &Value, image_size: Option<(u32, u32)>) -> Result<(), AtlasError> {
    let Some(_obj) = data.as_object() else {
        return Err(AtlasError::new("atlas must be an object"));
    };

    let image = data
        .get("image")
        .and_then(|v| v.as_str())
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| AtlasError::new("atlas.image is required"))?;

    if image.starts_with(['/', '\\']) || image.contains('\\') || image.contains(':') {
        return Err(AtlasError::new("atlas.image must be a relative project image path"));
    }

    let (width, height) = match image_size {
        Some((w, h)) => (w as i64, h as i64),
        None => match data.get("size") {
            Some(size) => {
                let (w, h) = pair(size, "size", ["w", "h"], Some(1))?;
                (w, h)
            }
            None => (1024, 1024),
        },
    };

    if let Some(size) = data.get("size") {
        let (sw, sh) = pair(size, "size", ["w", "h"], Some(1))?;
        if (sw, sh) != (width, height) {
            return Err(AtlasError::new("atlas.size must match the image dimensions"));
        }
    }
    if let Some(cell) = data.get("cell") {
        pair(cell, "cell", ["w", "h"], Some(1))?;
    }
    if let Some(padding) = data.get("padding") {
        number(padding, "padding", Some(0), true)?;
    }
    if let Some(pivot) = data.get("pivot") {
        pair(pivot, "pivot", ["x", "y"], None)?;
    }

    let actions = data
        .get("actions")
        .and_then(|v| v.as_object())
        .filter(|o| !o.is_empty())
        .ok_or_else(|| AtlasError::new("atlas.actions must contain at least one action"))?;

    for (name, action) in actions {
        if name.trim().is_empty() || !action.is_object() {
            return Err(AtlasError::new("each action needs a nonempty name and an object"));
        }
        let frames = action
            .get("frames")
            .and_then(|v| v.as_array())
            .filter(|f| !f.is_empty())
            .ok_or_else(|| AtlasError::new(format!("action {name:?} must contain frames")))?;
        for (i, frame) in frames.iter().enumerate() {
            let label = format!("actions.{name}.frames[{i}]");
            check_rect(frame, &label, Some(width), Some(height))?;
            if let Some(sprite) = frame.get("sprite") {
                check_rect(sprite, &format!("{label}.sprite"), Some(width), Some(height))?;
            }
            if let Some(offset) = frame.get("offset") {
                pair(offset, &format!("{label}.offset"), ["x", "y"], None)?;
            }
        }
    }
    Ok(())
}

/// Read PNG width/height from the IHDR chunk (first 24 bytes).
pub fn png_dimensions(path: &Path) -> std::io::Result<(u32, u32)> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut header = [0u8; 24];
    file.read_exact(&mut header)?;
    if &header[..8] != b"\x89PNG\r\n\x1a\n" {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "not a PNG"));
    }
    let width = u32::from_be_bytes([header[16], header[17], header[18], header[19]]);
    let height = u32::from_be_bytes([header[20], header[21], header[22], header[23]]);
    Ok((width, height))
}
