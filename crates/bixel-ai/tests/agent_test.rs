use bixel_ai::{ConnectionConfig, GooseAgent, ProviderChoice};

/// Construction makes no network call, and connect/disconnect can re-enter.
/// The env vars are process-global, so the whole lifecycle runs in a single
/// test to avoid races. `validate: false` + dummy key keeps this offline:
/// provider construction reads credentials but does not call the network.
#[test]
fn agent_connect_disconnect_lifecycle() {
    let root = std::env::temp_dir().join(format!("bixel-ai-test-{}", std::process::id()));
    std::env::set_var("GOOSE_PATH_ROOT", &root);
    // File-backed secrets (no Keychain) for the test process.
    std::env::set_var("GOOSE_DISABLE_KEYRING", "1");

    let agent = GooseAgent::new().expect("construction failed");
    assert!(agent.handle().is_none());

    // Without a key, connect fails fast with a config error.
    let no_key = ConnectionConfig {
        provider: ProviderChoice::OpenRouter,
        api_key: None,
        validate: false,
        ..Default::default()
    };
    assert!(agent.connect(no_key).is_err());

    // With a (dummy) key, connect succeeds offline and caches the provider.
    let cfg = ConnectionConfig {
        provider: ProviderChoice::OpenRouter,
        api_key: Some("sk-or-dummy-key-for-construction".into()),
        validate: false,
        ..Default::default()
    };
    let readiness = agent.connect(cfg.clone()).expect("connect failed");
    assert!(readiness.text.ready, "text role should be ready without a probe");
    assert!(readiness.vision.ready);
    assert!(readiness.image.ready);
    assert!(agent.handle().is_some());
    assert!(agent.image_gen().is_some());

    // Re-entry: connecting again replaces the handle.
    agent.connect(cfg).expect("reconnect failed");
    assert!(agent.handle().is_some());

    agent.disconnect().expect("disconnect failed");
    assert!(agent.handle().is_none());
    assert!(agent.image_gen().is_none());
}
