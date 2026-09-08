use bixel_ai::{AiSettings, Engine};

/// Validates the declarative OpenRouter JSON against the real goose SDK
/// (constructing a provider makes no network call). The env var is
/// process-global, so both checks run in a single test to avoid races.
#[test]
fn engine_construction_lifecycle() {
    // With a key, construction succeeds (no network call is made).
    std::env::set_var("OPENROUTER_API_KEY", "sk-or-dummy-key-for-construction");
    let settings = AiSettings::from_env();
    let engine = Engine::new(settings);
    assert!(engine.is_ok(), "engine construction failed: {:?}", engine.err());

    // Without a key, construction fails fast with a config error.
    std::env::remove_var("OPENROUTER_API_KEY");
    let settings = AiSettings { api_key: String::new(), ..Default::default() };
    let engine = Engine::new(settings);
    assert!(engine.is_err());
}
