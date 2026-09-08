//! Frame rendering for the Bixel TUI.
//!
//! Draws a top status bar (model / provider / tokens / timer), the scrolling
//! conversation (with markdown + a scrollbar), the input box, a hint bar and,
//! when active, the floating command palette.

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Style},
    text::{Line, Span},
    widgets::{
        Block, Borders, Clear, List, ListItem, ListState, Paragraph, Scrollbar,
        ScrollbarOrientation, ScrollbarState, Wrap,
    },
    Frame,
};

use crate::app::{App, Message, Role, MAX_INPUT_LINES};
use crate::markdown;
use crate::theme;

/// Width (in terminal cells) reserved for a message's role gutter.
const GUTTER: usize = 2;

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

pub fn render(f: &mut Frame, app: &App) {
    let area = f.area();
    let tick = app.started.elapsed().as_millis();
    let spinner = SPINNER[(tick / 100) as usize % SPINNER.len()];

    let input_inner = area.width.saturating_sub(2) as usize;
    let input_lines = crate::app::wrap_text(&app.input, input_inner);
    let input_h = (input_lines.len().clamp(1, MAX_INPUT_LINES) + 2) as u16;

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(3),
            Constraint::Length(input_h),
            Constraint::Length(1),
        ])
        .split(area);

    render_status_bar(f, app, rows[0], spinner);
    let chat_rect = render_chat(f, app, rows[1], spinner);
    render_input(f, app, rows[2]);
    render_hint(f, app, rows[3]);
    render_palette(f, app, chat_rect);
}

// ------------------------------------------------------------- status bar

fn render_status_bar(f: &mut Frame, app: &App, area: Rect, spinner: &str) {
    let width = area.width as usize;
    let bar = |s: Style| s.bg(theme::CODE_BG);

    let mut spans: Vec<Span<'static>> = Vec::new();
    spans.push(Span::styled("●", bar(theme::assistant_style())));
    spans.push(Span::styled(" bixel", bar(theme::assistant_style())));
    spans.push(Span::styled("   ", bar(theme::faint_style())));
    spans.push(Span::styled(
        app.provider.clone(),
        bar(theme::muted_style()),
    ));
    spans.push(Span::styled(" · ", bar(theme::faint_style())));
    spans.push(Span::styled(app.model.clone(), bar(theme::muted_style())));
    let left_w: usize = spans.iter().map(|s| s.content.chars().count()).sum();

    let mut right_spans: Vec<Span<'static>> = Vec::new();
    if app.running {
        right_spans.push(Span::styled(
            format!("{spinner} "),
            bar(Style::default().fg(theme::YELLOW)),
        ));
    }
    if let Some((i, o)) = app.last_usage {
        right_spans.push(Span::styled(
            format!("↑{i} ↓{o}  "),
            bar(theme::faint_style()),
        ));
    }
    let msgs = app.session_len();
    if msgs > 0 {
        right_spans.push(Span::styled(
            format!("{msgs} msgs  "),
            bar(theme::faint_style()),
        ));
    }
    right_spans.push(Span::styled(
        format_elapsed(app.started.elapsed().as_secs()),
        bar(theme::faint_style()),
    ));
    let right_w: usize = right_spans.iter().map(|s| s.content.chars().count()).sum();

    let gap = width.saturating_sub(left_w + right_w);
    spans.push(Span::styled(" ".repeat(gap), bar(theme::faint_style())));
    spans.extend(right_spans);

    let used = left_w + gap + right_w;
    if width > used {
        spans.push(Span::styled(
            " ".repeat(width - used),
            bar(theme::faint_style()),
        ));
    }

    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn format_elapsed(secs: u64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else if m > 0 {
        format!("{m}:{s:02}")
    } else {
        format!("{s}s")
    }
}

// ------------------------------------------------------------------- chat

fn render_chat(f: &mut Frame, app: &App, area: Rect, spinner: &str) -> Rect {
    let chat_cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(0), Constraint::Length(1)])
        .split(area);
    let chat_area = chat_cols[0];
    let inner_width = chat_area.width.saturating_sub(2) as usize;
    let text_width = inner_width.max(4);

    let mut all_lines: Vec<Line<'static>> = Vec::new();
    for m in &app.messages {
        all_lines.extend(message_lines(m, text_width));
    }
    // Live streaming tail (an assistant turn being typed out).
    if let Some(live) = app.live_stream() {
        all_lines.extend(markdown::render_markdown(live, text_width));
    }

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
    if app.running && !app.is_chat_streaming() {
        chat_lines.push(Line::from(Span::styled(
            format!("{spinner} working…"),
            Style::default().fg(theme::YELLOW),
        )));
    }

    let chat = Paragraph::new(chat_lines).wrap(Wrap { trim: false }).block(
        Block::default()
            .borders(Borders::ALL)
            .border_style(theme::faint_style())
            .title(" Bixel "),
    );
    f.render_widget(chat, chat_area);

    if total > visible && visible > 0 {
        let mut sb_area = chat_cols[1];
        sb_area.y += 1;
        sb_area.height = sb_area.height.saturating_sub(2);
        let mut sb_state = ScrollbarState::new(total)
            .position(max_scroll - scroll)
            .viewport_content_length(visible);
        let sb = Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .thumb_style(Style::default().fg(theme::DIM))
            .track_style(Style::default().fg(theme::FAINT));
        f.render_stateful_widget(sb, sb_area, &mut sb_state);
    }

    area
}

