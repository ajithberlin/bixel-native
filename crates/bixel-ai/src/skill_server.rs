//! In-process MCP extension exposing the Bixel pixel-art skills as goose tools.
//!
//! goose's builtin-extension mechanism spawns an `rmcp` server over a duplex
//! stream in-process; this module implements that server. A single `run_skill`
//! tool dispatches to [`crate::skills::Skills`] so the model can invoke any
//! registered skill by id. Produced images are written to the host workspace and
//! mirrored to an artifact mailbox that [`crate::agent::GooseAgent`] drains to
//! emit base64 artifacts back across the FFI boundary.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use base64::Engine as _;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{
    CallToolResult, ContentBlock, ErrorCode, ErrorData, Implementation, InitializeResult,
    ServerCapabilities, ServerInfo,
};
use rmcp::schemars::JsonSchema;
use rmcp::service::RequestContext;
use rmcp::{tool, tool_handler, tool_router, RoleServer, ServerHandler, ServiceExt};
use serde::{Deserialize, Serialize};

use crate::error::AiError;
use crate::image::{self, RgbaImage};
use crate::image_gen::ImageGenerator;
use crate::skills::{SkillInput, SkillKind, Skills};

/// An image produced by a skill, collected for the UI.
#[derive(Clone, Debug)]
pub struct Artifact {
    pub name: String,
    pub png: String,
    pub width: usize,
    pub height: usize,
    pub source: bool,
}

/// Shared runtime state for the skill extension: the image model client, the
/// per-request workspace, and a mailbox of produced artifacts.
pub struct SkillRuntime {
    /// The image-role client; None while the image role is not ready.
    pub image_gen: Mutex<Option<Arc<dyn ImageGenerator>>>,
    pub workspace: Mutex<Option<PathBuf>>,
    pub artifacts: Mutex<Vec<Artifact>>,
}

impl SkillRuntime {
    pub fn new(image_gen: Option<Arc<dyn ImageGenerator>>) -> Self {
        SkillRuntime {
            image_gen: Mutex::new(image_gen),
            workspace: Mutex::new(None),
            artifacts: Mutex::new(Vec::new()),
        }
    }
}

/// The process-global skill runtime (initialized once by the agent).
pub static RUNTIME: OnceLock<Arc<SkillRuntime>> = OnceLock::new();

/// Register the "bixel" builtin extension with goose.
pub fn register() {
    goose::builtin_extension::register_builtin_extension("bixel", spawn);
}

fn spawn(r: tokio::io::DuplexStream, w: tokio::io::DuplexStream) {
    tokio::spawn(async move {
        match SkillServer::new().serve((r, w)).await {
            Ok(running) => {
                let _ = running.waiting().await;
            }
            Err(e) => tracing::error!(extension = "bixel", error = %e, "skill server error"),
        }
    });
}

/// Arguments for the single skill tool.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct RunSkillParams {
    /// Skill id (e.g. generate_art, compress, pixel_image_gen, pixel_tileset_gen).
    pub skill: String,
    /// Text prompt for model-backed skills.
    #[serde(default)]
    pub prompt: String,
    /// Input image: a base64 data URL or a filename in the workspace.
    #[serde(default)]
    pub image: Option<String>,
    /// Generation params: width and height (1..4096) explicitly requested output pixels; omit both to keep source dimensions. Sheets use frame_width/frame_height plus cols/rows instead. transparent defaults true for sprites; set false for opaque backgrounds or terrain. palette is color/style guidance. Never infer target dimensions from the active canvas.
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Clone)]
pub struct SkillServer {
    tool_router: ToolRouter<Self>,
}

