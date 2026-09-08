//! Bixel — a terminal chatbot harness for the pixel-art studio.
//!
//! Talk to the AI with plain text, or drive the skills with slash commands:
//!
//!   /help                 show this help
//!   /skills               list available skills
//!   /generate <prompt>    generate pixel art (saves a PNG)
//!   /spritesheet <prompt> [--cols N --rows M]  generate + slice a sheet
//!   /next <image.png> [prompt]   predict the next animation frame
//!   /compress <image.png> [--bits N]    reduce to 2^N colors
//!   /remove_bg <image.png> [--tol N]    strip the background
//!   /quit                 exit
//!
//! Keys:
//!   Enter send · Tab complete · ↑/↓ history · PgUp/PgDn scroll · Ctrl+C quit

use std::io;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{
        Block, Borders, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState,
    },
    Terminal,
};

use bixel_ai::image::{self, RgbaImage};
use bixel_ai::skills::Skills;
use bixel_ai::{AiError, AiSettings, Engine};

const SYSTEM_PROMPT: &str =
    "You are Bixel, an AI assistant for a 2D pixel-art game studio. Be concise and helpful.";

/// Width (in terminal cells) reserved for the message-role prefix.
const PREFIX_WIDTH: usize = 6;

/// Maximum number of visible lines in the (auto-growing) input box.
const MAX_INPUT_LINES: usize = 6;

const COMMANDS: &[&str] = &[
    "/help",
    "/skills",
    "/generate",
    "/spritesheet",
    "/next",
    "/next_frame",
    "/compress",
    "/remove_bg",
    "/quit",
    "/exit",
    "/q",
];

type TaskResult = Result<String, AiError>;

#[derive(Clone, Copy, PartialEq)]
enum Role {
    User,
    Assistant,
    System,
    Error,
}

struct Message {
    role: Role,
    text: String,
}

impl Message {
    fn user(t: impl Into<String>) -> Self {
        Message { role: Role::User, text: t.into() }
    }
    fn assistant(t: impl Into<String>) -> Self {
        Message { role: Role::Assistant, text: t.into() }
    }
    fn system(t: impl Into<String>) -> Self {
        Message { role: Role::System, text: t.into() }
    }
    fn error(t: impl Into<String>) -> Self {
        Message { role: Role::Error, text: t.into() }
    }

    fn prefix(&self) -> (&'static str, &'static str, Color) {
        match self.role {
            Role::User => ("you   ", "      ", Color::Cyan),
            Role::Assistant => ("bixel ", "      ", Color::Green),
            Role::System => ("·     ", "      ", Color::DarkGray),
            Role::Error => ("!     ", "      ", Color::Red),
        }
    }
}

struct App {
    messages: Vec<Message>,
    input: String,
    input_cursor: usize,
    history: Vec<String>,
    history_index: Option<usize>,
    draft: String,
    scroll: usize,
    running: bool,
    engine: Option<Arc<Engine>>,
    tx: Sender<Message>,
    rx: Receiver<Message>,
    quit: bool,
    started: Instant,
}

impl App {
    fn new() -> Self {
        let (tx, rx) = channel::<Message>();
        let engine = match Engine::new(AiSettings::from_env_file()) {
            Ok(e) => Some(Arc::new(e)),
            Err(e) => {
                let _ = tx.send(Message::error(format!(
                    "{e} — add OPENROUTER_API_KEY to .env and restart."
                )));
                None
            }
        };
        App {
            messages: vec![Message::system("Bixel studio — type /help for commands, or just chat.")],
            input: String::new(),
            input_cursor: 0,
            history: Vec::new(),
            history_index: None,
            draft: String::new(),
            scroll: 0,
            running: false,
            engine,
            tx,
            rx,
            quit: false,
            started: Instant::now(),
        }
    }

    fn push(&mut self, m: Message) {
        self.messages.push(m);
    }

