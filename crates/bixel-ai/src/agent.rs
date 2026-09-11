//! The embedded goose agent: builds a full `goose::agents::Agent`, registers
//! the Bixel skill extension, and drives `Agent::reply` while mapping
//! `AgentEvent`s to [`NativeEvent`]s for the FFI. The chat provider comes from
//! a cached [`ProviderHandle`] (see `connection.rs`) and is shared across
//! sessions via `Agent::update_provider`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use futures::StreamExt;
use goose::agents::types::SessionConfig;
use goose::agents::{Agent, AgentConfig, AgentEvent, GoosePlatform};
use goose::config::{ExtensionConfig, GooseMode, PermissionManager};
use goose::conversation::message::{Message, MessageContent};
use goose::session::session_manager::SessionType;
use goose::session::SessionManager;
use rmcp::model::ContentBlock;

use crate::connection::{self, ConnectionConfig, ModelReadiness, ProviderHandle};
use crate::error::AiError;
use crate::native_stream::{NativeEvent, NativeRequest};
use crate::skill_server::{self, Artifact, SkillRuntime};

/// A synchronous wrapper around the goose agent. Owns its tokio runtime so the
/// FFI / UI layer can drive a whole agent turn without an async context.
pub struct GooseAgent {
    agent: Agent,
    runtime: tokio::runtime::Runtime,
    session_id: Mutex<HashMap<String, String>>,
    handle: Mutex<Option<Arc<ProviderHandle>>>,
    /// The session the in-process extension clients are currently bound to.
    /// Goose keeps one MCP client per extension name and asserts it only ever
    /// serves a single session, so a session switch must re-create them.
    bound_session: Mutex<Option<String>>,
}

impl GooseAgent {
    pub fn new() -> Result<Self, AiError> {
        // Isolate goose's config/session/OAuth state under an app-owned root
        // (never the user's ~/.config/goose) before Config::global() is first
        // touched.
        let data_dir = connection::ensure_goose_env()?;

        skill_server::register();

        // Stage the bundled agent skills into goose's global skills directory so
        // its native `skills` extension can discover them (idempotent; also
        // triggered when the host lists commands).
        crate::skill_install::ensure_bundled_installed();

        let runtime = tokio::runtime::Runtime::new()
            .map_err(|e| AiError::Provider(format!("failed to start runtime: {e}")))?;

        // SessionManager builds a sqlx pool lazily, which requires a Tokio
        // context — construct it inside the runtime and keep the runtime alive
        // for the lifetime of the agent.
        let session_manager = Arc::new(runtime.block_on(async {
            SessionManager::new(data_dir.clone())
        }));

        let agent = Agent::with_config(AgentConfig::new(
            session_manager,
            PermissionManager::instance(),
            None,
            GooseMode::Auto,
            false,
            GoosePlatform::GooseCli,
        ));

        skill_server::RUNTIME.get_or_init(|| Arc::new(SkillRuntime::new(None)));

        Ok(GooseAgent {
            agent,
            runtime,
            session_id: Mutex::new(HashMap::new()),
            handle: Mutex::new(None),
            bound_session: Mutex::new(None),
        })
    }

    /// The active provider connection, if any.
    pub fn handle(&self) -> Option<Arc<ProviderHandle>> {
        self.handle.lock().unwrap().clone()
    }

    /// The tokio runtime driving this agent (for other blocking goose calls).
    pub fn runtime(&self) -> &tokio::runtime::Runtime {
        &self.runtime
    }

    /// Current readiness of the three model roles (None = not connected).
    pub fn readiness(&self) -> Option<ModelReadiness> {
        self.handle().map(|h| h.readiness.clone())
    }

    /// The image-role client used by model-backed skills.
    pub fn image_gen(&self) -> Option<Arc<dyn crate::image_gen::ImageGenerator>> {
        self.handle().and_then(|h| h.image_gen.clone())
    }

    /// Connect (or reconnect) with a new credential set. Builds and caches one
    /// provider instance; sessions receive clones via `update_provider`.
    /// Returns the three-model readiness gate.
    pub fn connect(&self, cfg: ConnectionConfig) -> Result<ModelReadiness, AiError> {
        let handle = connection::connect(&self.runtime, cfg)?;
        let readiness = handle.readiness.clone();
        if let Some(runtime) = skill_server::RUNTIME.get() {
            *runtime.image_gen.lock().unwrap() = handle.image_gen.clone();
        }
        *self.handle.lock().unwrap() = Some(handle);
        Ok(readiness)
    }