fn message_lines(msg: &Message, width: usize) -> Vec<Line<'static>> {
    match msg.role {
        Role::Assistant => markdown::render_markdown(&msg.text, width),
        Role::Tool => markdown::render_markdown_with(&msg.text, width, theme::tool_style()),
        Role::User => {
            let body = markdown::render_markdown_with(
                &msg.text,
                width.saturating_sub(GUTTER),
                theme::text_style(),
            );
            prefix_lines(body, "❯ ", theme::user_style())
        }
        Role::System => {
            let body = markdown::render_markdown_with(
                &msg.text,
                width.saturating_sub(GUTTER),
                theme::dim_style(),
            );
            prefix_lines(body, "· ", theme::dim_style())
        }
        Role::Error => {
            let body = markdown::render_markdown_with(
                &msg.text,
                width.saturating_sub(GUTTER),
                theme::error_style(),
            );
            prefix_lines(body, "✖ ", theme::error_style())
        }
    }
}

/// Prepend a glyph to the first line and indent continuation lines.
fn prefix_lines(lines: Vec<Line<'static>>, glyph: &str, style: Style) -> Vec<Line<'static>> {
    let glyph_w = glyph.chars().count();
    lines
        .into_iter()
        .enumerate()
        .map(|(i, line)| {
            let mut spans = Vec::new();
            if i == 0 {
                spans.push(Span::styled(glyph.to_string(), style));
            } else {
                spans.push(Span::raw(" ".repeat(glyph_w)));
            }
            spans.extend(line.spans);
            Line::from(spans)
        })
        .collect()
}

// ------------------------------------------------------------------ input

fn render_input(f: &mut Frame, app: &App, area: Rect) {
    let width = area.width.saturating_sub(2) as usize;
    let show_cursor = (app.started.elapsed().as_millis() / 500) % 2 == 0;
    let cursor_style = Style::default().bg(Color::White).fg(Color::Black);
    let lines = crate::app::wrap_text(&app.input, width);
    let (cur_line, cur_col) = crate::app::cursor_position(&app.input, app.input_cursor, width);

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

    let title = if app.palette_open() {
        " input · tab to accept "
    } else {
        " input "
    };
    let input = Paragraph::new(out).block(
        Block::default()
            .borders(Borders::ALL)
            .border_style(if app.palette_open() {
                Style::default().fg(theme::ACCENT_DIM)
            } else {
                theme::faint_style()
            })
            .title(title),
    );
    f.render_widget(input, area);
}

fn render_hint(f: &mut Frame, app: &App, area: Rect) {
    let mut spans = vec![
        Span::styled("Enter", theme::muted_style()),
        Span::styled(" send", theme::faint_style()),
        Span::styled("  ·  ", theme::faint_style()),
        Span::styled("Tab", theme::muted_style()),
        Span::styled(" menu", theme::faint_style()),
        Span::styled("  ·  ", theme::faint_style()),
        Span::styled("↑↓", theme::muted_style()),
        Span::styled(" history", theme::faint_style()),
        Span::styled("  ·  ", theme::faint_style()),
        Span::styled("Ctrl+L", theme::muted_style()),
        Span::styled(" clear", theme::faint_style()),
        Span::styled("  ·  ", theme::faint_style()),
        Span::styled("Ctrl+C", theme::muted_style()),
        Span::styled(" quit", theme::faint_style()),
    ];
    if app.running {
        spans.insert(0, Span::styled("busy", theme::assistant_style()));
        spans.insert(1, Span::styled("  ·  ", theme::faint_style()));
    }
    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

// ----------------------------------------------------------------- palette

fn render_palette(f: &mut Frame, app: &App, chat_area: Rect) {
    let Some(p) = &app.palette else { return };

    let title_width = 14usize;
    let max_desc = 48usize;
    let box_width = (title_width + 2 + max_desc + 2)
        .min(chat_area.width.saturating_sub(2) as usize)
        .max(20);
    let rows = p.matches.len().clamp(1, 9);
    let height = (rows + 2) as u16;

    // Anchor above the input box, pinned to the left of the chat area.
    let y = chat_area
        .y
        .saturating_add(chat_area.height.saturating_sub(height));
    let area = Rect {
        x: chat_area.x.saturating_add(1),
        y,
        width: box_width as u16,
        height,
    };

    f.render_widget(Clear, area);

    let desc_w = box_width.saturating_sub(title_width + 2).max(1);
    let items: Vec<ListItem> = p
        .matches
        .iter()
        .map(|c| {
            let name = format!("{:<width$}", c.name, width = title_width);
            let desc = truncate(c.description, desc_w);
            ListItem::new(Line::from(vec![
                Span::styled(name, theme::assistant_style()),
                Span::raw("  "),
                Span::styled(desc, theme::dim_style()),
            ]))
        })
        .collect();

    let mut state = ListState::default();
    state.select(Some(p.selected));

    let list = List::new(items)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(theme::ACCENT_DIM)
                .title(" commands "),
        )
        .highlight_style(Style::default().bg(theme::ACCENT_DIM).fg(theme::TEXT))
        .highlight_symbol("❯ ");

    f.render_stateful_widget(list, area, &mut state);
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut cut: String = s.chars().take(max.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    #[test]
    fn renders_conversation_without_panicking() {
        let mut app = App::new();
        app.push(Message::user("hello world"));
        app.push(Message::assistant(
            "# Title\n\nSome **bold** and `code` and a [link](https://x).",
        ));
        app.push(Message::tool("▸ generate_art {\"prompt\":\"cat\"}"));
        app.push(Message::error("something failed"));
        app.input = "/gen".to_string();
        app.refresh_palette();

        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, &app)).unwrap();
    }

    #[test]
    fn renders_empty_state_without_panicking() {
        let app = App::new();
        let backend = TestBackend::new(40, 12);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, &app)).unwrap();
    }
}
