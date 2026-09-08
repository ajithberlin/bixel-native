//! Application state, input editing and command dispatch for the Bixel TUI.
//!
//! Kept free of rendering so it can be reasoned about (and tested) headlessly,
//! mirroring the "browser owns pixels / engine owns state" split from the web
//! studio: `App` owns the conversation and the command logic; `render` draws it.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::Instant;

use bixel_ai::image::{self, RgbaImage};
use bixel_ai::{AiError, AiSettings, Engine, StreamEvent};

use crate::commands::{self, CommandSpec};

pub const SYSTEM_PROMPT: &str =
    "You are Bixel, an AI assistant for a 2D pixel-art game studio. Be concise and helpful. \
     When generating art, prefer clean pixel-art with crisp edges and no text or watermarks.";

/// Maximum number of visible lines in the (auto-growing) input box.
pub const MAX_INPUT_LINES: usize = 8;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
    System,
    Error,
    /// A live tool call / result line.
    Tool,
}

pub struct Message {
    pub role: Role,
    pub text: String,
}

impl Message {
    pub fn user(t: impl Into<String>) -> Self {
        Message {
            role: Role::User,
            text: t.into(),
        }
    }
    pub fn assistant(t: impl Into<String>) -> Self {
        Message {
            role: Role::Assistant,
            text: t.into(),
        }
    }
    pub fn system(t: impl Into<String>) -> Self {
        Message {
            role: Role::System,
            text: t.into(),
        }
    }
    pub fn error(t: impl Into<String>) -> Self {
        Message {
            role: Role::Error,
            text: t.into(),
        }
    }
    pub fn tool(t: impl Into<String>) -> Self {
        Message {
            role: Role::Tool,
            text: t.into(),
        }
    }
}

/// Events sent from a worker thread back to the UI loop.
pub enum Event {
    /// A streaming chunk from the assistant.
    Stream(StreamEvent),
    /// The job finished (text result or error string).
    Done(Result<String, String>),
}

/// State for the interactive command palette.
pub struct Palette {
    pub matches: Vec<&'static CommandSpec>,
    pub selected: usize,
}

pub struct App {
    pub messages: Vec<Message>,
    pub input: String,
    pub input_cursor: usize,
    history: Vec<String>,
    history_index: Option<usize>,
    draft: String,
    pub scroll: usize,
    pub running: bool,
    /// A streaming chat is in flight (vs. a one-shot command).
    streaming: bool,
    /// Accumulated text of the in-progress assistant turn.
    stream_buf: String,
    engine: Option<Arc<Engine>>,
    /// Human-readable model name for the status bar.
    pub model: String,
    pub provider: String,
    tx: Sender<Event>,
    rx: Receiver<Event>,
    pub quit: bool,
    pub started: Instant,
    /// Token usage of the most recent turn.
    pub last_usage: Option<(i64, i64)>,
    pub palette: Option<Palette>,
}

impl App {
    pub fn new() -> Self {
        let (tx, rx) = channel::<Event>();
        let (engine, model, provider) = match Engine::new(AiSettings::from_env_file()) {
            Ok(e) => {
                let model = e.settings().text_model.clone();
                (Some(Arc::new(e)), model, "openrouter".to_string())
            }
            Err(e) => {
                let _ = tx.send(Event::Done(Err(format!(
                    "{e} — add OPENROUTER_API_KEY to .env and restart."
                ))));
                (None, "no model".to_string(), "openrouter".to_string())
            }
        };

        App {
            messages: vec![Message::system(
                "Bixel studio — type /help for commands, or just chat.",
            )],
            input: String::new(),
            input_cursor: 0,
            history: Vec::new(),
            history_index: None,
            draft: String::new(),
            scroll: 0,
            running: false,
            streaming: false,
            stream_buf: String::new(),
            engine,
            model,
            provider,
            tx,
            rx,
            quit: false,
            started: Instant::now(),
            last_usage: None,
            palette: None,
        }
    }