    fn submit(&mut self) {
        let line = self.input.trim().to_string();
        self.input.clear();
        self.input_cursor = 0;
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

    fn dispatch_command(&mut self, line: &str) {
        let mut parts = line.split_whitespace();
        let cmd = parts.next().unwrap_or("").to_string();
        let args: String = parts.collect::<Vec<_>>().join(" ");

        match cmd.as_str() {
            "/help" => self.push(Message::system(help_text())),
            "/skills" => self.push(Message::system(skills_text())),
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
                    self.push(Message::error("usage: /spritesheet <prompt> [--cols N --rows M]"));
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
            "/next" | "/next_frame" => {
                let (path, prompt) = split_first(&args);
                if path.is_empty() {
                    self.push(Message::error("usage: /next <image.png> [prompt]"));
                    return;
                }
                let prompt = if prompt.is_empty() { "continue the motion".to_string() } else { prompt };
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
                    Ok(format!("saved {} ({}-bit, {} colors)", out_path, bits, 1usize << bits))
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

    fn dispatch_chat(&mut self, prompt: &str) {
        let prompt = prompt.to_string();
        self.run(move |engine| engine.chat(&prompt, SYSTEM_PROMPT));
    }

    /// Run a blocking job on a worker thread; push the result as a message.
    fn run<F>(&mut self, f: F)
    where
        F: FnOnce(&Engine) -> TaskResult + Send + 'static,
    {
        let Some(engine) = self.engine.clone() else {
            self.push(Message::error("no engine configured"));
            return;
        };
        self.running = true;
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let msg = match f(&engine) {
                Ok(text) => Message::assistant(text),
                Err(e) => Message::error(e.to_string()),
            };
            let _ = tx.send(msg);
        });
    }

    fn drain(&mut self) {
        loop {
            match self.rx.try_recv() {
                Ok(m) => {
                    self.push(m);
                    self.running = false;
                }
                Err(_) => break,
            }
        }
    }
}

// ------------------------------------------------------------ input editing

impl App {
    fn insert_char(&mut self, c: char) {
        self.input.insert(self.input_cursor, c);
        self.input_cursor += c.len_utf8();
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
    }

    fn delete(&mut self) {
        if self.input_cursor >= self.input.len() {
            return;
        }
        self.input.remove(self.input_cursor);
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
    }

    fn delete_to_end(&mut self) {
        self.input.truncate(self.input_cursor);
    }

    fn clear_input(&mut self) {
        self.input.clear();
        self.input_cursor = 0;
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
    }

    fn tab_complete(&mut self) {
        if let Some(filled) = complete_command(&self.input) {
            self.input = filled;
            self.input_cursor = self.input.len();
        }
    }
}

fn complete_command(input: &str) -> Option<String> {
    let trimmed = input.trim_start();
    if !trimmed.starts_with('/') || trimmed.contains(' ') {
        return None;
    }
    let matches: Vec<&str> = COMMANDS
        .iter()
        .filter(|c| c.starts_with(trimmed))
        .copied()
        .collect();
    if matches.is_empty() {
        return None;
    }
    if matches.len() == 1 {
        return Some(format!("{} ", matches[0]));
    }
    let mut lcp = matches[0].to_string();
    for m in &matches[1..] {
        while !m.starts_with(&lcp) {
            lcp.pop();
        }
        if lcp.is_empty() {
            break;
        }
    }
    if lcp.len() > trimmed.len() {
        Some(lcp)
    } else {
        None
    }
}

// ------------------------------------------------------------ helpers

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
    let cut = toks.iter().position(|t| t.starts_with("--")).unwrap_or(toks.len());
    (toks[..cut].join(" "), cols, rows)
}

fn help_text() -> String {
    [
        "Commands:",
        "  /help                          show this help",
        "  /skills                        list skills",
        "  /generate <prompt>             text → pixel art (saves art_N.png)",
        "  /spritesheet <prompt> [--cols N --rows M]   sheet + slice into frames",
        "  /next <image.png> [prompt]     predict the next animation frame",
        "  /compress <image.png> [--bits N]   reduce to 2^N colors",
        "  /remove_bg <image.png> [--tol N]   strip the background",
        "  /quit                          exit",
        "",
        "Anything else is sent to the chat model.",
    ]
    .join("\n")
}

fn skills_text() -> String {
    let mut out = String::from("Available skills:\n");
    for s in Skills::specs() {
        out.push_str(&format!("  • {} — {}\n", s.name, s.description));
    }
    out.trim_end().to_string()
}

// --------------------------------------------------------------- wrapping

/// Word-wrap `text` to `width` columns, breaking long words mid-word.
/// Preserves explicit `\n` line breaks.
fn wrap_text(text: &str, width: usize) -> Vec<String> {
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
fn cursor_position(input: &str, cursor_byte: usize, width: usize) -> (usize, usize) {
    let prefix = &input[..cursor_byte];
    let lines = wrap_text(prefix, width);
    let col = lines.last().map(|l| l.chars().count()).unwrap_or(0);
    (lines.len().saturating_sub(1), col)
}

// --------------------------------------------------------------- render

fn build_chat_lines(app: &App, text_width: usize) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    for m in &app.messages {
        let (prefix, indent, color) = m.prefix();
        let style = Style::default().fg(color).add_modifier(Modifier::BOLD);
        for (i, seg) in wrap_text(&m.text, text_width).into_iter().enumerate() {
            if i == 0 {
                lines.push(Line::from(vec![
                    Span::styled(prefix.to_string(), style),
                    Span::raw(seg),
                ]));
            } else {
                lines.push(Line::from(Span::raw(format!("{indent}{seg}"))));
            }
        }
    }
    lines
}

fn render_input_lines(
    input: &str,
    cursor: usize,
    width: usize,
    show_cursor: bool,
) -> Vec<Line<'static>> {
    let cursor_style = Style::default().bg(Color::White).fg(Color::Black);
    let lines = wrap_text(input, width);
    let (cur_line, cur_col) = cursor_position(input, cursor, width);
    let mut out: Vec<Line<'static>> = Vec::new();

