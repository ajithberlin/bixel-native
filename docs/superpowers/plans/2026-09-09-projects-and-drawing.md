# Projects and responsive drawing

Goal: responsive pointer input and durable, isolated projects on macOS, with host-provided Documents storage suitable for an iPad sandbox.

- Replace per-drag global observation with a canvas invalidation publisher. Composite/upload once per display callback, cache timeline composites, finish strokes outside the view, accept the first click.
- Add a Rust filesystem gateway using explicit roots and safe_resolve, atomic writes, project create/list, and validated lossless document serialization.
- Add a Foundation project store and SwiftUI create/open picker. Autosave completed edits on a serial background queue; flush before switching. Restore complete layered documents.
- Persist assistant transcripts, attachments and local/generated outputs per project. Use a distinct working directory per conversation, isolate goose sessions by working directory, and bound restored textual context. Disable switching during active generation.
- Verify Rust persistence/path tests, Swift stroke and project/session round trips, then build the macOS app. No network model requests are required for verification.

Storage: Documents/Bixel/Projects/<UUID>/project.json, document.json, assistant.json, .studio/cache/ai/<conversation UUID>/. Generated code and assets use the conversation directory as the agent working directory. Durable user work is never placed in an OS-evictable cache.