    /// Drop the cached provider and clear stored credentials.
    pub fn disconnect(&self) -> Result<(), AiError> {
        let provider = self
            .handle()
            .map(|h| h.config.provider)
            .unwrap_or_default();
        connection::disconnect(&self.runtime, provider)?;
        *self.handle.lock().unwrap() = None;
        if let Some(runtime) = skill_server::RUNTIME.get() {
            *runtime.image_gen.lock().unwrap() = None;
        }
        Ok(())
    }

    /// Forget the current conversation so the next `chat_stream` starts a fresh
    /// goose session.
    pub fn reset(&self) {
        self.session_id.lock().unwrap().clear();
    }

    fn ensure_session(&self, base: &str) -> Result<String, AiError> {
        let mut guard = self.session_id.lock().unwrap();
        if let Some(id) = guard.get(base) {
            return Ok(id.clone());
        }
        let sm = self.agent.config.session_manager.clone();
        let working_dir = PathBuf::from(base);
        let session = self
            .runtime
            .block_on(sm.create_session(
                working_dir,
                "Bixel Studio".to_string(),
                SessionType::User,
                GooseMode::Auto,
            ))
            .map_err(|e| AiError::Provider(e.to_string()))?;
        let id = session.id.clone();
        guard.insert(base.to_string(), id.clone());
        Ok(id)
    }

    /// True when the in-process extension clients must be re-created for
    /// `session_id`. Goose's extension manager dedupes clients by name and its
    /// in-process MCP client panics ("requests from different sessions") when a
    /// second session reuses one, so any session change forces a rebind.
    fn session_needs_rebind(&self, session_id: &str) -> bool {
        self.bound_session.lock().unwrap().as_deref() != Some(session_id)
    }

    /// Record `session_id` as bound. Only call after the extensions were
    /// successfully (re)created: marking a session whose rebind failed would
    /// leave stale clients bound to a different session and panic on the next
    /// tool call.
    fn set_bound_session(&self, session_id: &str) {
        *self.bound_session.lock().unwrap() = Some(session_id.to_string());
    }

    /// Enable the developer (file/shell), skills (goose native skills) and bixel
    /// (provider image tools) extensions, plus every enabled MCP extension the
    /// user configured in Settings, and hand the session the cached provider
    /// with the configured text model.
    fn ensure_extensions_and_provider(&self, session_id: &str) -> Result<(), AiError> {
        let handle = self
            .handle()
            .ok_or_else(|| AiError::Config("AI provider is not connected".into()))?;
        let needs_rebind = self.session_needs_rebind(session_id);
        // User-configured MCP servers live in goose's extensions config. The
        // built-in developer/skills/bixel extensions are always added
        // explicitly, so skip any configured duplicate by key.
        let mut configured: Vec<ExtensionConfig> = goose::config::extensions::get_enabled_extensions();
        configured.retain(|ext| !matches!(ext.key().as_str(), "developer" | "skills" | "bixel"));
        let mut managed_keys = vec![
            "developer".to_string(),
            "skills".to_string(),
            "bixel".to_string(),
        ];
        managed_keys.extend(configured.iter().map(|ext| ext.key()));
        let res: Result<(), String> = self.runtime.block_on(async {
            if needs_rebind {
                // Drop the clients so add_extension re-creates them bound to
                // this session (fresh empty session slot, no goose assert).
                for key in &managed_keys {
                    self.agent
                        .extension_manager
                        .remove_extension_by_key(key)
                        .await
                        .map_err(|e| e.to_string())?;
                }
            }
            self.agent
                .add_extension(
                    ExtensionConfig::Platform {
                        name: "developer".into(),
                        description: "developer".into(),
                        display_name: None,
                        bundled: None,
                        available_tools: vec![],
                    },
                    session_id,
                )
                .await
                .map_err(|e| e.to_string())?;

            // goose's native skills system: discovers the SKILL.md packages we
            // installed under ~/.agents/skills and serves the `load_skill` tool.
            self.agent
                .add_extension(
                    ExtensionConfig::Platform {
                        name: "skills".into(),
                        description: "skills".into(),
                        display_name: None,
                        bundled: None,
                        available_tools: vec![],
                    },
                    session_id,
                )
                .await
                .map_err(|e| e.to_string())?;

            self.agent
                .add_extension(
                    ExtensionConfig::Builtin {
                        name: "bixel".into(),
                        description: "bixel".into(),
                        display_name: None,
                        timeout: None,
                        bundled: None,
                        available_tools: vec![],
                    },
                    session_id,
                )
                .await
                .map_err(|e| e.to_string())?;

            // User-configured MCP servers (stdio / streamable HTTP) from
            // Settings. A failure to start one server must not sink the whole
            // session, so log and continue.
            for ext in configured {
                if let Err(error) = self.agent.add_extension(ext.clone(), session_id).await {
                    tracing::warn!(extension = %ext.key(), %error, "could not start MCP extension");
                }
            }

            self.agent
                .update_provider(
                    handle.provider.clone(),
                    handle.text_model_config(),
                    session_id,
                )
                .await
                .map_err(|e| e.to_string())?;

            Ok(())
        });
        match res {
            Ok(()) => {
                self.set_bound_session(session_id);
                Ok(())
            }
            Err(error) => Err(AiError::Provider(error)),
        }
    }