    for (i, line) in lines.iter().enumerate() {
        if i == cur_line && show_cursor {
            let mut col = 0;
            let mut before = String::new();
            let mut after = String::new();
            for ch in line.chars() {
                if col < cur_col {
                    before.push(ch);
                } else {
                    after.push(ch);
                }
                col += 1;
            }
            let mut spans = Vec::new();
            if !before.is_empty() {
                spans.push(Span::raw(before));
            }
            if after.is_empty() {
                spans.push(Span::styled(" ".to_string(), cursor_style));
            } else {
                let mut it = after.chars();
                let first = it.next().unwrap();
                spans.push(Span::styled(first.to_string(), cursor_style));
                let rest: String = it.collect();
                if !rest.is_empty() {
                    spans.push(Span::raw(rest));
                }
            }
            out.push(Line::from(spans));
        } else {
            out.push(Line::from(Span::raw(line.clone())));
        }
    }

    if out.is_empty() {
        out.push(Line::from(Span::styled(" ".to_string(), cursor_style)));
    }
    out
}

fn render(f: &mut ratatui::Frame, app: &App) {
    let tick = app.started.elapsed().as_millis();
    let show_cursor = (tick / 500) % 2 == 0;
    let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][(tick / 100) as usize % 10];

    let input_inner = f.area().width.saturating_sub(2) as usize;
    let input_lines = wrap_text(&app.input, input_inner);
    let input_h = (input_lines.len().clamp(1, MAX_INPUT_LINES) + 2) as u16;

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(3), Constraint::Length(input_h), Constraint::Length(1)])
        .split(f.area());

    // --- chat (with scrollbar) ---
    let chat_cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(rows[0]);

    let chat_area = chat_cols[0];
    let inner_width = chat_area.width.saturating_sub(2) as usize;
    let text_width = inner_width.saturating_sub(PREFIX_WIDTH).max(4);

    let all_lines = build_chat_lines(app, text_width);
    let visible = chat_area.height.saturating_sub(2) as usize;
    let total = all_lines.len();
    let max_scroll = total.saturating_sub(visible);
    let scroll = app.scroll.min(max_scroll);
    let end = total.saturating_sub(scroll);
    let start = end.saturating_sub(visible);
    let slice = if all_lines.is_empty() {
        &all_lines[..0]
    } else {
        &all_lines[start..end]
    };

    let mut chat_lines: Vec<Line> = slice.to_vec();
    if app.running {
        chat_lines.push(Line::from(Span::styled(
            format!("{spinner} thinking…"),
            Style::default().fg(Color::Yellow),
        )));
    }

    let chat = Paragraph::new(chat_lines)
        .block(Block::default().borders(Borders::ALL).title(" Bixel "));
    f.render_widget(chat, chat_area);

    if total > visible && visible > 0 {
        let mut sb_area = chat_cols[1];
        sb_area.y += 1;
        sb_area.height = sb_area.height.saturating_sub(2);
        let mut sb_state = ScrollbarState::new(total)
            .position(max_scroll - scroll)
            .viewport_content_length(visible);
        let sb = Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .thumb_style(Style::default().fg(Color::Gray));
        f.render_stateful_widget(sb, sb_area, &mut sb_state);
    }

    // --- input ---
    let input_lines = render_input_lines(&app.input, app.input_cursor, input_inner, show_cursor);
    let input = Paragraph::new(input_lines)
        .block(Block::default().borders(Borders::ALL).title(" input "));
    f.render_widget(input, rows[1]);

    // --- hint bar ---
    let hint = Line::from(Span::styled(
        "Enter send  ·  Tab complete  ·  ↑/↓ history  ·  PgUp/PgDn scroll  ·  Ctrl+C quit",
        Style::default().fg(Color::DarkGray),
    ));
    f.render_widget(Paragraph::new(hint), rows[2]);
}

