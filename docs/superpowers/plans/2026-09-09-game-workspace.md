# Game Workspace Implementation Plan

> Execute task-by-task using subagent-driven-development, with focused reviews and final verification.

**Goal:** Make Bixel a multi-document game asset workspace with project-aware AI and reusable generated assets.
**Architecture:** Keep document pixels in Rust; Swift owns project catalog and UI state through the existing Rust storage gateway. Extend deterministic Rust image processing and cache inventory; pass fresh editor context per assistant request.
**Tech Stack:** Rust, SwiftUI, Metal, existing JSON storage and C ABI.
**Spec:** docs/superpowers/specs/2026-09-09-game-workspace-design.md

## Global Constraints
- macOS 13+, no new dependencies; no Apple/network imports in bixel-core.
- Bulk pixel processing in Rust; all managed filesystem paths use safe_resolve.
- Preserve legacy projects and existing local editor changes.

## Tasks
- [ ] Rust storage: add bounded recursive cache inventory and binary reads through existing JSON gateway. Test nested files and traversal/symlink rejection.
- [ ] Rust generation: explicit-target preparation with background policy, source retention, dimensions/alpha diagnostics, meaningful local tests. Never infer project-wide output size.
- [ ] Workspace catalog: independent document metadata, durable document paths, active document persistence, legacy migration, shared style. Test Codable metadata and validation with Swift harness.
- [ ] Workspace UI: project creation independent of canvas size; library/new-document controls for all asset kinds; cache previews and acceptance.
- [ ] Editor integration: bulk undoable placement, cell-aligned map stamps, spritesheet slicing and animation packing; canvas drop and timeline import.
- [ ] Assistant: fresh project/document/frame/layer context, clarification policy, available asset inventory, draggable chat images.
- [ ] Verify Rust tests, Swift typecheck, native build; review changes for persistence failures, resizing, and cache boundaries.

## Decisions
- Work in the current checkout if worktree creation is blocked, preserving user edits.
- Initial map editing uses the existing layered document engine with cell-aligned stamps; no engine-specific map format is presumed.
- No automatic deletion of generated sources or project assets.
