//! Minimal markdown renderer for chat messages.
//!
//! Supports the subset that matters for an assistant TUI: ATX headings, fenced
//! code blocks (with a tinted background), inline code, bold/italic, links,
//! unordered/ordered lists, blockquotes and horizontal rules. Everything else
//! degrades gracefully to plain wrapped text.
//!
//! The renderer is line-oriented: it returns `Vec<Line<'static>>` ready for a
//! `ratatui` `Paragraph`, wrapping to the available width with hanging indents
//! for list items.

use ratatui::{
    style::{Modifier, Style},
    text::{Line, Span},
};

use crate::theme;

/// A character paired with the style to render it in. Flattening styled spans
/// into these lets the wrapper break lines without splitting a `Span` in two
/// different places.
type StyledChar = (char, Style);

/// Render markdown `text` into wrapped, styled lines of at most `width` cells.
pub fn render_markdown(text: &str, width: usize) -> Vec<Line<'static>> {
    render_markdown_with(text, width, theme::text_style())
}

/// Like [`render_markdown`], but with a caller-supplied base style for plain
/// text (used to tint tool/system/error messages without losing formatting).
pub fn render_markdown_with(text: &str, width: usize, base: Style) -> Vec<Line<'static>> {
    let width = width.max(1);
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut in_code = false;
    let mut code_buf: Vec<String> = Vec::new();
    let mut blank_queued = false;

    let mut raw_lines = text.split('\n').peekable();
    while let Some(raw) = raw_lines.next() {
        let trimmed = raw.trim_start();

        if trimmed.starts_with("```") {
            if !in_code {
                in_code = true;
                code_buf.clear();
            } else {
                in_code = false;
                push_code_block(&mut lines, &code_buf, width);
                code_buf.clear();
                blank_queued = false;
            }
            continue;
        }

        if in_code {
            code_buf.push(raw.to_string());
            continue;
        }

        if raw.trim().is_empty() {
            if !lines.is_empty() && !blank_queued {
                lines.push(Line::from(""));
                blank_queued = true;
            }
            continue;
        }
        blank_queued = false;

        if is_horizontal_rule(trimmed) {
            lines.push(Line::from(Span::styled(
                "─".repeat(width),
                theme::faint_style(),
            )));
            continue;
        }

        if let Some((level, rest)) = heading(trimmed) {
            push_wrapped(
                &mut lines,
                parse_inline(rest, theme::heading_style(level)),
                width,
                0,
            );
            continue;
        }

        if let Some(rest) = trimmed.strip_prefix('>').map(str::trim_start) {
            push_quote(&mut lines, rest, width);
            continue;
        }

        if let Some(rest) = list_item(trimmed) {
            push_list_item(&mut lines, rest, width, base);
            continue;
        }

        push_wrapped(&mut lines, parse_inline(raw, base), width, 0);
    }

    if in_code {
        push_code_block(&mut lines, &code_buf, width);
    }

    if lines.is_empty() {
        lines.push(Line::from(""));
    }
    lines
}

// ------------------------------------------------------------------ blocks

fn push_code_block(lines: &mut Vec<Line<'static>>, code: &[String], width: usize) {
    for raw in code {
        let mut content = raw.clone();
        content.truncate_char_boundary(width);
        // Pad to full width so the background tint reads as a solid block.
        let pad = width.saturating_sub(content.chars().count());
        let mut spans = vec![Span::styled(content, theme::code_block_style())];
        if pad > 0 {
            spans.push(Span::styled(" ".repeat(pad), theme::code_block_style()));
        }
        lines.push(Line::from(spans));
    }
}

trait TruncateCharBoundary {
    fn truncate_char_boundary(&mut self, max: usize);
}

impl TruncateCharBoundary for String {
    fn truncate_char_boundary(&mut self, max: usize) {
        if self.chars().count() <= max {
            return;
        }
        if let Some((idx, _)) = self.char_indices().nth(max) {
            self.truncate(idx);
        }
    }
}

fn push_quote(lines: &mut Vec<Line<'static>>, text: &str, width: usize) {
    let bar = Span::styled("▍ ", theme::heading_style(1));
    let body_width = width.saturating_sub(2).max(1);
    let body = parse_inline(text, theme::quote_style());
    let wrapped = wrap_spans(body, body_width);
    for (i, line) in wrapped.into_iter().enumerate() {
        let mut spans = Vec::new();
        if i == 0 {
            spans.push(bar.clone());
        } else {
            spans.push(Span::raw("  "));
        }
        spans.extend(line);
        lines.push(Line::from(spans));
    }
}

