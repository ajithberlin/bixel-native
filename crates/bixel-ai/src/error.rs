//! Error types for the AI engine.

/// Errors raised by the AI engine and skills.
#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("missing configuration: {0}")]
    Config(String),
    #[error("provider error: {0}")]
    Provider(String),
    #[error("image error: {0}")]
    Image(String),
    #[error("no image produced by the model")]
    NoImage,
    #[error("no text produced by the model")]
    NoText,
    #[error("unsupported skill: {0}")]
    Unsupported(String),
}

impl From<png::EncodingError> for AiError {
    fn from(e: png::EncodingError) -> Self {
        AiError::Image(e.to_string())
    }
}

impl From<png::DecodingError> for AiError {
    fn from(e: png::DecodingError) -> Self {
        AiError::Image(e.to_string())
    }
}
