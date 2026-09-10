//! Native agent events crossing the FFI boundary. Every visible node corresponds
//! to an actual goose agent or tool event.

use serde::{Deserialize, Serialize};

/// A base64 image attachment sent from the host with a request.
#[derive(Debug, Clone, Deserialize)]
pub struct NativeAttachment {
    pub name: String,
    pub data: String,
}

/// A host-originated chat request.
#[derive(Debug, Deserialize)]
pub struct NativeRequest {
    pub prompt: String,
    pub system: String,
    pub base: String,
    #[serde(default)]
    pub images: Vec<NativeAttachment>,
}

/// An event emitted to the host while the goose agent streams a reply.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NativeEvent {
    Started { id: String, title: String },
    Thinking { id: String, delta: String },
    Text { id: String, delta: String },
    ToolCall { id: String, name: String, arguments: String },
    ToolResult { id: String, name: String, text: String, success: bool },
    Artifact {
        id: String,
        parent_id: String,
        name: String,
        png: String,
        width: usize,
        height: usize,
        source: bool,
        /// JSON array of per-frame `{duration_ms, tag}` for sheet artifacts.
        #[serde(skip_serializing_if = "Option::is_none")]
        frame_meta: Option<String>,
        /// Sheet manifest (JSON) that produced the frames, when available.
        #[serde(skip_serializing_if = "Option::is_none")]
        atlas: Option<String>,
    },
    Usage { input_tokens: i64, output_tokens: i64 },
    Finished,
    Error { message: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_contract_is_tagged() {
        let event = NativeEvent::ToolResult {
            id: "tool-1".into(),
            name: "compress".into(),
            text: "ok".into(),
            success: true,
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "tool_result");
        assert_eq!(json["id"], "tool-1");
        assert_eq!(json["success"], true);
    }
}
