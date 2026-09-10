//! Image generation through the ChatGPT (Codex) backend: the Responses API
//! hosted `image_generation` tool, driven by the same OAuth token the goose
//! `chatgpt_codex` provider caches. No OpenRouter key is involved.

use std::path::PathBuf;

use base64::Engine as _;
use chrono::{DateTime, Utc};

use crate::connection::ensure_goose_env;
use crate::error::AiError;
use crate::image::{decode_any, encode_png, RgbaImage};
use crate::image_gen::ImageGenerator;

const ISSUER: &str = "https://auth.openai.com";
const CODEX_API_ENDPOINT: &str = "https://chatgpt.com/backend-api/codex";
const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
/// Hosted image generation can take a couple of minutes for large renders.
const IMAGE_TIMEOUT_SECS: u64 = 300;

#[derive(Debug, serde::Deserialize, serde::Serialize)]
struct TokenData {
    access_token: String,
    refresh_token: String,
    id_token: Option<String>,
    expires_at: DateTime<Utc>,
    account_id: Option<String>,
}

/// Synchronous client for the Codex backend's hosted image-generation tool.
pub struct CodexImageGen {
    model: String,
    tokens_path: PathBuf,
}

impl CodexImageGen {
    /// `model` is the connected Codex chat model (the hosted tool rides it).
    pub fn new(model: &str) -> Result<Self, AiError> {
        let root = ensure_goose_env()?;
        Ok(CodexImageGen {
            model: model.to_string(),
            tokens_path: root.join("config/chatgpt_codex/tokens.json"),
        })
    }

    fn client() -> Result<reqwest::blocking::Client, AiError> {
        reqwest::blocking::Client::builder()
            .connect_timeout(std::time::Duration::from_secs(30))
            .timeout(std::time::Duration::from_secs(IMAGE_TIMEOUT_SECS))
            .build()
            .map_err(|e| AiError::Provider(e.to_string()))
    }

    /// Load the cached token, refreshing it (and persisting the rotation)
    /// when it is expired or about to expire — same flow as goose's provider.
    fn valid_token(&self) -> Result<TokenData, AiError> {
        let read = |path: &PathBuf| -> Result<TokenData, AiError> {
            let text = std::fs::read_to_string(path)
                .map_err(|e| AiError::Config(format!("ChatGPT token cache unreadable: {e}")))?;
            serde_json::from_str(&text)
                .map_err(|e| AiError::Config(format!("ChatGPT token cache corrupt: {e}")))
        };
        let mut token = read(&self.tokens_path)?;
        if token.expires_at > Utc::now() + chrono::Duration::seconds(60) {
            return Ok(token);
        }
        let resp = Self::client()?
            .post(format!("{ISSUER}/oauth/token"))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", token.refresh_token.as_str()),
                ("client_id", CLIENT_ID),
            ])
            .send()
            .map_err(|e| AiError::Provider(format!("ChatGPT token refresh failed: {e}")))?;
        if !resp.status().is_success() {
            return Err(AiError::Provider(format!(
                "ChatGPT token refresh failed ({}): {}",
                resp.status(),
                resp.text().unwrap_or_default()
            )));
        }
        #[derive(serde::Deserialize)]
        struct RefreshResponse {
            access_token: String,
            refresh_token: String,
            id_token: Option<String>,
            expires_in: Option<i64>,
        }
        let refreshed: RefreshResponse = resp
            .json()
            .map_err(|e| AiError::Provider(format!("ChatGPT token refresh response invalid: {e}")))?;
        token.access_token = refreshed.access_token;
        token.refresh_token = refreshed.refresh_token;
        if refreshed.id_token.is_some() {
            token.id_token = refreshed.id_token;
        }
        token.expires_at =
            Utc::now() + chrono::Duration::seconds(refreshed.expires_in.unwrap_or(3600));
        let json = serde_json::to_string(&token)
            .map_err(|e| AiError::Config(format!("cannot serialize token: {e}")))?;
        #[cfg(unix)]
        {
            use std::io::Write as _;
            let mut file = std::fs::File::create(&self.tokens_path)
                .map_err(|e| AiError::Config(format!("cannot write token cache: {e}")))?;
            let mut perms = file
                .metadata()
                .map_err(|e| AiError::Config(e.to_string()))?
                .permissions();
            #[allow(clippy::permissions_set_readonly_false)]
            perms.set_readonly(false);
            use std::os::unix::fs::PermissionsExt as _;
            let _ = perms.set_mode(0o600);
            file.write_all(json.as_bytes())
                .map_err(|e| AiError::Config(format!("cannot write token cache: {e}")))?;
        }
        #[cfg(not(unix))]
        std::fs::write(&self.tokens_path, &json)
            .map_err(|e| AiError::Config(format!("cannot write token cache: {e}")))?;
        Ok(token)
    }
}

impl ImageGenerator for CodexImageGen {
    fn model(&self) -> &str {
        &self.model
    }

