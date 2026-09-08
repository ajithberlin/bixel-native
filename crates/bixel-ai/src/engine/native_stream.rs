//! Native agent events. Every visible node corresponds to an actual provider or tool event.
use super::*;
use std::path::Path;
use serde::{Deserialize, Serialize};
use bixel_core::paths::safe_resolve;

#[derive(Debug, Deserialize)]
pub struct NativeAttachment {
    pub name: String,
    pub data: String,
}

#[derive(Debug, Deserialize)]
pub struct NativeRequest {
    pub prompt: String,
    pub system: String,
    pub base: String,
    #[serde(default)]
    pub images: Vec<NativeAttachment>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NativeEvent {
    Started { id: String, title: String },
    Thinking { id: String, delta: String },
    Text { id: String, delta: String },
    ToolCall { id: String, name: String, arguments: String },
    ToolResult { id: String, name: String, text: String, success: bool },
    Artifact { id: String, parent_id: String, name: String, png: String, width: usize, height: usize },
    Usage { input_tokens: i64, output_tokens: i64 },
    Finished,
    Error { message: String },
}

impl Engine {
    /// A streaming turn with a host-owned file root and bulk image attachments.
    /// Returning false from the observer stops at the next event boundary.
    pub fn native_chat<F>(&self, request: NativeRequest, mut emit: F) -> Result<(), AiError>
    where F: FnMut(NativeEvent) -> bool {
        let base = Path::new(&request.base);
        if !base.is_absolute() { return Err(AiError::Config("An absolute assistant workspace is required".into())); }
        std::fs::create_dir_all(base).map_err(|e| AiError::Image(e.to_string()))?;
        let mut content = vec![Self::text(&request.prompt)];
        for attachment in &request.images {
            let data = base64::engine::general_purpose::STANDARD.decode(&attachment.data)
                .map_err(|e| AiError::Image(e.to_string()))?;
            if data.len() > 5_000_000 { return Err(AiError::Image("Image attachment exceeds 5 MB".into())); }
            let decoded = crate::image::decode_any(&data)?;
            let png = encode_png(&decoded)?;
            let name = format!("attachment_{}.png", counter());
            let path = safe_resolve(&name, base).map_err(|e| AiError::Image(e.to_string()))?;
            std::fs::write(&path, &png).map_err(|e| AiError::Image(e.to_string()))?;
            content.push(Self::text(&format!("Attached image {:?} is available to tools as {name}", attachment.name)));
            content.push(Self::image("image/png", png));
        }
        let model = if request.images.is_empty() { &self.settings.text_model } else { &self.settings.vision_model };
        let mut session = self.session.lock().map_err(|_| AiError::Provider("Session is unavailable".into()))?;
        if session.system != request.system { session.reset(&request.system); }
        session.messages.push(Self::user(content));
        let checkpoint = session.messages.len() - 1;
        let result = (|| {
            for round in 0..MAX_TOOL_ROUNDS {
                let round_id = format!("round_{round}");
                observe(&mut emit, NativeEvent::Started { id: round_id.clone(), title: "Thinking".into() })?;
                let stream = self.runtime.block_on(self.stream(model, &session.system, session.messages.clone(), self.skill_tools()))?;
                let mut text = String::new();
                let mut calls = Vec::<(String, String, String)>::new();
                loop {
                    match self.runtime.block_on(stream.next_chunk()).map_err(|e| AiError::Provider(e.to_string()))? {
                        None => break,
                        Some(StreamChunk::TextChunk { text: delta }) => {
                            text.push_str(&delta);
                            observe(&mut emit, NativeEvent::Text { id: round_id.clone(), delta })?;
                        }
                        Some(StreamChunk::ThinkingChunk { thinking, .. }) => {
                            observe(&mut emit, NativeEvent::Thinking { id: round_id.clone(), delta: thinking })?;
                        }
                        Some(StreamChunk::RedactedThinkingChunk { .. }) => {},
                        Some(StreamChunk::ToolChunk { id, name, arguments_json, .. }) => {
                            merge_tool_chunk(&mut calls, id, name, arguments_json);
                        }
                        Some(StreamChunk::EndChunk { usage }) => {
                            if let Some(usage) = usage {
                                observe(&mut emit, NativeEvent::Usage {
                                    input_tokens: usage.input_tokens.unwrap_or(0) as i64,
                                    output_tokens: usage.output_tokens.unwrap_or(0) as i64,
                                })?;
                            }
                            break;
                        }
                        Some(StreamChunk::ErrorChunk { error }) => return Err(AiError::Provider(error.message)),
                    }
                }
                if calls.is_empty() {
                    if text.trim().is_empty() { return Err(AiError::NoText); }
                    session.messages.push(ProviderMessage { role: MessageRole::Assistant, content: vec![Self::text(&text)] });
                    observe(&mut emit, NativeEvent::Finished)?;
                    return Ok(());
                }
                let mut content = if text.is_empty() { vec![] } else { vec![Self::text(&text)] };
                for (id, name, args) in &calls {
                    content.push(MessageContent::ToolRequest { id: id.clone(), name: name.clone(), arguments_json: args.clone(), provider_metadata_json: None, tool_error_json: None });
                }
                session.messages.push(ProviderMessage { role: MessageRole::Assistant, content });
                let mut results = vec![];
                for (id, name, arguments) in calls {
                    observe(&mut emit, NativeEvent::ToolCall { id: id.clone(), name: name.clone(), arguments: arguments.clone() })?;
                    let result = self.native_tool(&id, &name, &arguments, base, &mut emit);
                    let (success, text) = match result { Ok(text) => (true, text), Err(e) => (false, e.to_string()) };
                    observe(&mut emit, NativeEvent::ToolResult { id: id.clone(), name, text: text.clone(), success })?;
                    results.push(tool_result(id, success, text));
                }
                session.messages.push(ProviderMessage { role: MessageRole::Tool, content: results });
            }
            Err(AiError::Provider("The agent reached its tool-round limit. Try a smaller request.".into()))
        })();
        // A failed/abandoned turn must not leave unmatched tool requests in history.
        if result.is_err() { session.messages.truncate(checkpoint); }
        result
    }