    /// Drive one full agent turn, emitting [`NativeEvent`]s as they arrive.
    /// Returning `false` from `emit` aborts the turn at the next event boundary.
    pub fn chat_stream<F>(&self, request: NativeRequest, mut emit: F) -> Result<(), AiError>
    where
        F: FnMut(NativeEvent) -> bool,
    {
        let base = std::path::Path::new(&request.base);
        if !base.is_absolute() {
            return Err(AiError::Config("An absolute assistant workspace is required".into()));
        }
        std::fs::create_dir_all(base).map_err(|e| AiError::Image(e.to_string()))?;

        let session_id = self.ensure_session(&request.base)?;
        self.ensure_extensions_and_provider(&session_id)?;

        if let Some(runtime) = skill_server::RUNTIME.get() {
            *runtime.workspace.lock().unwrap() = Some(base.to_path_buf());
        }

        // Honor the host-provided studio prompt as an additive system
        // instruction. The legacy `Agent::reply` path (unlike goose's state
        // machine) does not inject goose's skill catalog, so append it here
        // using goose's own formatter.
        let mut system_prompt = request.system.clone();
        let skills = crate::commands::installed_skills_markdown(Some(base));
        if !skills.trim().is_empty() {
            if !system_prompt.trim().is_empty() {
                system_prompt.push_str("\n\n");
            }
            system_prompt.push_str(&skills);
        }
        if !system_prompt.trim().is_empty() {
            self.runtime.block_on(
                self.agent
                    .extend_system_prompt("bixel".to_string(), system_prompt),
            );
        }

        // Route image attachments through the vision role when it is ready:
        // the vision model describes them and the descriptions ride along as
        // text, so the chat model never needs image input. Without vision, the
        // raw images are attached to the chat model as before.
        let mut prompt_text = request.prompt.clone();
        let mut images = request.images.clone();
        if !images.is_empty() {
            if let Some(handle) = self.handle() {
                if let Some(descriptions) = handle.describe_attachments(&images) {
                    prompt_text.push_str(&descriptions);
                    images = vec![];
                }
            }
        }

        let mut msg = Message::user().with_text(prompt_text);
        for attachment in &images {
            msg = msg.with_image(attachment.data.clone(), "image/png".to_string());
        }

        let session_config = SessionConfig {
            id: session_id,
            schedule_id: None,
            max_turns: Some(20),
            retry_config: None,
        };

        let agent = &self.agent;
        let runtime = &self.runtime;
        let mut stream = runtime
            .block_on(agent.reply(msg, session_config, None))
            .map_err(|e| AiError::Provider(e.to_string()))?;

        let mut state = StreamState::default();
        loop {
            match runtime.block_on(stream.next()) {
                None => break,
                Some(Ok(event)) => {
                    if !map_event(event, &mut state, &mut emit) {
                        break;
                    }
                }
                Some(Err(e)) => return Err(AiError::Provider(e.to_string())),
            }
        }
        emit(NativeEvent::Finished);
        Ok(())
    }
}

#[derive(Default)]
struct StreamState {
    next_id: u32,
    tool_names: HashMap<String, String>,
}