    pub fn push(&mut self, m: Message) {
        self.messages.push(m);
    }

    /// The assistant text currently being streamed, if any.
    pub fn live_stream(&self) -> Option<&str> {
        if self.streaming && !self.stream_buf.is_empty() {
            Some(&self.stream_buf)
        } else {
            None
        }
    }

    pub fn is_chat_streaming(&self) -> bool {
        self.streaming
    }

    pub fn session_len(&self) -> usize {
        self.engine.as_ref().map(|e| e.session_len()).unwrap_or(0)
    }

    // -------------------------------------------------------------- input

    pub fn submit(&mut self) {
        let line = self.input.trim().to_string();
        self.input.clear();
        self.input_cursor = 0;
        self.palette = None;
        if line.is_empty() {
            return;
        }
        if self.history.last() != Some(&line) {
            self.history.push(line.clone());
            if self.history.len() > 100 {
                self.history.remove(0);
            }
        }
        self.history_index = None;
        self.draft.clear();
        self.scroll = 0;

        self.push(Message::user(line.clone()));
        if line.starts_with('/') {
            self.dispatch_command(&line);
        } else {
            self.dispatch_chat(&line);
        }
    }

    // ---------------------------------------------------------- dispatch

    fn dispatch_command(&mut self, line: &str) {
        let mut parts = line.split_whitespace();
        let cmd = parts.next().unwrap_or("").to_string();
        let args: String = parts.collect::<Vec<_>>().join(" ");

        let canonical = commands::canonical(&cmd).unwrap_or(&cmd).to_string();

        match canonical.as_str() {
            "/help" => self.push(Message::system(commands::help_text())),
            "/skills" => self.push(Message::system(commands::skills_text())),
            "/clear" => self.clear_conversation(),
            "/quit" | "/exit" | "/q" => self.quit = true,
            "/generate" => {
                if args.is_empty() {
                    self.push(Message::error("usage: /generate <prompt>"));
                    return;
                }
                let prompt = args;
                self.run(move |engine| {
                    let img = engine.generate_image(&prompt, None)?;
                    let path = format!("art_{}.png", counter());
                    write_png(&path, &img)?;
                    Ok(format!("saved {} ({}×{})", path, img.width, img.height))
                });
            }
            "/spritesheet" => {
                let (prompt, cols, rows) = parse_spritesheet(&args);
                if prompt.is_empty() {
                    self.push(Message::error(
                        "usage: /spritesheet <prompt> [--cols N --rows M]",
                    ));
                    return;
                }
                self.run(move |engine| {
                    let sheet = engine.generate_image(&prompt, None)?;
                    let frames = image::slice_grid(&sheet, cols, rows);
                    let mut names = Vec::new();
                    for (i, f) in frames.iter().enumerate() {
                        let path = format!("sheet_{}_f{}.png", counter(), i);
                        write_png(&path, f)?;
                        names.push(path);
                    }
                    Ok(format!(
                        "sheet {}×{} sliced into {} frames: {}",
                        sheet.width,
                        sheet.height,
                        frames.len(),
                        names.join(", ")
                    ))
                });
            }
            "/next" => {
                let (path, prompt) = split_first(&args);
                if path.is_empty() {
                    self.push(Message::error("usage: /next <image.png> [prompt]"));
                    return;
                }
                let prompt = if prompt.is_empty() {
                    "continue the motion".to_string()
                } else {
                    prompt
                };
                self.run(move |engine| {
                    let img = load_image(&path)?;
                    let out = engine.generate_image(&prompt, Some(&img))?;
                    let out_path = format!("next_{}.png", counter());
                    write_png(&out_path, &out)?;
                    Ok(format!("saved {} ({}×{})", out_path, out.width, out.height))
                });
            }
            "/compress" => {
                let (path, bits) = parse_bits(&args);
                if path.is_empty() {
                    self.push(Message::error("usage: /compress <image.png> [--bits N]"));
                    return;
                }
                self.run(move |_| {
                    let img = load_image(&path)?;
                    let out = image::compress_to_bits(&img, bits);
                    let out_path = format!("{}_compressed.png", stem(&path));
                    write_png(&out_path, &out)?;
                    Ok(format!(
                        "saved {} ({}-bit, {} colors)",
                        out_path,
                        bits,
                        1usize << bits
                    ))
                });
            }
            "/remove_bg" => {
                let (path, tol) = parse_tolerance(&args);
                if path.is_empty() {
                    self.push(Message::error("usage: /remove_bg <image.png> [--tol N]"));
                    return;
                }
                self.run(move |_| {
                    let img = load_image(&path)?;
                    let out = image::remove_background(&img, tol);
                    let out_path = format!("{}_nobg.png", stem(&path));
                    write_png(&out_path, &out)?;
                    Ok(format!("saved {}", out_path))
                });
            }
            _ => self.push(Message::error(format!("unknown command {cmd}. try /help"))),
        }
    }