    fn native_tool<F>(&self, id: &str, name: &str, arguments: &str, base: &Path, emit: &mut F) -> Result<String, AiError>
    where F: FnMut(NativeEvent) -> bool {
        let params: serde_json::Value = serde_json::from_str(arguments).map_err(|e| AiError::Provider(e.to_string()))?;
        let kind = SkillKind::from_id(name).ok_or_else(|| AiError::Unsupported(name.into()))?;
        let image = if let Some(path) = params.get("image").and_then(|v| v.as_str()) {
            let path = safe_resolve(path, base).map_err(|e| AiError::Image(e.to_string()))?;
            Some(crate::image::decode_any(&std::fs::read(path).map_err(|e| AiError::Image(e.to_string()))?)?)
        } else { None };
        let prompt = params.get("prompt").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let output = Skills::run(Some(self), kind, SkillInput { prompt, image, images: vec![], params })?;
        let mut saved = vec![];
        for image in output.image.iter().chain(output.frames.iter()) {
            let name = format!("{name}_{}.png", counter());
            let png = encode_png(image)?;
            let path = safe_resolve(&name, base).map_err(|e| AiError::Image(e.to_string()))?;
            std::fs::write(&path, &png).map_err(|e| AiError::Image(e.to_string()))?;
            observe(emit, NativeEvent::Artifact {
                id: name.clone(), parent_id: id.into(), name: name.clone(),
                png: base64::engine::general_purpose::STANDARD.encode(&png), width: image.width, height: image.height,
            })?;
            saved.push(name);
        }
        Ok(format!("{}\n{}", output.text, saved.join("\n")))
    }
}

fn observe<F: FnMut(NativeEvent) -> bool>(emit: &mut F, event: NativeEvent) -> Result<(), AiError> {
    if emit(event) { Ok(()) } else { Err(AiError::Provider("Stopped by user".into())) }
}

fn merge_tool_chunk(calls: &mut Vec<(String, String, String)>, id: String, name: String, arguments: String) {
    if let Some(call) = calls.iter_mut().find(|call| call.0 == id) {
        if !name.is_empty() { call.1 = name; }
        if serde_json::from_str::<serde_json::Value>(&arguments).is_ok() { call.2 = arguments; }
        else { call.2.push_str(&arguments); }
    } else { calls.push((id, name, arguments)); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tool_fragments_are_assembled_without_duplicate_execution() {
        let mut calls = vec![];
        merge_tool_chunk(&mut calls, "1".into(), "generate_art".into(), "{\"prompt\":".into());
        merge_tool_chunk(&mut calls, "1".into(), "".into(), "\"cat\"}".into());
        assert_eq!(calls, vec![("1".into(), "generate_art".into(), "{\"prompt\":\"cat\"}".into())]);
    }
    #[test]
    fn observer_can_stop_and_event_contract_preserves_tool_identity() {
        let event = NativeEvent::ToolResult { id: "tool-1".into(), name: "custom_tool".into(), text: "failed".into(), success: false };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "tool_result");
        assert_eq!(json["id"], "tool-1");
        assert_eq!(json["success"], false);
        assert!(observe(&mut |_| false, event).is_err());
    }
}
