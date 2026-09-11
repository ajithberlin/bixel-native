//! In-process MCP extension exposing the provider-backed image tools as goose
//! tools.
//!
//! goose's builtin-extension mechanism spawns an `rmcp` server over a duplex
//! stream in-process; this module implements that server. Each image skill is
//! its own named tool (`image_gen`, `generate_art`, `pixel_image_gen`,
//! `spritesheet`, `next_frame`) dispatching to [`crate::skills::Skills`].
//! Produced images are written to the host workspace and mirrored to an
//! artifact mailbox that [`crate::agent::GooseAgent`] drains to emit base64
//! artifacts back across the FFI boundary.

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
    /// Per-frame timeline metadata for sheet artifacts.
    pub frame_meta: Vec<crate::skills::FrameMeta>,
    /// Sheet manifest (JSON) describing the frames, when available.
    pub atlas: Option<String>,
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

/// Arguments for the provider-backed image tools.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ImageSkillParams {
    /// Text prompt describing the image / edit / motion.
    #[serde(default)]
    pub prompt: String,
    /// Input image: a base64 data URL or a filename in the workspace.
    #[serde(default)]
    pub image: Option<String>,
    /// Generation params: width and height (1..4096) explicitly requested output pixels; omit both to keep source dimensions. Spritesheet uses frame_width/frame_height plus cols/rows instead. transparent defaults true for sprites; set false for opaque backgrounds or terrain. palette is color/style guidance. next_frame takes `action`. Never infer target dimensions from the active canvas.
    #[serde(default)]
    pub params: serde_json::Value,
}

/// Arguments for `editor_read`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EditorReadParams {
    /// Which editor to read: "all" (default), "document", or "map".
    #[serde(default)]
    pub scope: Option<String>,
    /// Include a downscaled preview of the current view for visual reasoning.
    #[serde(default)]
    pub include_preview: Option<bool>,
    /// Longest side of the preview in pixels (default 1024, max 2048).
    #[serde(default)]
    pub preview_max: Option<u32>,
}

