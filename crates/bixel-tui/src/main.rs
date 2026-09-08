//! Bixel — a terminal chatbot harness for the pixel-art studio.
//!
//! Talk to the AI with plain text (streamed token-by-token), or drive the
//! skills with slash commands. Type `/` to open the command palette.
//!
//! Keys:
//!   Enter send · Tab accept/complete · ↑/↓ history or palette nav
//!   PgUp/PgDn scroll · Ctrl+L clear · Ctrl+C quit

mod app;
mod commands;
mod markdown;
mod render;
mod theme;

use std::io;
use std::time::Duration;

use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{backend::CrosstermBackend, Terminal};

use app::App;

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
        terminal.draw(|f| render::render(f, &app))?;
        app.drain();

        if app.quit {
            return Ok(());
        }

        if event::poll(Duration::from_millis(50))? {
            match event::read()? {
                Event::Key(key) => {
                    if key.kind == KeyEventKind::Press || key.kind == KeyEventKind::Repeat {
                        handle_key(key, &mut app);
                    }
                }
                Event::Paste(text) => app.insert_paste(&text),
                Event::Resize(..) | Event::FocusGained | Event::FocusLost => {}
                _ => {}
            }
        }
    }
}

fn handle_key(key: crossterm::event::KeyEvent, app: &mut App) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);

    match key.code {
        KeyCode::Char('c') if ctrl => app.quit = true,
        KeyCode::Char('d') if ctrl => app.quit = true,
        KeyCode::Char('l') if ctrl => app.clear_conversation(),

        KeyCode::Enter => {
            if app.palette_open() {
                app.palette_accept();
            } else {
                app.submit();
            }
        }
        KeyCode::Tab => {
            if app.palette_open() {
                app.palette_accept();
            } else {
                app.refresh_palette();
            }
        }
        KeyCode::BackTab => app.refresh_palette(),

        KeyCode::Up => {
            if app.palette_open() {
                app.palette_prev();
            } else {
                app.apply_edit(app::EditAction::HistoryUp);
            }
        }
        KeyCode::Down => {
            if app.palette_open() {
                app.palette_next();
            } else {
                app.apply_edit(app::EditAction::HistoryDown);
            }
        }

        KeyCode::Esc => {
            if app.palette_open() {
                app.refresh_palette();
            } else {
                app.apply_edit(app::EditAction::Clear);
            }
        }

        KeyCode::Char('u') if ctrl => app.apply_edit(app::EditAction::Clear),
        KeyCode::Char('w') if ctrl => app.apply_edit(app::EditAction::DeleteWordBack),
        KeyCode::Char('k') if ctrl => app.apply_edit(app::EditAction::DeleteToEnd),
        KeyCode::Char('a') if ctrl => app.apply_edit(app::EditAction::Home),
        KeyCode::Char('e') if ctrl => app.apply_edit(app::EditAction::End),

        KeyCode::Char(c) => app.apply_edit(app::EditAction::Char(c)),
        KeyCode::Backspace => app.apply_edit(app::EditAction::Backspace),
        KeyCode::Delete => app.apply_edit(app::EditAction::Delete),
        KeyCode::Left => app.apply_edit(app::EditAction::Left),
        KeyCode::Right => app.apply_edit(app::EditAction::Right),
        KeyCode::Home => app.apply_edit(app::EditAction::Home),
        KeyCode::End => app.apply_edit(app::EditAction::End),

        KeyCode::PageUp => {
            app.scroll = app.scroll.saturating_add(10);
        }
        KeyCode::PageDown => {
            app.scroll = app.scroll.saturating_sub(10);
        }

        _ => {}
    }
}