    pub fn clear_conversation(&mut self) {
        self.messages.clear();
        if let Some(e) = &self.engine {
            e.reset_chat();
        }
        self.last_usage = None;
        self.push(Message::system("conversation cleared."));
    }

    fn dispatch_chat(&mut self, prompt: &str) {
        let Some(engine) = self.engine.clone() else {
            self.push(Message::error("no engine configured"));
            return;
        };
        self.running = true;
        self.streaming = true;
        self.stream_buf.clear();
        let prompt = prompt.to_string();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = engine.stream_chat(&prompt, SYSTEM_PROMPT, |ev| {
                let _ = tx.send(Event::Stream(ev));
            });
            let _ = tx.send(Event::Done(result.map_err(|e| e.to_string())));
        });
    }

    /// Run a one-shot (non-streaming) job on a worker thread.
    fn run<F>(&mut self, f: F)
    where
        F: FnOnce(&Engine) -> Result<String, AiError> + Send + 'static,
    {
        let Some(engine) = self.engine.clone() else {
            self.push(Message::error("no engine configured"));
            return;
        };
        self.running = true;
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = f(&engine).map_err(|e| e.to_string());
            let _ = tx.send(Event::Done(result));
        });
    }

    /// Drain worker events and fold them into the conversation.
    pub fn drain(&mut self) {
        loop {
            match self.rx.try_recv() {
                Ok(Event::Stream(ev)) => self.handle_stream(ev),
                Ok(Event::Done(result)) => {
                    self.handle_done(result);
                }
                Err(_) => break,
            }
        }
    }

    fn handle_stream(&mut self, ev: StreamEvent) {
        match ev {
            StreamEvent::Text { delta } => {
                self.stream_buf.push_str(&delta);
            }
            StreamEvent::ToolCall {
                name, arguments, ..
            } => {
                let args = summarize_json(&arguments);
                self.push(Message::tool(format!("▸ {name} {args}")));
            }
            StreamEvent::ToolResult { name, text, .. } => {
                self.push(Message::tool(format!("  ↳ {name}: {text}")));
            }
            StreamEvent::Usage {
                input_tokens,
                output_tokens,
            } => {
                self.last_usage = Some((input_tokens, output_tokens));
            }
        }
    }

    fn handle_done(&mut self, result: Result<String, String>) {
        if self.streaming {
            self.streaming = false;
            let streamed = std::mem::take(&mut self.stream_buf);
            match result {
                Ok(full) => {
                    let text = if streamed.trim().is_empty() {
                        full
                    } else {
                        streamed
                    };
                    if text.trim().is_empty() {
                        self.push(Message::assistant("(no output)"));
                    } else {
                        self.push(Message::assistant(text));
                    }
                }
                Err(e) => {
                    if !streamed.trim().is_empty() {
                        self.push(Message::assistant(streamed));
                    }
                    self.push(Message::error(e));
                }
            }
            self.running = false;
        } else {
            self.running = false;
            match result {
                Ok(text) => self.push(Message::assistant(text)),
                Err(e) => self.push(Message::error(e)),
            }
        }
    }

    // ------------------------------------------------------------ palette

    /// Refresh the palette from the current input (auto-show while typing a
    /// bare `/command` token).
    pub fn refresh_palette(&mut self) {
        let trimmed = self.input.trim_start();
        let show = trimmed.starts_with('/') && !trimmed.contains(' ');
        if show {
            let matches = commands::matches(trimmed);
            if !matches.is_empty() {
                // Preserve selection across refreshes when possible.
                let selected = self
                    .palette
                    .as_ref()
                    .map(|p| p.selected.min(matches.len().saturating_sub(1)))
                    .unwrap_or(0);
                self.palette = Some(Palette { matches, selected });
                return;
            }
        }
        self.palette = None;
    }

    pub fn palette_open(&self) -> bool {
        self.palette.is_some()
    }

    pub fn palette_next(&mut self) {
        if let Some(p) = self.palette.as_mut() {
            if p.selected + 1 < p.matches.len() {
                p.selected += 1;
            }
        }
    }

    pub fn palette_prev(&mut self) {
        if let Some(p) = self.palette.as_mut() {
            p.selected = p.selected.saturating_sub(1);
        }
    }

    /// Accept the highlighted palette entry (insert command name + suffix).
    pub fn palette_accept(&mut self) {
        if let Some(p) = self.palette.take() {
            let spec = p.matches[p.selected.min(p.matches.len() - 1)];
            self.input = commands::completed_input(spec, &self.input);
            self.input_cursor = self.input.len();
        }
    }

    // ------------------------------------------------------- input editing

    fn insert_char(&mut self, c: char) {
        self.input.insert(self.input_cursor, c);
        self.input_cursor += c.len_utf8();
        self.refresh_palette();
    }

    fn backspace(&mut self) {
        if self.input_cursor == 0 {
            return;
        }
        let prev = self.input[..self.input_cursor]
            .chars()
            .next_back()
            .expect("cursor is on a char boundary");
        self.input_cursor -= prev.len_utf8();
        self.input.remove(self.input_cursor);
        self.refresh_palette();
    }

    fn delete(&mut self) {
        if self.input_cursor >= self.input.len() {
            return;
        }
        self.input.remove(self.input_cursor);
        self.refresh_palette();
    }

    fn cursor_left(&mut self) {
        if self.input_cursor == 0 {
            return;
        }
        let prev = self.input[..self.input_cursor]
            .chars()
            .next_back()
            .expect("cursor is on a char boundary");
        self.input_cursor -= prev.len_utf8();
    }

    fn cursor_right(&mut self) {
        if self.input_cursor >= self.input.len() {
            return;
        }
        let next = self.input[self.input_cursor..]
            .chars()
            .next()
            .expect("cursor is on a char boundary");
        self.input_cursor += next.len_utf8();
    }

    fn cursor_home(&mut self) {
        self.input_cursor = 0;
    }

    fn cursor_end(&mut self) {
        self.input_cursor = self.input.len();
    }

    fn delete_word_back(&mut self) {
        let prefix = &self.input[..self.input_cursor];
        let end = prefix.trim_end_matches(char::is_whitespace).len();
        let cut = prefix[..end]
            .rfind(char::is_whitespace)
            .map(|i| i + 1)
            .unwrap_or(0);
        self.input.drain(cut..self.input_cursor);
        self.input_cursor = cut;
        self.refresh_palette();
    }

    fn delete_to_end(&mut self) {
        self.input.truncate(self.input_cursor);
        self.refresh_palette();
    }

    fn clear_input(&mut self) {
        self.input.clear();
        self.input_cursor = 0;
        self.palette = None;
    }

    fn history_up(&mut self) {
        if self.history.is_empty() {
            return;
        }
        match self.history_index {
            None => {
                self.draft = self.input.clone();
                let i = self.history.len() - 1;
                self.history_index = Some(i);
                self.input = self.history[i].clone();
            }
            Some(0) => {}
            Some(i) => {
                self.history_index = Some(i - 1);
                self.input = self.history[i - 1].clone();
            }
        }
        self.input_cursor = self.input.len();
        self.palette = None;
    }

    fn history_down(&mut self) {
        match self.history_index {
            None => {}
            Some(i) if i + 1 < self.history.len() => {
                self.history_index = Some(i + 1);
                self.input = self.history[i + 1].clone();
                self.input_cursor = self.input.len();
            }
            Some(_) => {
                self.history_index = None;
                self.input = std::mem::take(&mut self.draft);
                self.input_cursor = self.input.len();
            }
        }
        self.palette = None;
    }

    /// Insert a multi-line paste verbatim (no command/enter triggering).
    pub fn insert_paste(&mut self, text: &str) {
        for ch in text.chars() {
            self.input.insert(self.input_cursor, ch);
            self.input_cursor += ch.len_utf8();
        }
        self.refresh_palette();
    }
}