    fn generate_image(&self, prompt: &str, input: Option<&RgbaImage>) -> Result<RgbaImage, AiError> {
        let token = self.valid_token()?;

        // The hosted tool generates from the conversation: an input image is
        // attached as input_image so the model can carry it into the render.
        let mut content = Vec::new();
        if let Some(image) = input {
            let b64 = base64::engine::general_purpose::STANDARD.encode(encode_png(image)?);
            content.push(serde_json::json!({
                "type": "input_image",
                "image_url": format!("data:image/png;base64,{b64}"),
            }));
        }
        content.push(serde_json::json!({ "type": "input_text", "text": prompt }));

        let body = serde_json::json!({
            "model": self.model,
            "input": [{ "role": "user", "content": content }],
            "tools": [{ "type": "image_generation" }],
            "store": false,
            "stream": true,
        });

        let mut request = Self::client()?
            .post(format!("{CODEX_API_ENDPOINT}/responses"))
            .header("Authorization", format!("Bearer {}", token.access_token))
            .header("Content-Type", "application/json")
            .json(&body);
        if let Some(account_id) = &token.account_id {
            request = request.header("chatgpt-account-id", account_id);
        }
        let resp = request
            .send()
            .map_err(|e| AiError::Provider(format!("Codex image request failed: {e}")))?;
        if !resp.status().is_success() {
            return Err(AiError::Provider(format!(
                "Codex image endpoint {}: {}",
                resp.status(),
                resp.text().unwrap_or_default().trim()
            )));
        }
        parse_image_events(&resp.text().unwrap_or_default())
    }
}

/// Scan an SSE event stream for the hosted tool's image payload: prefer the
/// final `image_generation_call` result, fall back to the last partial image.
fn parse_image_events(body: &str) -> Result<RgbaImage, AiError> {
    let mut partial: Option<String> = None;
    for line in body.lines() {
        let data = line.strip_prefix("data:").map(str::trim);
        let Some(data) = data else { continue };
        if data == "[DONE]" {
            break;
        }
        let Ok(event) = serde_json::from_str::<serde_json::Value>(data) else { continue };
        match event.get("type").and_then(|t| t.as_str()) {
            Some("response.output_item.done") => {
                let item = &event["item"];
                if item.get("type").and_then(|t| t.as_str()) == Some("image_generation_call") {
                    if let Some(result) = item.get("result").and_then(|r| r.as_str()) {
                        return decode_b64(result);
                    }
                }
            }
            Some("response.image_generation_call.partial_image") => {
                if let Some(b64) = event.get("partial_image_b64").and_then(|b| b.as_str()) {
                    partial = Some(b64.to_string());
                }
            }
            Some("response.failed") => {
                return Err(AiError::Provider(format!(
                    "Codex image generation failed: {data}"
                )));
            }
            _ => {}
        }
    }
    match partial {
        Some(b64) => decode_b64(&b64),
        None => Err(AiError::NoImage),
    }
}

fn decode_b64(b64: &str) -> Result<RgbaImage, AiError> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|e| AiError::Image(format!("bad base64: {e}")))?;
    decode_any(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_parser_prefers_final_result() {
        // A tiny valid 1x1 PNG stands in for the final result; the partial
        // payload is junk. Success can only come from the final result.
        let png = base64::engine::general_purpose::STANDARD.encode(
            crate::image::encode_png(&RgbaImage {
                data: vec![0, 255, 0, 255],
                width: 1,
                height: 1,
            })
            .unwrap(),
        );
        let body = format!(
            "data: {{\"type\": \"response.image_generation_call.partial_image\", \"partial_image_b64\": \"AAAA\"}}\n\n\
             data: {{\"type\": \"response.output_item.done\", \"item\": {{\"type\": \"image_generation_call\", \"result\": \"{png}\"}}}}\n\n\
             data: [DONE]\n\n"
        );
        let image = parse_image_events(&body).unwrap();
        assert_eq!((image.width, image.height), (1, 1));
    }

    #[test]
    fn sse_parser_falls_back_to_partial() {
        // A tiny valid 1x1 PNG.
        let png = base64::engine::general_purpose::STANDARD.encode(
            crate::image::encode_png(&RgbaImage {
                data: vec![255, 0, 0, 255],
                width: 1,
                height: 1,
            })
            .unwrap(),
        );
        let body = format!(
            "data: {{\"type\": \"response.image_generation_call.partial_image\", \"partial_image_b64\": \"{png}\"}}\n\ndata: [DONE]\n\n"
        );
        let image = parse_image_events(&body).unwrap();
        assert_eq!((image.width, image.height), (1, 1));
    }

    #[test]
    fn sse_parser_errors_when_no_image() {
        let body = "data: {\"type\": \"response.output_text.delta\", \"delta\": \"hi\"}\n\ndata: [DONE]\n\n";
        assert!(parse_image_events(body).is_err());
    }
}