fn push_list_item(lines: &mut Vec<Line<'static>>, text: &str, width: usize, base: Style) {
    // "• " is 2 cells; continuation lines hang by the same amount.
    let bullet = Span::styled("• ", theme::assistant_style());
    let body_width = width.saturating_sub(2).max(1);
    let body = parse_inline(text, base);
    let wrapped = wrap_spans(body, body_width);
    for (i, line) in wrapped.into_iter().enumerate() {
        let mut spans = Vec::new();
        if i == 0 {
            spans.push(bullet.clone());
        } else {
            spans.push(Span::raw("  "));
        }
        spans.extend(line);
        lines.push(Line::from(spans));
    }
}

fn push_wrapped(
    lines: &mut Vec<Line<'static>>,
    spans: Vec<Span<'static>>,
    width: usize,
    indent: usize,
) {
    let body_width = width.saturating_sub(indent).max(1);
    let wrapped = wrap_spans(spans, body_width);
    for (i, line) in wrapped.into_iter().enumerate() {
        let mut spans = Vec::new();
        if i > 0 && indent > 0 {
            spans.push(Span::raw(" ".repeat(indent)));
        }
        spans.extend(line);
        lines.push(Line::from(spans));
    }
}

// ------------------------------------------------------------------ blocks
// (block-pattern helpers)

fn heading(line: &str) -> Option<(usize, &str)> {
    for level in (1..=3).rev() {
        let prefix = "#".repeat(level) + " ";
        if let Some(rest) = line.strip_prefix(&prefix) {
            return Some((level, rest.trim()));
        }
    }
    None
}

fn is_horizontal_rule(line: &str) -> bool {
    let t = line.trim();
    !t.is_empty() && t.chars().all(|c| matches!(c, '-' | '*' | '_' | ' ')) && t.len() >= 3
}

/// Detect `- `, `* `, `+ ` bullets and `1. ` / `1)` ordered items.
fn list_item(line: &str) -> Option<&str> {
    if let Some(rest) = line
        .strip_prefix("- ")
        .or_else(|| line.strip_prefix("* "))
        .or_else(|| line.strip_prefix("+ "))
    {
        return Some(rest.trim_start());
    }
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i > 0 && i < bytes.len() {
        let rest = &line[i..];
        if let Some(r) = rest.strip_prefix(". ").or_else(|| rest.strip_prefix(") ")) {
            return Some(r.trim_start());
        }
    }
    None
}

// ------------------------------------------------------------------ inline

/// Parse inline markdown (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`)
/// into styled spans. Toggles are applied on a flat style; nesting is treated
/// leniently (the last toggle wins).
pub fn parse_inline(text: &str, base: Style) -> Vec<Span<'static>> {
    let mut out: Vec<Span<'static>> = Vec::new();
    let mut buf = String::new();
    let mut style = base;
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut i = 0;

    let flush = |out: &mut Vec<Span<'static>>, buf: &mut String, style: Style| {
        if !buf.is_empty() {
            out.push(Span::styled(std::mem::take(buf), style));
        }
    };

    while i < n {
        let c = chars[i];
        match c {
            '`' => {
                flush(&mut out, &mut buf, style);
                i += 1;
                let mut code = String::new();
                while i < n && chars[i] != '`' {
                    code.push(chars[i]);
                    i += 1;
                }
                if i < n {
                    i += 1; // closing backtick
                }
                if !code.is_empty() {
                    out.push(Span::styled(code, theme::inline_code_style()));
                }
            }
            '*' | '_' => {
                let double = i + 1 < n && chars[i + 1] == c;
                flush(&mut out, &mut buf, style);
                if double {
                    style = toggle(style, Modifier::BOLD);
                    i += 2;
                } else {
                    style = toggle(style, Modifier::ITALIC);
                    i += 1;
                }
            }
            '[' => {
                if let Some((label, after)) = take_link(&chars, i, n) {
                    flush(&mut out, &mut buf, style);
                    out.push(Span::styled(label, theme::link_style()));
                    i = after;
                } else {
                    buf.push(c);
                    i += 1;
                }
            }
            _ => {
                buf.push(c);
                i += 1;
            }
        }
    }
    flush(&mut out, &mut buf, style);

    if out.is_empty() {
        out.push(Span::raw(""));
    }
    out
}

/// If `chars[i]` begins a `[label](url)`, return `(label, index_after_')')`.
fn take_link(chars: &[char], start: usize, n: usize) -> Option<(String, usize)> {
    let mut j = start + 1;
    let mut label = String::new();
    while j < n && chars[j] != ']' {
        label.push(chars[j]);
        j += 1;
    }
    if j >= n || label.is_empty() {
        return None;
    }
    if j + 1 >= n || chars[j + 1] != '(' {
        return None;
    }
    let mut k = j + 2;
    while k < n && chars[k] != ')' {
        k += 1;
    }
    if k >= n {
        return None;
    }
    Some((label, k + 1))
}

fn toggle(style: Style, modifier: Modifier) -> Style {
    if style.add_modifier.contains(modifier) {
        style.remove_modifier(modifier)
    } else {
        style.add_modifier(modifier)
    }
}

// ------------------------------------------------------------------ wrapping

