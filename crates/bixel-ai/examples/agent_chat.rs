use bixel_ai::native_stream::{NativeEvent, NativeRequest};
use bixel_ai::{AiSettings, GooseAgent};

fn main() {
    let settings = AiSettings::from_env_file();
    println!("models: text={} image={}", settings.text_model, settings.image_model);
    let agent = GooseAgent::new(settings).expect("failed to build goose agent");

    let base = std::env::temp_dir().join("bixel-headless-test");
    let request = NativeRequest {
        prompt: "Reply with exactly one word: hello".into(),
        system: String::new(),
        base: base.to_string_lossy().into_owned(),
        images: vec![],
    };

    let mut saw_text = false;
    let result = agent.chat_stream(request, |event| {
        match event {
            NativeEvent::Text { delta, .. } => {
                print!("{delta}");
                saw_text = true;
            }
            NativeEvent::Thinking { .. } => {}
            NativeEvent::ToolCall { name, .. } => println!("\n[tool: {name}]"),
            NativeEvent::ToolResult { name, success, .. } => {
                println!("\n[tool result: {name} success={success}]");
            }
            NativeEvent::Usage { input_tokens, output_tokens } => {
                println!("\n[usage in={input_tokens} out={output_tokens}]");
            }
            NativeEvent::Error { message } => println!("\n[ERROR: {message}]"),
            NativeEvent::Finished => {}
            NativeEvent::Started { .. } => {}
            NativeEvent::Artifact { name, .. } => println!("\n[artifact: {name}]"),
        }
        true
    });

    println!();
    match result {
        Ok(()) => println!("=== chat_stream OK, saw_text={saw_text} ==="),
        Err(e) => println!("=== chat_stream FAILED: {e} ==="),
    }
}
