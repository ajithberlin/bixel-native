//! Animation playback controller (port of `web/aseprite/timeline.js`).
//!
//! High-precision playback clock with a delta accumulator, forward/reverse/
//! ping-pong looping, tag-constrained playback, per-frame durations, and onion
//! skinning state. There is no `requestAnimationFrame` here: the host (Swift
//! via Metal/CVDisplayLink, or a Web shell) drives [`TimelineController::update`]
//! with elapsed milliseconds and reads [`TimelineController::state`] to render.
//! Events are intentionally omitted — polling is the FFI-friendly contract.

use std::cell::RefCell;
use std::rc::Rc;

use crate::document::AsepriteDoc;

/// Loop behaviour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoopMode {
    Forward,
    Reverse,
    PingPong,
}

impl LoopMode {
    fn validate(mode: &str) -> Self {
        match mode {
            "reverse" => LoopMode::Reverse,
            "ping-pong" => LoopMode::PingPong,
            _ => LoopMode::Forward,
        }
    }
}

/// Onion-skin tinting mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnionMode {
    Opacity,
    RedBlue,
}

/// Onion-skinning configuration.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OnionSkin {
    pub enabled: bool,
    pub mode: OnionMode,
    pub prev: usize,
    pub next: usize,
}

impl Default for OnionSkin {
    fn default() -> Self {
        OnionSkin {
            enabled: false,
            mode: OnionMode::Opacity,
            prev: 3,
            next: 1,
        }
    }
}

/// Read-only view the controller needs over its document.
pub trait TimelineDoc {
    fn frame_count(&self) -> usize;
    fn frame_duration(&self, idx: usize) -> Option<u32>;
    fn set_frame_duration(&mut self, idx: usize, ms: u32);
    /// Inclusive frame range `(from, to)` for a named tag, if present.
    fn tag_range(&self, name: &str) -> Option<(usize, usize)>;
}

impl TimelineDoc for AsepriteDoc {
    fn frame_count(&self) -> usize {
        self.frames.len()
    }

    fn frame_duration(&self, idx: usize) -> Option<u32> {
        self.frames.get(idx).map(|f| f.duration_ms)
    }

    fn set_frame_duration(&mut self, idx: usize, ms: u32) {
        if let Some(frame) = self.frames.get_mut(idx) {
            frame.duration_ms = ms;
        }
    }

    fn tag_range(&self, name: &str) -> Option<(usize, usize)> {
        self.tags
            .iter()
            .find(|t| t.name == name)
            .map(|t| (t.from, t.to))
    }
}

/// Shared-handle form so the UI can own the document while the controller
/// borrows it (`TimelineController<Rc<RefCell<AsepriteDoc>>>`).
impl<T: TimelineDoc> TimelineDoc for Rc<RefCell<T>> {
    fn frame_count(&self) -> usize {
        self.borrow().frame_count()
    }
    fn frame_duration(&self, idx: usize) -> Option<u32> {
        self.borrow().frame_duration(idx)
    }
    fn set_frame_duration(&mut self, idx: usize, ms: u32) {
        self.borrow_mut().set_frame_duration(idx, ms)
    }
    fn tag_range(&self, name: &str) -> Option<(usize, usize)> {
        self.borrow().tag_range(name)
    }
}

/// Thread-safe shared-handle form used across the FFI boundary
/// (`TimelineController<Arc<Mutex<AsepriteDoc>>>`).
impl<T: TimelineDoc> TimelineDoc for std::sync::Arc<std::sync::Mutex<T>> {
    fn frame_count(&self) -> usize {
        self.lock().unwrap().frame_count()
    }
    fn frame_duration(&self, idx: usize) -> Option<u32> {
        self.lock().unwrap().frame_duration(idx)
    }
    fn set_frame_duration(&mut self, idx: usize, ms: u32) {
        self.lock().unwrap().set_frame_duration(idx, ms)
    }
    fn tag_range(&self, name: &str) -> Option<(usize, usize)> {
        self.lock().unwrap().tag_range(name)
    }
}