/// Flatten styled spans into a per-character style stream.
fn flatten(spans: &[Span<'static>]) -> Vec<StyledChar> {
    let mut out = Vec::new();
    for span in spans {
        for ch in span.content.chars() {
            out.push((ch, span.style));
        }
    }
    out
}

/// Word-wrap a styled character stream to `width` cells, breaking over-long
/// words mid-word (matching the original plain-text wrapper semantics).
fn wrap_spans(spans: Vec<Span<'static>>, width: usize) -> Vec<Vec<Span<'static>>> {
    let chars = flatten(&spans);
    let width = width.max(1);
    let mut lines: Vec<Vec<StyledChar>> = Vec::new();
    let mut line: Vec<StyledChar> = Vec::new();

    let mut i = 0;
    while i < chars.len() {
        let is_space = chars[i].0 == ' ';
        let mut tok: Vec<StyledChar> = Vec::new();
        while i < chars.len() && (chars[i].0 == ' ') == is_space {
            tok.push(chars[i]);
            i += 1;
        }

        if is_space {
            if line.is_empty() {
                continue; // trim leading spaces
            }
            if line.len() + tok.len() <= width {
                line.extend(tok);
                continue;
            }
            lines.push(std::mem::take(&mut line));
            continue;
        }

        if line.len() + tok.len() <= width {
            line.extend(tok);
            continue;
        }

        if !line.is_empty() {
            lines.push(std::mem::take(&mut line));
        }
        // Break the over-long word across lines.
        let mut cur: Vec<StyledChar> = Vec::new();
        for c in tok {
            if cur.len() >= width {
                lines.push(std::mem::take(&mut cur));
            }
            cur.push(c);
        }
        line = cur;
    }

    if !line.is_empty() {
        lines.push(line);
    }
    if lines.is_empty() {
        lines.push(Vec::new());
    }

    lines.into_iter().map(|l| spans_from_chars(&l)).collect()
}

/// Merge adjacent same-styled characters back into spans.
fn spans_from_chars(chars: &[StyledChar]) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut cur = String::new();
    let mut cur_style: Option<Style> = None;
    for (ch, style) in chars {
        match cur_style {
            Some(s) if s == *style => cur.push(*ch),
            _ => {
                if let Some(s) = cur_style.take() {
                    spans.push(Span::styled(std::mem::take(&mut cur), s));
                }
                cur_style = Some(*style);
                cur.push(*ch);
            }
        }
    }
    if let Some(s) = cur_style {
        spans.push(Span::styled(cur, s));
    }
    spans
}

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Modifier;

    fn plain(lines: &[Line<'static>]) -> String {
        lines
            .iter()
            .map(|l| l_spans_text(l))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn l_spans_text(l: &Line<'static>) -> String {
        l.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn renders_plain_text() {
        let lines = render_markdown("hello world", 40);
        assert_eq!(plain(&lines), "hello world");
    }

    #[test]
    fn wraps_long_text() {
        let lines = render_markdown("aaaa bbbb cccc", 9);
        assert_eq!(plain(&lines), "aaaa bbbb\ncccc");
    }

    #[test]
    fn renders_headings_without_hash() {
        let lines = render_markdown("# Title", 40);
        assert_eq!(plain(&lines), "Title");
    }

    #[test]
    fn renders_bold_inline() {
        let lines = render_markdown("a **b** c", 40);
        assert_eq!(plain(&lines), "a b c");
        let bold = lines[0]
            .spans
            .iter()
            .find(|s| s.content == "b")
            .expect("bold span");
        assert!(bold.style.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn renders_inline_code() {
        let lines = render_markdown("run `ls -la` now", 40);
        assert_eq!(plain(&lines), "run ls -la now");
    }

    #[test]
    fn renders_code_block() {
        let lines = render_markdown("```\nfn main() {}\n```", 40);
        assert_eq!(plain(&lines).trim_end(), "fn main() {}");
        // A code line carries a background tint.
        let span = &lines[0].spans[0];
        assert_eq!(span.style.bg, Some(theme::CODE_BG));
    }

    #[test]
    fn renders_unordered_list() {
        let lines = render_markdown("- one\n- two", 40);
        assert_eq!(plain(&lines), "• one\n• two");
    }

    #[test]
    fn renders_ordered_list() {
        let lines = render_markdown("1. first\n2. second", 40);
        assert_eq!(plain(&lines), "• first\n• second");
    }

    #[test]
    fn renders_blockquote() {
        let lines = render_markdown("> quoted", 40);
        assert_eq!(plain(&lines), "▍ quoted");
    }

    #[test]
    fn renders_link_label_only() {
        let lines = render_markdown("see [docs](https://x)", 40);
        assert_eq!(plain(&lines), "see docs");
    }

    #[test]
    fn collapses_blank_lines() {
        let lines = render_markdown("a\n\n\nb", 40);
        assert_eq!(plain(&lines), "a\n\nb");
    }
}