// ------------------------------------------------------------ input actions
// (dispatched by the key handler; kept as methods so tests can drive them)

impl App {
    /// Dispatch a single editing action against the current input.
    pub fn apply_edit(&mut self, action: EditAction) {
        match action {
            EditAction::Char(c) => self.insert_char(c),
            EditAction::Backspace => self.backspace(),
            EditAction::Delete => self.delete(),
            EditAction::Left => self.cursor_left(),
            EditAction::Right => self.cursor_right(),
            EditAction::Home => self.cursor_home(),
            EditAction::End => self.cursor_end(),
            EditAction::DeleteWordBack => self.delete_word_back(),
            EditAction::DeleteToEnd => self.delete_to_end(),
            EditAction::Clear => self.clear_input(),
            EditAction::HistoryUp => self.history_up(),
            EditAction::HistoryDown => self.history_down(),
        }
    }
}

#[derive(Clone, Copy)]
pub enum EditAction {
    Char(char),
    Backspace,
    Delete,
    Left,
    Right,
    Home,
    End,
    DeleteWordBack,
    DeleteToEnd,
    Clear,
    HistoryUp,
    HistoryDown,
}

// ------------------------------------------------------------ helpers

fn summarize_json(json: &str) -> String {
    let trimmed = json.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    // Collapse to a single line, capped for display.
    let collapsed: String = trimmed.split_whitespace().collect::<Vec<_>>().join(" ");
    let limit = 80;
    if collapsed.chars().count() > limit {
        let mut cut: String = collapsed.chars().take(limit).collect();
        cut.push('…');
        return cut;
    }
    collapsed
}