/// A point-in-time snapshot for the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct TimelineState {
    pub current_frame: usize,
    pub playing: bool,
    pub loop_mode: LoopMode,
    pub fps: f32,
    pub active_tag: Option<String>,
    pub onion_skin: OnionSkin,
    pub frame_duration: u32,
}

/// Animation playback controller.
pub struct TimelineController<D: TimelineDoc> {
    doc: D,
    fps: f32,
    loop_mode: LoopMode,
    active_tag: Option<String>,
    playing: bool,
    accumulator: f32,
    ping_pong_direction: i8,
    onion_skin: OnionSkin,
    current_frame: usize,
}

impl<D: TimelineDoc> TimelineController<D> {
    pub fn new(doc: D) -> Self {
        let mut ctl = TimelineController {
            doc,
            fps: 8.0,
            loop_mode: LoopMode::Forward,
            active_tag: None,
            playing: false,
            accumulator: 0.0,
            ping_pong_direction: 1,
            onion_skin: OnionSkin::default(),
            current_frame: 0,
        };
        let count = ctl.doc.frame_count();
        ctl.current_frame = if count == 0 { 0 } else { 0 };
        ctl
    }

    /// Resolved playback bounds for the active tag (or the whole doc).
    fn tag_range(&self) -> (usize, usize) {
        let total = self.doc.frame_count();
        if total == 0 {
            return (0, 0);
        }
        let max = total - 1;
        let Some(name) = &self.active_tag else {
            return (0, max);
        };
        let Some((from, to)) = self.doc.tag_range(name) else {
            return (0, max);
        };
        let bounded_from = from.min(max);
        let bounded_to = to.min(max);
        (bounded_from.min(bounded_to), bounded_from.max(bounded_to))
    }

    fn set_current(&mut self, val: usize) {
        let (min, max) = self.tag_range();
        self.current_frame = val.clamp(min, max);
    }

    pub fn current_frame(&self) -> usize {
        self.current_frame
    }

    pub fn next_frame(&mut self) -> usize {
        let (min, max) = self.tag_range();
        if min == max {
            self.current_frame = min;
            return self.current_frame;
        }

        match self.loop_mode {
            LoopMode::Reverse => {
                if self.current_frame > min {
                    self.current_frame -= 1;
                } else {
                    self.current_frame = max;
                }
            }
            LoopMode::PingPong => {
                if self.ping_pong_direction == 1 {
                    if self.current_frame < max {
                        self.current_frame += 1;
                    }
                    if self.current_frame >= max {
                        self.current_frame = max;
                        self.ping_pong_direction = -1;
                    }
                } else {
                    if self.current_frame > min {
                        self.current_frame -= 1;
                    }
                    if self.current_frame <= min {
                        self.current_frame = min;
                        self.ping_pong_direction = 1;
                    }
                }
            }
            LoopMode::Forward => {
                if self.current_frame < max {
                    self.current_frame += 1;
                } else {
                    self.current_frame = min;
                }
            }
        }
        self.current_frame
    }

    pub fn prev_frame(&mut self) -> usize {
        let (min, max) = self.tag_range();
        if min == max {
            self.current_frame = min;
            return self.current_frame;
        }

        match self.loop_mode {
            LoopMode::Reverse => {
                if self.current_frame < max {
                    self.current_frame += 1;
                } else {
                    self.current_frame = min;
                }
            }
            LoopMode::PingPong => {
                if self.ping_pong_direction == -1 {
                    if self.current_frame < max {
                        self.current_frame += 1;
                    }
                    if self.current_frame >= max {
                        self.current_frame = max;
                        self.ping_pong_direction = 1;
                    }
                } else {
                    if self.current_frame > min {
                        self.current_frame -= 1;
                    }
                    if self.current_frame <= min {
                        self.current_frame = min;
                        self.ping_pong_direction = -1;
                    }
                }
            }
            LoopMode::Forward => {
                if self.current_frame > min {
                    self.current_frame -= 1;
                } else {
                    self.current_frame = max;
                }
            }
        }
        self.current_frame
    }

    pub fn first_frame(&mut self) -> usize {
        let (min, _) = self.tag_range();
        self.current_frame = min;
        self.accumulator = 0.0;
        self.ping_pong_direction = 1;
        self.current_frame
    }