#[tool_router(router = tool_router)]
impl SkillServer {
    pub fn new() -> Self {
        SkillServer {
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        name = "run_skill",
        description = "Run a Bixel pixel-art skill. Skills: image_gen, generate_art, spritesheet, next_frame, pixel_image_gen (provider image backend); compress, remove_background, pixel_reduce_colors, pixel_file_compressor, pixel_remove_bg, pixel_8dir_character, pixel_animate_text, pixel_interpolate, pixel_9slice_splitter, pixel_spritesheet_gen, pixel_tileset_gen, pixel_game_ui_gen, pixel_ui_elements_gen, pixel_ui_kit_gen, pixel_game_asset_prep (local, no network). Use image_gen for a user's natural-language request to create or edit an image. Generation params: width + height (1..4096, explicit target only); spritesheet uses frame_width + frame_height and cols/rows (1..64, max 256 cells). transparent defaults true for sprites and false for image_gen; palette is a string of palette/style guidance. Omit target dimensions to keep source size. Never silently inherit canvas dimensions; ask the user if target intent is unclear. Do not compress or request a reduced target implicitly. Raw model sources are retained separately; explicitly prepared assets crop transparent padding before reduction and use nearest-neighbor pixels. Do not use shell, Python, or another tool to fabricate an image. Returns saved image filenames."
    )]
    pub async fn run_skill(
        &self,
        params: Parameters<RunSkillParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let p = params.0;
        let Some(kind) = SkillKind::from_id(&p.skill) else {
            return Err(ErrorData::new(
                ErrorCode::INVALID_PARAMS,
                format!("unknown skill `{}`", p.skill),
                None,
            ));
        };

        let runtime = RUNTIME.get().ok_or_else(|| {
            ErrorData::new(
                ErrorCode::INTERNAL_ERROR,
                "skill runtime is not initialized".to_string(),
                None,
            )
        })?;

        let workspace = runtime.workspace.lock().unwrap().clone();
        let image = decode_input_image(p.image.as_deref(), workspace.as_deref())
            .map_err(|e| ErrorData::new(ErrorCode::INVALID_PARAMS, e.to_string(), None))?;

        let input = SkillInput {
            prompt: p.prompt,
            image,
            images: vec![],
            params: p.params,
        };

        let gen = runtime.image_gen.lock().unwrap().clone();
        let output = Skills::run(gen.as_deref(), kind, input)
            .map_err(|e| ErrorData::new(ErrorCode::INTERNAL_ERROR, e.to_string(), None))?;

        let mut text = output.text.clone();
        let mut saved = Vec::new();
        let push = |img: &RgbaImage, tag: &str, source: bool| -> Result<String, String> {
            let png = image::encode_png(img).map_err(|e| e.to_string())?;
            let name = loop {
                let name = format!("{}_{}.png", tag, counter());
                if let Some(ws) = &workspace {
                    if !bixel_core::storage::write_new(ws, &name, &png)? { continue; }
                }
                break name;
            };
            let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
            runtime.artifacts.lock().unwrap().push(Artifact {
                name: name.clone(),
                png: b64,
                width: img.width,
                height: img.height,
                source,
            });
            Ok(name)
        };

        if let Some(img) = &output.source_image {
            match push(img, &format!("{}_source", kind), true) {
                Ok(name) => saved.push(name),
                Err(e) => return Err(ErrorData::new(ErrorCode::INTERNAL_ERROR, e, None)),
            }
        }
        if let Some(img) = &output.image {
            let duplicate = output.source_image.as_ref().is_some_and(|source| source == img);
            if !duplicate {
                match push(img, &kind.to_string(), false) {
                    Ok(name) => saved.push(name),
                    Err(e) => return Err(ErrorData::new(ErrorCode::INTERNAL_ERROR, e, None)),
                }
            }
        }
        for (i, frame) in output.frames.iter().enumerate() {
            match push(frame, &format!("{}_{}", kind, i), false) {
                Ok(name) => saved.push(name),
                Err(e) => return Err(ErrorData::new(ErrorCode::INTERNAL_ERROR, e, None)),
            }
        }

        if !saved.is_empty() {
            if !text.is_empty() {
                text.push_str("\nSaved: ");
            } else {
                text.push_str("Saved: ");
            }
            text.push_str(&saved.join(", "));
        }

        Ok(CallToolResult::success(vec![ContentBlock::text(text)]))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for SkillServer {
    fn get_info(&self) -> ServerInfo {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("bixel-skills", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Bixel pixel-art skills: generate sprite assets with the image model, or run \
                 local deterministic operations (color reduce, background removal, slicing, \
                 packing) on images already in the workspace. Pass input images by their \
                 workspace filename.",
            )
    }
}

fn counter() -> u32 {
    static C: AtomicU32 = AtomicU32::new(1);
    C.fetch_add(1, Ordering::Relaxed)
}

/// Decode an input image reference: a base64 data URL/string or a workspace
/// filename.
fn decode_input_image(value: Option<&str>, workspace: Option<&std::path::Path>) -> Result<Option<RgbaImage>, AiError> {
    let Some(value) = value else { return Ok(None) };
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }

    if let Some(b64) = value.strip_prefix("data:") {
        let b64 = b64.split_once("base64,").map(|(_, d)| d).unwrap_or("");
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| AiError::Image(format!("bad base64 image: {e}")))?;
        return Ok(Some(crate::image::decode_any(&bytes)?));
    }

    if let Some(ws) = workspace {
        let path = bixel_core::paths::safe_resolve(value, ws).map_err(|e| AiError::Image(e.to_string()))?;
        if path.is_file() {
            let bytes = std::fs::read(&path).map_err(|e| AiError::Image(e.to_string()))?;
            return Ok(Some(crate::image::decode_any(&bytes)?));
        }
    }

    if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(value) {
        if let Ok(img) = crate::image::decode_any(&bytes) {
            return Ok(Some(img));
        }
    }

    Err(AiError::Image(format!("cannot read input image `{value}`")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skill_ids_resolve() {
        assert!(SkillKind::from_id("compress").is_some());
        assert!(SkillKind::from_id("generate_art").is_some());
        assert!(SkillKind::from_id("does_not_exist").is_none());
    }

    #[test]
    fn empty_image_is_none() {
        assert!(decode_input_image(None, None).unwrap().is_none());
        assert!(decode_input_image(Some(""), None).unwrap().is_none());
    }
}