fn counter() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static C: AtomicU32 = AtomicU32::new(1);
    C.fetch_add(1, Ordering::Relaxed)
}

fn stem(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".to_string())
}

fn load_image(path: &str) -> Result<RgbaImage, AiError> {
    let bytes = std::fs::read(path).map_err(|e| AiError::Image(e.to_string()))?;
    image::decode_any(&bytes)
}

fn write_png(path: &str, img: &RgbaImage) -> Result<(), AiError> {
    let png = image::encode_png(img)?;
    std::fs::write(path, png).map_err(|e| AiError::Image(e.to_string()))
}

fn split_first(args: &str) -> (String, String) {
    let mut it = args.splitn(2, char::is_whitespace);
    let first = it.next().unwrap_or("").to_string();
    let rest = it.next().unwrap_or("").trim().to_string();
    (first, rest)
}

fn parse_bits(args: &str) -> (String, u8) {
    let mut bits = 4u8;
    let toks: Vec<&str> = args.split_whitespace().collect();
    let mut path = args.to_string();
    if let Some(i) = toks.iter().position(|t| *t == "--bits") {
        if let Some(v) = toks.get(i + 1).and_then(|v| v.parse::<u8>().ok()) {
            bits = v.clamp(1, 8);
        }
        path = toks[..i].join(" ");
    }
    (path, bits)
}

