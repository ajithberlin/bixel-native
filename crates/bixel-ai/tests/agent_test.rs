use bixel_ai::{AiSettings, GooseAgent};

/// Validates that constructing the embedded goose agent makes no network call:
/// building the `Agent` (provider creation is lazy) succeeds with a key and
/// fails fast without one. The env var is process-global, so both checks run in
/// a single test to avoid races.
#[test]
fn agent_construction_lifecycle() {
    // With a key, construction succeeds (provider is created lazily).
    std::env::set_var("OPENROUTER_API_KEY", "sk-or-dummy-key-for-construction");
    let settings = AiSettings::from_env();
    let agent = GooseAgent::new(settings);
    assert!(agent.is_ok(), "agent construction failed: {:?}", agent.err());

    // Without a key, construction fails fast with a config error.
    std::env::remove_var("OPENROUTER_API_KEY");
    let settings = AiSettings { api_key: String::new(), ..Default::default() };
    let agent = GooseAgent::new(settings);
    assert!(agent.is_err());
}
