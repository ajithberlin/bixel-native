//! # bixel-core
//!
//! Platform-independent domain engine for Bixel Studio — a native desktop-class
//! web studio for 2D game asset creation. This crate holds the *headless* logic
//! (no UI, no I/O beyond the filesystem) so it can be unit-tested and shared
//! across every frontend: Swift + Metal (macOS/iPadOS), a future Web/WebGPU
//! shell, or Tauri for Windows/Linux.
//!
//! The original studio was a Python + FastAPI backend with a zero-dependency
//! browser frontend. This crate is the Rust port of that backend's domain
//! logic, reorganized into focused modules:
//!
//! * [`document`] — Aseprite-compatible sprite document: cels, layers, frames,
//!   tags, pixel buffers, undo/redo, and frame compositing.
//! * [`palette`] — preset palettes (DB32, PICO-8, Game Boy) and color math.
//! * [`timeline`] — animation playback controller (loop modes, tag bounds,
//!   onion skinning).
//! * [`tilemap`] — headless tile-layer paint math, patterns, autotile, minimap.
//! * [`atlas`] — sprite-sheet atlas schema validation.
//! * [`map_validate`] — Tiled map continuity/structural validation (Bonfire).
//! * [`paths`] — app-home resolution, project roots and the path jail.
//! * [`project`] — project create/list/load/delete + active-project state.
//! * [`sources`] — in-place source references (folders/files opened directly).
//! * [`config`] — AI provider configuration and API-token storage.
//! * [`clipboard`] — per-project asset clip tray.
//! * [`audits`] — persisted, dated validation reports.
//! * [`jobs`] — subprocess execution queue with log streaming and cancellation.
//!
//! Note: AI/network code lives in the separate [`bixel-ai`] crate (goose SDK →
//! OpenRouter); this crate stays UI-free and network-free.

pub mod atlas;
pub mod audits;
pub mod clipboard;
pub mod color;
pub mod config;
pub mod document;
pub mod jobs;
pub mod map;
pub mod map_validate;
pub mod palette;
pub mod paths;
pub mod project;
pub mod sheet;
pub mod sources;
pub mod tilemap;
pub mod timeline;

pub use color::Rgba;
pub use document::AsepriteDoc;
pub use paths::PathJailError;
pub use project::{Project, ProjectError};
pub use sources::SourceError;

pub mod storage;