fn main() -> io::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let result = run(&mut terminal);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    result
}

fn run(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>) -> io::Result<()> {
    let mut app = App::new();
    loop {
        terminal.draw(|f| render(f, &app))?;
        app.drain();

        if app.quit {
            return Ok(());
        }

        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press || key.kind == KeyEventKind::Repeat {
                    handle_key(key, &mut app);
                }
            }
        }
    }
}

fn handle_key(key: crossterm::event::KeyEvent, app: &mut App) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Char('c') if ctrl => app.quit = true,
        KeyCode::Char('d') if ctrl => app.quit = true,
        KeyCode::Enter => app.submit(),
        KeyCode::Char('u') if ctrl => app.clear_input(),
        KeyCode::Char('w') if ctrl => app.delete_word_back(),
        KeyCode::Char('k') if ctrl => app.delete_to_end(),
        KeyCode::Char('a') if ctrl => app.cursor_home(),
        KeyCode::Char('e') if ctrl => app.cursor_end(),
        KeyCode::Char(c) => app.insert_char(c),
        KeyCode::Tab => app.tab_complete(),
        KeyCode::Backspace => app.backspace(),
        KeyCode::Delete => app.delete(),
        KeyCode::Left => app.cursor_left(),
        KeyCode::Right => app.cursor_right(),
        KeyCode::Home => app.cursor_home(),
        KeyCode::End => app.cursor_end(),
        KeyCode::Up => app.history_up(),
        KeyCode::Down => app.history_down(),
        KeyCode::PageUp => {
            let visible = 10usize;
            app.scroll = app.scroll.saturating_add(visible);
        }
        KeyCode::PageDown => app.scroll = app.scroll.saturating_sub(10),
        KeyCode::Esc => app.clear_input(),
        _ => {}
    }
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
    fn tab_completes_unique() {
        assert_eq!(complete_command("/gen"), Some("/generate ".to_string()));
    }

    #[test]
    fn tab_ignores_plain_text() {
        assert_eq!(complete_command("hello"), None);
    }
}