    pub fn last_frame(&mut self) -> usize {
        let (_, max) = self.tag_range();
        self.current_frame = max;
        self.accumulator = 0.0;
        self.ping_pong_direction = -1;
        self.current_frame
    }

    pub fn go_to_frame(&mut self, idx: usize) -> usize {
        self.set_current(idx);
        self.accumulator = 0.0;
        self.current_frame
    }

    pub fn play(&mut self) {
        self.playing = true;
    }

    pub fn pause(&mut self) {
        self.playing = false;
    }

    pub fn toggle(&mut self) -> bool {
        self.playing = !self.playing;
        self.playing
    }

    pub fn is_playing(&self) -> bool {
        self.playing
    }

    pub fn set_fps(&mut self, fps: f32, update_frames: bool) -> f32 {
        self.fps = fps.max(0.1);
        if update_frames {
            let ms = ((1000.0 / self.fps).round() as u32).max(1);
            let count = self.doc.frame_count();
            for i in 0..count {
                self.doc.set_frame_duration(i, ms);
            }
        }
        self.fps
    }

    pub fn fps(&self) -> f32 {
        self.fps
    }

    pub fn frame_duration(&self, idx: Option<usize>) -> u32 {
        let idx = idx.unwrap_or(self.current_frame);
        self.doc
            .frame_duration(idx)
            .map(|d| d.max(1))
            .unwrap_or_else(|| ((1000.0 / self.fps).round() as u32).max(1))
    }

    pub fn set_frame_duration(&mut self, idx: usize, ms: u32) -> u32 {
        let duration = ms.max(1);
        self.doc.set_frame_duration(idx, duration);
        duration
    }

    pub fn set_loop_mode(&mut self, mode: &str) -> LoopMode {
        self.loop_mode = LoopMode::validate(mode);
        self.ping_pong_direction = match self.loop_mode {
            LoopMode::Reverse => -1,
            _ => 1,
        };
        self.loop_mode
    }

    pub fn loop_mode(&self) -> LoopMode {
        self.loop_mode
    }

    pub fn set_active_tag(&mut self, name: Option<String>) {
        self.active_tag = name;
        let (min, max) = self.tag_range();
        if self.current_frame < min || self.current_frame > max {
            self.current_frame = if self.loop_mode == LoopMode::Reverse { max } else { min };
        }
        self.accumulator = 0.0;
        self.ping_pong_direction = 1;
    }

    pub fn active_tag(&self) -> Option<&str> {
        self.active_tag.as_deref()
    }

    pub fn set_onion_skin(&mut self, onion: OnionSkin) {
        self.onion_skin = onion;
    }

    pub fn toggle_onion_skin(&mut self, enabled: bool) {
        self.onion_skin.enabled = enabled;
    }

    pub fn onion_skin(&self) -> OnionSkin {
        self.onion_skin
    }

    /// Advance the internal clock by `delta_ms`, stepping frames as needed.
    pub fn update(&mut self, delta_ms: f32) -> usize {
        if delta_ms.is_nan() || delta_ms <= 0.0 {
            return self.current_frame;
        }
        self.accumulator += delta_ms;
        let mut steps = 0;
        const MAX_STEPS: usize = 1000;
        let mut duration = self.frame_duration(Some(self.current_frame)) as f32;
        while self.accumulator >= duration && steps < MAX_STEPS {
            self.accumulator -= duration;
            self.next_frame();
            duration = self.frame_duration(Some(self.current_frame)) as f32;
            steps += 1;
        }
        self.current_frame
    }

    pub fn state(&self) -> TimelineState {
        TimelineState {
            current_frame: self.current_frame,
            playing: self.playing,
            loop_mode: self.loop_mode,
            fps: self.fps,
            active_tag: self.active_tag.clone(),
            onion_skin: self.onion_skin,
            frame_duration: self.frame_duration(Some(self.current_frame)),
        }
    }
}

impl TimelineController<AsepriteDoc> {
    /// Convenience constructor for an owned document.
    pub fn with_document(doc: AsepriteDoc) -> Self {
        Self::new(doc)
    }
}