fn parse_tolerance(args: &str) -> (String, f32) {
    let mut tol = 32.0f32;
    let toks: Vec<&str> = args.split_whitespace().collect();
    let mut path = args.to_string();
    if let Some(i) = toks.iter().position(|t| *t == "--tol") {
        if let Some(v) = toks.get(i + 1).and_then(|v| v.parse::<f32>().ok()) {
            tol = v;
        }
        path = toks[..i].join(" ");
    }
    (path, tol)
}

fn parse_spritesheet(args: &str) -> (String, usize, usize) {
    let mut cols = 4usize;
    let mut rows = 1usize;
    let toks: Vec<&str> = args.split_whitespace().collect();
    if let Some(i) = toks.iter().position(|t| *t == "--cols") {
        if let Some(v) = toks.get(i + 1).and_then(|v| v.parse::<usize>().ok()) {
            cols = v.max(1);
        }
    }
    if let Some(i) = toks.iter().position(|t| *t == "--rows") {
        if let Some(v) = toks.get(i + 1).and_then(|v| v.parse::<usize>().ok()) {
            rows = v.max(1);
        }
    }
    let cut = toks
        .iter()
        .position(|t| t.starts_with("--"))
        .unwrap_or(toks.len());
    (toks[..cut].join(" "), cols, rows)
}

// --------------------------------------------------------------- wrapping

/// Word-wrap `text` to `width` columns, breaking long words mid-word.
/// Preserves explicit `\n` line breaks.
pub fn wrap_text(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut lines: Vec<String> = Vec::new();
    for raw in text.split('\n') {
        wrap_line(raw, width, &mut lines);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn wrap_line(text: &str, width: usize, out: &mut Vec<String>) {
    let mut line = String::new();
    for (i, word) in text.split(' ').enumerate() {
        let word_width = word.chars().count();
        if word_width > width {
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
            }
            let mut chunk = String::new();
            for ch in word.chars() {
                if chunk.chars().count() >= width {
                    out.push(std::mem::take(&mut chunk));
                }
                chunk.push(ch);
            }
            line = chunk;
        } else if i == 0 || line.chars().count() + 1 + word_width <= width {
            if i != 0 {
                line.push(' ');
            }
            line.push_str(word);
        } else {
            out.push(std::mem::take(&mut line));
            line.push_str(word);
        }
    }
    out.push(line);
}

/// Byte offset of the cursor maps to a (line, column) pair in wrapped text.
pub fn cursor_position(input: &str, cursor_byte: usize, width: usize) -> (usize, usize) {
    let prefix = &input[..cursor_byte];
    let lines = wrap_text(prefix, width);
    let col = lines.last().map(|l| l.chars().count()).unwrap_or(0);
    (lines.len().saturating_sub(1), col)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_short_line() {
        assert_eq!(wrap_text("hello world", 20), vec!["hello world"]);
    }

    #[test]
    fn wrap_basic() {
        assert_eq!(wrap_text("hello world", 6), vec!["hello", "world"]);
    }

    #[test]
    fn wrap_preserves_newlines() {
        assert_eq!(wrap_text("a\nb", 10), vec!["a", "b"]);
    }

    #[test]
    fn wrap_breaks_long_word() {
        assert_eq!(wrap_text("abcdef", 4), vec!["abcd", "ef"]);
    }

    #[test]
    fn wrap_empty() {
        assert_eq!(wrap_text("", 10), vec![""]);
    }

    #[test]
    fn cursor_at_end() {
        assert_eq!(cursor_position("hello world", 11, 6), (1, 5));
    }

    #[test]
    fn summarize_truncates_long_json() {
        let s = summarize_json(
            "{\"prompt\":\"a very long prompt that goes on and on and on and on and on\"}",
        );
        assert!(s.chars().count() <= 81);
    }
}