fn map_event<F>(event: AgentEvent, state: &mut StreamState, emit: &mut F) -> bool
where
    F: FnMut(NativeEvent) -> bool,
{
    match event {
        AgentEvent::Message(message) => {
            let msg_id = message.id.clone().unwrap_or_else(|| {
                state.next_id += 1;
                format!("msg_{}", state.next_id)
            });
            for block in message.content {
                match block {
                    MessageContent::Text(t) => {
                        if !t.text.is_empty()
                            && !emit(NativeEvent::Text { id: msg_id.clone(), delta: t.text })
                        {
                            return false;
                        }
                    }
                    MessageContent::Thinking(t) => {
                        if !t.thinking.is_empty()
                            && !emit(NativeEvent::Thinking { id: msg_id.clone(), delta: t.thinking })
                        {
                            return false;
                        }
                    }
                    MessageContent::ToolRequest(req) => {
                        if let Ok(params) = &req.tool_call {
                            let name = tool_display_name(&params.name, &params.arguments);
                            let arguments = params
                                .arguments
                                .as_ref()
                                .map(|a| serde_json::to_string(a).unwrap_or_default())
                                .unwrap_or_default();
                            state.tool_names.insert(req.id.clone(), name.clone());
                            if !emit(NativeEvent::ToolCall {
                                id: req.id.clone(),
                                name,
                                arguments,
                            }) {
                                return false;
                            }
                        }
                    }
                    MessageContent::ToolResponse(resp) => {
                        let (text, failed) = match &resp.tool_result {
                            Ok(cr) => {
                                let mut text = String::new();
                                for block in &cr.content {
                                    if let ContentBlock::Text(t) = block {
                                        text.push_str(&t.text);
                                    }
                                }
                                (text, cr.is_error.unwrap_or(false))
                            }
                            Err(e) => (e.message.to_string(), true),
                        };
                        let name = state
                            .tool_names
                            .get(&resp.id)
                            .cloned()
                            .unwrap_or_else(|| "tool".to_string());
                        if !emit(NativeEvent::ToolResult {
                            id: resp.id.clone(),
                            name,
                            text,
                            success: !failed,
                        }) {
                            return false;
                        }
                        if let Some(runtime) = skill_server::RUNTIME.get() {
                            let artifacts: Vec<Artifact> =
                                std::mem::take(&mut *runtime.artifacts.lock().unwrap());
                            for artifact in artifacts {
                                let frame_meta = if artifact.frame_meta.is_empty() {
                                    None
                                } else {
                                    serde_json::to_string(&artifact.frame_meta).ok()
                                };
                                if !emit(NativeEvent::Artifact {
                                    id: artifact.name.clone(),
                                    parent_id: resp.id.clone(),
                                    name: artifact.name,
                                    png: artifact.png,
                                    width: artifact.width,
                                    height: artifact.height,
                                    source: artifact.source,
                                    frame_meta,
                                    atlas: artifact.atlas,
                                }) {
                                    return false;
                                }
                            }
                        }
                    }
                    MessageContent::Error(e) => {
                        if !emit(NativeEvent::Error { message: e.message }) {
                            return false;
                        }
                    }
                    _ => {}
                }
            }
            true
        }
        AgentEvent::Usage(usage) => {
            let input = usage.usage.input_tokens.unwrap_or(0) as i64;
            let output = usage.usage.output_tokens.unwrap_or(0) as i64;
            if input == 0 && output == 0 {
                return true;
            }
            emit(NativeEvent::Usage { input_tokens: input, output_tokens: output })
        }
        _ => true,
    }
}

/// Derive a display name from a (possibly extension-prefixed) tool name.
fn tool_display_name(
    raw: &str,
    _arguments: &Option<serde_json::Map<String, serde_json::Value>>,
) -> String {
    raw.rsplit("__").next().unwrap_or(raw).to_string()
}

#[cfg(test)]
mod workspace_tests {
    use super::*;

    #[test]
    fn conversations_reuse_only_their_own_workspace_session() {
        let agent = GooseAgent::new().unwrap();
        let base = std::env::temp_dir().join(format!("bixel-context-{}", std::process::id()));
        let a = base.join("project-a/chat-a").to_string_lossy().into_owned();
        let b = base.join("project-b/chat-a").to_string_lossy().into_owned();
        let a_id = agent.ensure_session(&a).unwrap();
        let b_id = agent.ensure_session(&b).unwrap();
        assert_ne!(a_id, b_id, "Projects must not share model context or working directories");
        assert_eq!(a_id, agent.ensure_session(&a).unwrap());
        agent.reset();
        assert_ne!(a_id, agent.ensure_session(&a).unwrap());
    }

    #[test]
    fn session_switch_marks_extensions_for_rebind() {
        let agent = GooseAgent::new().unwrap();
        // First bind of a session always rebinds (clients start unbound).
        assert!(agent.session_needs_rebind("session-a"));
        agent.set_bound_session("session-a");
        // Re-marking the same session is a no-op.
        assert!(!agent.session_needs_rebind("session-a"));
        // A different conversation's session forces a rebind — otherwise
        // goose's McpClient panics ("requests from different sessions").
        assert!(agent.session_needs_rebind("session-b"));
        agent.set_bound_session("session-b");
        assert!(!agent.session_needs_rebind("session-b"));
    }
}
