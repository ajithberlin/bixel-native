# Local projects

Use the project button in the top bar to create or open a project. The last open
project is restored at launch. Completed edits autosave, preserving layers,
visibility, frame durations, and pixels. Project switching is blocked during an
assistant turn; stop it and wait for completion before switching.

The host resolves `FileManager.documentDirectory`, then uses:

```
Bixel/Projects/<project UUID>/
  project.json
  document.json
  assistant.json
  .studio/cache/ai/<conversation UUID>/
    inputs/
    generated images and code
```

The picker’s **AI Files** button opens the generated-files folder. This is durable
storage in Documents, despite the cache folder name; it is not an OS-purgeable
temporary directory. A future iPad host can pass its own sandbox Documents URL to
the same Rust storage API. The current UI and renderer remain macOS-specific.

Conversations and their archived history belong to the project. New Chat starts a
new conversation workspace. Switching back restores the saved conversation; after
restoration the assistant receives at most 12,000 characters of recent text and
artifact names, without replaying image payloads or full tool logs. Goose retains
its normal live context compaction, and each request is limited to 20 agent turns.
The developer extension uses the conversation cache as its working directory and
is instructed to keep generated files there; it is not an operating-system sandbox.

Existing temporary assistant workspaces are not automatically imported.

Verification: `cargo test -p bixel-core`, `cargo test -p bixel-ai --lib`, then
`scripts/build-rust.sh` and `scripts/test-assistant.sh`. For a faster local Swift
test link, build `cargo build -p bixel-ffi` and run
`BIXEL_TEST_LIBRARY_DIR=target/debug scripts/test-assistant.sh`.
