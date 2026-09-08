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

use std::io;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::Duration;

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
    widgets::{Block, Borders, Paragraph},
    Terminal,
};

use bixel_ai::image::{self, RgbaImage};
use bixel_ai::skills::Skills;
use bixel_ai::{AiError, AiSettings, Engine};

const SYSTEM_PROMPT: &str =
    "You are Bixel, an AI assistant for a 2D pixel-art game studio. Be concise and helpful.";

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
}

struct App {
    messages: Vec<Message>,
    input: String,
    running: bool,
    engine: Option<Arc<Engine>>,
    tx: Sender<Message>,
    rx: Receiver<Message>,
    quit: bool,
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
            running: false,
            engine,
            tx,
            rx,
            quit: false,
        }
    }

    fn push(&mut self, m: Message) {
        self.messages.push(m);
    }

    fn submit(&mut self) {
        let line = self.input.trim().to_string();
        self.input.clear();
        if line.is_empty() {
            return;
        }
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
        self.run(move |engine| engine.complete_text(&prompt, SYSTEM_PROMPT));
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

// --------------------------------------------------------------- render

fn render(f: &mut ratatui::Frame, app: &App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(3), Constraint::Length(3)].as_ref())
        .split(f.area());

    let mut lines: Vec<Line> = Vec::new();
    for m in &app.messages {
        let (prefix, color) = match m.role {
            Role::User => ("you", Color::Cyan),
            Role::Assistant => ("bixel", Color::Green),
            Role::System => ("·", Color::DarkGray),
            Role::Error => ("!", Color::Red),
        };
        for (i, seg) in m.text.split('\n').enumerate() {
            if i == 0 {
                lines.push(Line::from(vec![
                    Span::styled(format!("{prefix}  "), Style::default().fg(color).add_modifier(Modifier::BOLD)),
                    Span::raw(seg),
                ]));
            } else {
                lines.push(Line::from(Span::raw(format!("       {seg}"))));
            }
        }
    }
    if app.running {
        lines.push(Line::from(Span::styled("… thinking", Style::default().fg(Color::Yellow))));
    }

    let chat = Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title(" Bixel "));
    f.render_widget(chat, chunks[0]);

    let input = Paragraph::new(app.input.as_str())
        .block(Block::default().borders(Borders::ALL).title(" > "));
    f.render_widget(input, chunks[1]);
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
                if key.kind == KeyEventKind::Press {
                    handle_key(key, &mut app);
                }
            }
        }
    }
}

fn handle_key(key: crossterm::event::KeyEvent, app: &mut App) {
    match key.code {
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => app.quit = true,
        KeyCode::Enter => app.submit(),
        KeyCode::Char(c) => app.input.push(c),
        KeyCode::Backspace => {
            app.input.pop();
        }
        KeyCode::Esc => app.input.clear(),
        _ => {}
    }
}
