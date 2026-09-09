//! The embedded goose agent: builds a full `goose::agents::Agent`, wires the
//! OpenRouter provider, registers the Bixel skill extension, and drives
//! `Agent::reply` while mapping `AgentEvent`s to [`NativeEvent`]s for the FFI.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use futures::StreamExt;
use goose::agents::types::SessionConfig;
use goose::agents::{Agent, AgentConfig, AgentEvent, GoosePlatform};
use goose::config::{Config, ExtensionConfig, GooseMode, PermissionManager};
use goose::conversation::message::{Message, MessageContent};
use goose::session::session_manager::SessionType;
use goose::session::SessionManager;
use rmcp::model::ContentBlock;

use crate::config::AiSettings;
use crate::error::AiError;
use crate::image_gen::ImageGen;
use crate::native_stream::{NativeEvent, NativeRequest};
use crate::skill_server::{self, Artifact, SkillRuntime};

/// A synchronous wrapper around the goose agent. Owns its tokio runtime so the
/// FFI / UI layer can drive a whole agent turn without an async context.
pub struct GooseAgent {
    agent: Agent,
    runtime: tokio::runtime::Runtime,
    session_id: Mutex<HashMap<String, String>>,
    settings: AiSettings,
}

impl GooseAgent {
    pub fn new(settings: AiSettings) -> Result<Self, AiError> {
        if !settings.has_key() {
            return Err(AiError::Config(
                "OPENROUTER_API_KEY is not set (see .env.example)".into(),
            ));
        }

        // Isolate goose's config/session state under a host-owned temp dir and
        // point it at OpenRouter via the environment.
        let data_dir = std::env::temp_dir().join("bixel-goose");
        settings.apply_goose_env(&data_dir);
        std::fs::create_dir_all(&data_dir).map_err(|e| AiError::Provider(e.to_string()))?;

        skill_server::register();

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

        // Initialize the skill runtime with the image model client.
        let image_gen = Arc::new(ImageGen::new(&settings));
        skill_server::RUNTIME.get_or_init(|| Arc::new(SkillRuntime::new(Some(image_gen))));

        Ok(GooseAgent {
            agent,
            runtime,
            session_id: Mutex::new(HashMap::new()),
            settings,
        })
    }

    pub fn settings(&self) -> &AiSettings {
        &self.settings
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

    /// Enable the developer (file/shell) and bixel (pixel-art skills) extensions
    /// and create the OpenRouter provider for the session.
    fn ensure_extensions_and_provider(&self, session_id: &str) -> Result<(), AiError> {
        let res: Result<(), String> = self.runtime.block_on(async {
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

            let config = Config::global();
            let provider_name = config.get_goose_provider().map_err(|e| e.to_string())?;
            let model_name = config.get_goose_model().map_err(|e| e.to_string())?;
            let model_config = goose::model_config::model_config_from_user_config(
                &provider_name,
                &model_name,
            )
            .map_err(|e| e.to_string())?;
            self.agent
                .recreate_provider_for_session(session_id, &provider_name, model_config)
                .await
                .map_err(|e| e.to_string())?;

            Ok(())
        });
        res.map_err(AiError::Provider)
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

        // Honor the host-provided studio prompt as an additive system instruction.
        if !request.system.trim().is_empty() {
            self.runtime.block_on(
                self.agent
                    .extend_system_prompt("bixel".to_string(), request.system.clone()),
            );
        }

        let mut msg = Message::user().with_text(request.prompt.clone());
        for attachment in &request.images {
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
                                if !emit(NativeEvent::Artifact {
                                    id: artifact.name.clone(),
                                    parent_id: resp.id.clone(),
                                    name: artifact.name,
                                    png: artifact.png,
                                    width: artifact.width,
                                    height: artifact.height,
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

/// Derive a display name from a (possibly extension-prefixed) tool name,
/// preferring the `skill` argument when the tool is `run_skill`.
fn tool_display_name(
    raw: &str,
    arguments: &Option<serde_json::Map<String, serde_json::Value>>,
) -> String {
    let base = raw.rsplit("__").next().unwrap_or(raw).to_string();
    if let Some(args) = arguments {
        if let Some(skill) = args.get("skill").and_then(|v| v.as_str()) {
            return skill.to_string();
        }
    }
    base
}

#[cfg(test)]
mod workspace_tests {
    use super::*;

    #[test]
    fn conversations_reuse_only_their_own_workspace_session() {
        let settings = AiSettings { api_key: "dummy-no-network".into(), ..Default::default() };
        let agent = GooseAgent::new(settings).unwrap();
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
}
