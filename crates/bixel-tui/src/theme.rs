//! Unified dark color theme for the TUI.
//!
//! The palette is a slate/teal scheme in the spirit of the modern terminal
//! assistants (opencode, Claude Code, Hermes): a dim slate canvas with a teal
//! accent for the assistant, cyan for the user, and soft role-colored cues for
//! tool activity and errors.

use ratatui::style::{Color, Modifier, Style};

// ------------------------------------------------------------------ palette

pub const ACCENT: Color = Color::Rgb(94, 234, 212); // teal — brand / assistant
pub const ACCENT_DIM: Color = Color::Rgb(45, 108, 100);
pub const USER: Color = Color::Rgb(103, 232, 249); // cyan — the human
pub const TOOL: Color = Color::Rgb(167, 139, 250); // violet — tool calls
pub const RED: Color = Color::Rgb(248, 113, 113);
pub const YELLOW: Color = Color::Rgb(250, 204, 21);

pub const TEXT: Color = Color::Rgb(226, 232, 240);
pub const MUTED: Color = Color::Rgb(148, 163, 184);
pub const DIM: Color = Color::Rgb(100, 116, 139);
pub const FAINT: Color = Color::Rgb(71, 85, 105);

pub const CODE_BG: Color = Color::Rgb(30, 41, 59);
pub const CODE_FG: Color = Color::Rgb(165, 180, 252);

// --------------------------------------------------------------- semantics

pub fn user_style() -> Style {
    Style::default().fg(USER).add_modifier(Modifier::BOLD)
}

pub fn assistant_style() -> Style {
    Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)
}

pub fn tool_style() -> Style {
    Style::default().fg(TOOL)
}

pub fn error_style() -> Style {
    Style::default().fg(RED).add_modifier(Modifier::BOLD)
}

pub fn dim_style() -> Style {
    Style::default().fg(DIM)
}

pub fn faint_style() -> Style {
    Style::default().fg(FAINT)
}

pub fn muted_style() -> Style {
    Style::default().fg(MUTED)
}

pub fn text_style() -> Style {
    Style::default().fg(TEXT)
}

pub fn heading_style(level: usize) -> Style {
    let color = match level {
        1 => ACCENT,
        2 => ACCENT_DIM,
        _ => USER,
    };
    Style::default().fg(color).add_modifier(Modifier::BOLD)
}

pub fn inline_code_style() -> Style {
    Style::default().fg(CODE_FG).bg(CODE_BG)
}

pub fn code_block_style() -> Style {
    Style::default().fg(CODE_FG).bg(CODE_BG)
}

pub fn link_style() -> Style {
    Style::default().fg(USER).add_modifier(Modifier::UNDERLINED)
}

pub fn quote_style() -> Style {
    Style::default().fg(MUTED).add_modifier(Modifier::ITALIC)
}
