# Game asset workspace

Approved direction: a project groups independent sprite, animation, spritesheet, tileset, map, and image documents, rather than imposing a single pixel size. Legacy document.json must remain loadable. Each document records its own dimensions and optional cell size; map dimensions are expressed in cells. Project style and palette inform AI along with active document/frame/layer context. Ambiguous generation requests require focused clarification rather than treating canvas dimensions as universal output dimensions.

Generated sources, prepared images, code and intermediate files belong under .studio/cache. Accepted documents and assets persist separately from disposable intermediates. Large generated images are prepared locally only for an explicit target, preserving the source. Sprites default to transparent backgrounds; backgrounds and terrain can be opaque. Library images can be placed as undoable layers without resizing the destination. Sheets can be sliced into animation frames and animations packed for export. Maps use cell-aligned tile placement and layered documents.

Constraints: macOS 13+, SwiftUI/Metal frontend, whole-buffer Rust processing, filesystem access through safe_resolve, no Apple/network dependencies in bixel-core. Existing uncommitted editor work must be preserved.