/// Arguments for `editor_command`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct EditorCommandParams {
    /// Ordered operations to apply. Each op is `{"op": "...", ...args}`.
    pub ops: Vec<serde_json::Value>,
    /// Set true only after the user approved destructive operations.
    #[serde(default)]
    pub confirm: bool,
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
        name = "image_gen",
        description = "Generate a new image or edit a reference image through the configured provider image backend. Use this only to create or transform artwork, never to run a deterministic preparation step (color reduction, background removal, slicing, packing) — those are installed skills loaded with load_skill. Put the complete visual brief in `prompt`; pass a reference with `image`."
    )]
    pub async fn image_gen(
        &self,
        params: Parameters<ImageSkillParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        self.run_image(SkillKind::ImageGen, params.0).await
    }

    #[tool(
        name = "generate_art",
        description = "Generate a piece of pixel art from a text prompt through the provider image backend."
    )]
    pub async fn generate_art(
        &self,
        params: Parameters<ImageSkillParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        self.run_image(SkillKind::GenerateArt, params.0).await
    }

    #[tool(
        name = "pixel_image_gen",
        description = "Generate a single clean, game-ready pixel-art asset from a prompt or reference image. One asset per image."
    )]
    pub async fn pixel_image_gen(
        &self,
        params: Parameters<ImageSkillParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        self.run_image(SkillKind::PixelImageGen, params.0).await
    }

    #[tool(
        name = "spritesheet",
        description = "Generate a spritesheet grid and slice it into frames. Provide frame_width + frame_height and cols + rows in params."
    )]
    pub async fn spritesheet(
        &self,
        params: Parameters<ImageSkillParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        self.run_image(SkillKind::Spritesheet, params.0).await
    }

    #[tool(
        name = "next_frame",
        description = "Advance an animation by exactly one frame. Pass the current frame as `image` and put the motion (a small increment) in `params.action`. Returns the next frame at the source frame's size."
    )]
    pub async fn next_frame(
        &self,
        params: Parameters<ImageSkillParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        self.run_image(SkillKind::NextFrame, params.0).await
    }

    #[tool(
        name = "editor_read",
        description = "Read the live editor state (active document or tilemap): dimensions, layers, frames, tags, tilesets, selection, palette and undo availability. Returns structured JSON plus a downscaled preview image of the current view. Call this before changing anything so the plan matches what is actually on screen."
    )]
    pub async fn editor_read(
        &self,
        params: Parameters<EditorReadParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let p = params.0;
        let request = serde_json::json!({
            "command": "read",
            "workspace": workspace_string(),
            "scope": p.scope.unwrap_or_else(|| "all".into()),
            "include_preview": p.include_preview.unwrap_or(true),
            "preview_max": p.preview_max.unwrap_or(1024).min(2048),
        });
        let response = crate::editor_bridge::request(&request)
            .map_err(|e| ErrorData::new(ErrorCode::INTERNAL_ERROR, e.to_string(), None))?;
        if response.get("ok").and_then(|v| v.as_bool()) != Some(true) {
            return Err(bridge_error(&response));
        }
        let mut data = response.get("data").cloned().unwrap_or(serde_json::Value::Null);
        let preview = data
            .get_mut("preview_png_base64")
            .and_then(|value| value.take().as_str().map(str::to_string));
        let text = serde_json::to_string_pretty(&data).unwrap_or_default();
        let mut blocks = vec![ContentBlock::text(text)];
        if let Some(preview) = preview.filter(|p| !p.is_empty()) {
            blocks.push(ContentBlock::image(preview, "image/png"));
        }
        Ok(CallToolResult::success(blocks))
    }

    #[tool(
        name = "editor_command",
        description = "Apply one or more operations to the live editor (sprite document or tilemap). Use editor_read first. Each op is {\"op\": \"...\", ...}. Destructive ops (remove/resize) are guarded: get the user's approval and pass confirm=true, otherwise the host may deny the batch or show a native confirmation. Returns per-op results so failures can be corrected."
    )]
    pub async fn editor_command(
        &self,
        params: Parameters<EditorCommandParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let p = params.0;
        if p.ops.is_empty() {
            return Err(ErrorData::new(
                ErrorCode::INVALID_PARAMS,
                "editor_command needs at least one op".to_string(),
                None,
            ));
        }
        let request = serde_json::json!({
            "command": "apply",
            "workspace": workspace_string(),
            "ops": p.ops,
            "confirm": p.confirm,
        });
        let response = crate::editor_bridge::request(&request)
            .map_err(|e| ErrorData::new(ErrorCode::INTERNAL_ERROR, e.to_string(), None))?;
        let text = serde_json::to_string_pretty(&response).unwrap_or_default();
        Ok(CallToolResult::success(vec![ContentBlock::text(text)]))
    }

    async fn run_image(
        &self,
        kind: SkillKind,
        p: ImageSkillParams,
    ) -> Result<CallToolResult, ErrorData> {
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
        let push = |img: &RgbaImage, tag: &str, source: bool,
                    frame_meta: Vec<crate::skills::FrameMeta>, atlas: Option<String>| -> Result<String, String> {
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
                frame_meta,
                atlas,
            });
            Ok(name)
        };

        // The packed sheet carries the full frame list + manifest so the host
        // can offer "add as animation"; individual frames carry their own meta.
        let sheet_meta = output.frame_meta.clone();
        let sheet_atlas = output.atlas.clone();
        if let Some(img) = &output.source_image {
            match push(img, &format!("{}_source", kind), true, vec![], None) {
                Ok(name) => saved.push(name),
                Err(e) => return Err(ErrorData::new(ErrorCode::INTERNAL_ERROR, e, None)),
            }
        }
        if let Some(img) = &output.image {
            let duplicate = output.source_image.as_ref().is_some_and(|source| source == img);
            if !duplicate {
                match push(img, &kind.to_string(), false, sheet_meta, sheet_atlas) {
                    Ok(name) => saved.push(name),
                    Err(e) => return Err(ErrorData::new(ErrorCode::INTERNAL_ERROR, e, None)),
                }
            }
        }
        for (i, frame) in output.frames.iter().enumerate() {
            let meta = output.frame_meta.get(i).cloned().into_iter().collect();
            match push(frame, &format!("{}_{}", kind, i), false, meta, None) {
                Ok(name) => saved.push(name),
                Err(e) => return Err(ErrorData::new(ErrorCode::INTERNAL_ERROR, e, None)),
            }
        }

        if !saved.is_empty() {
            text.push_str("\nSaved: ");
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
                "Bixel provider-backed image tools: image_gen, generate_art, pixel_image_gen, \
                 spritesheet, next_frame. Pass input images by their workspace filename. \
                 Live editor control: editor_read observes the current document/tilemap (state + \
                 preview) and editor_command applies validated operations to it. Use editor_read \
                 before editor_command, and never claim a change without a tool result. \
                 Deterministic image work (color reduction, background removal, slicing, packing, \
                 tilesets, UI kits) is provided by installed agent skills — list them in your \
                 system instructions, load one with load_skill, and run its scripts.",
            )
    }
}

/// The per-request workspace as a string for the host bridge, when known.
fn workspace_string() -> Option<String> {
    RUNTIME
        .get()
        .and_then(|runtime| runtime.workspace.lock().unwrap().clone())
        .map(|path| path.to_string_lossy().into_owned())
}

/// Turn a `{"ok":false,...}` bridge response into a tool error.
fn bridge_error(response: &serde_json::Value) -> ErrorData {
    let code = response
        .get("code")
        .and_then(|v| v.as_str())
        .unwrap_or("editor_error");
    let message = response
        .get("error")
        .and_then(|v| v.as_str())
        .unwrap_or("The editor command failed.");
    ErrorData::new(
        ErrorCode::INTERNAL_ERROR,
        format!("{code}: {message}"),
        None,
    )
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
        assert!(SkillKind::from_id("image_gen").is_some());
        assert!(SkillKind::from_id("generate_art").is_some());
        assert!(SkillKind::from_id("next_frame").is_some());
        assert!(SkillKind::from_id("does_not_exist").is_none());
    }

    #[test]
    fn empty_image_is_none() {
        assert!(decode_input_image(None, None).unwrap().is_none());
        assert!(decode_input_image(Some(""), None).unwrap().is_none());
    }
}
