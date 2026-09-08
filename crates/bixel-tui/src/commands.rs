//! Slash-command registry: a single source of truth for the commands the TUI
//! understands, driving `/help`, tab-completion and the interactive command
//! palette (the popup menu shown while typing `/`).

use bixel_ai::skills::Skills;

/// Metadata for one slash command.
#[derive(Debug, Clone)]
pub struct CommandSpec {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub description: &'static str,
    pub usage: &'static str,
    /// The trailing text inserted after the command name when picked from the
    /// palette (a leading space separates it from the name).
    pub insert: &'static str,
}

impl CommandSpec {
    fn new(
        name: &'static str,
        aliases: &'static [&'static str],
        description: &'static str,
        usage: &'static str,
    ) -> Self {
        CommandSpec {
            name,
            aliases,
            description,
            usage,
            insert: "",
        }
    }

    fn with_insert(mut self, insert: &'static str) -> Self {
        self.insert = insert;
        self
    }

    fn matches(&self, token: &str) -> bool {
        let token = token.trim_start_matches('/');
        if token.is_empty() {
            return true;
        }
        self.name.trim_start_matches('/').starts_with(token)
            || self
                .aliases
                .iter()
                .any(|a| a.trim_start_matches('/').starts_with(token))
    }
}

/// All commands, in the order they appear in the palette and `/help`.
pub fn all() -> &'static [CommandSpec] {
    static SPECS: std::sync::OnceLock<Vec<CommandSpec>> = std::sync::OnceLock::new();
    SPECS.get_or_init(|| {
        vec![
            CommandSpec::new(
                "/generate",
                &[],
                "Generate pixel art from a text prompt",
                "/generate <prompt>",
            )
            .with_insert(" "),
            CommandSpec::new(
                "/spritesheet",
                &[],
                "Generate a sprite sheet and slice it into frames",
                "/spritesheet <prompt> [--cols N --rows M]",
            )
            .with_insert(" "),
            CommandSpec::new(
                "/next",
                &["/next_frame"],
                "Predict the next animation frame from an image",
                "/next <image.png> [prompt]",
            )
            .with_insert(" "),
            CommandSpec::new(
                "/compress",
                &[],
                "Reduce an image to 2^N colors",
                "/compress <image.png> [--bits N]",
            )
            .with_insert(" "),
            CommandSpec::new(
                "/remove_bg",
                &[],
                "Strip a near-uniform background",
                "/remove_bg <image.png> [--tol N]",
            )
            .with_insert(" "),
            CommandSpec::new(
                "/skills",
                &[],
                "List the available pixel-art skills",
                "/skills",
            ),
            CommandSpec::new(
                "/clear",
                &[],
                "Clear the conversation and start fresh",
                "/clear",
            ),
            CommandSpec::new("/help", &[], "Show this help", "/help"),
            CommandSpec::new("/quit", &["/exit", "/q"], "Exit Bixel", "/quit"),
        ]
    })
}

/// The command token currently being typed (the text up to the first space).
pub fn current_token(input: &str) -> &str {
    input.split_whitespace().next().unwrap_or("")
}

/// Commands matching the input's leading token, for the palette.
pub fn matches(input: &str) -> Vec<&'static CommandSpec> {
    let token = current_token(input);
    all().iter().filter(|c| c.matches(token)).collect()
}

/// Resolve a full command line (e.g. `/next_frame`) to its canonical name.
pub fn canonical(cmd: &str) -> Option<&'static str> {
    all()
        .iter()
        .find(|c| c.name == cmd || c.aliases.contains(&cmd))
        .map(|c| c.name)
}

/// The command name to insert when the user picks from the palette.
pub fn completed_input(spec: &CommandSpec, input: &str) -> String {
    let token = current_token(input);
    let rest = input.strip_prefix(token).unwrap_or("");
    format!("{}{}{}", spec.name, spec.insert, rest)
}

/// Formatted `/help` block.
pub fn help_text() -> String {
    let mut out = String::new();
    out.push_str("Bixel commands:\n");
    for c in all() {
        let aliases = if c.aliases.is_empty() {
            String::new()
        } else {
            format!("  (alias: {})", c.aliases.join(", "))
        };
        out.push_str(&format!(
            "  {:<14} {}  {}{}\n",
            c.usage, c.description, "", aliases
        ));
    }
    out.push_str("\nAnything else is sent to the chat model.");
    out.push_str("\nKeys: Enter send · Tab menu · Shift+Tab menu · ↑/↓ history · Ctrl+C quit");
    out
}

/// Formatted `/skills` block, grouped by category.
pub fn skills_text() -> String {
    let mut out = String::from("Available skills:\n");
    let specs = Skills::specs();
    let mut last_category = "";
    for s in &specs {
        if s.category != last_category {
            last_category = s.category;
            out.push_str(&format!("\n  {}:\n", title_case(last_category)));
        }
        let role = match s.model {
            bixel_ai::skills::ModelRole::None => "local",
            bixel_ai::skills::ModelRole::Text => "text",
            bixel_ai::skills::ModelRole::Vision => "vision",
            bixel_ai::skills::ModelRole::Image => "image",
        };
        out.push_str(&format!(
            "    {:<28} {:<8} {}\n",
            s.name, role, s.description
        ));
    }
    out.trim_end().to_string()
}

fn title_case(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_extraction() {
        assert_eq!(current_token("/generate a cat"), "/generate");
        assert_eq!(current_token("/"), "/");
        assert_eq!(current_token("hello"), "hello");
    }

    #[test]
    fn slash_matches_everything() {
        assert!(matches("/").len() >= 5);
    }

    #[test]
    fn prefix_filters_commands() {
        let m = matches("/gen");
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].name, "/generate");
    }

    #[test]
    fn aliases_resolve_to_canonical() {
        assert_eq!(canonical("/next_frame"), Some("/next"));
        assert_eq!(canonical("/q"), Some("/quit"));
        assert_eq!(canonical("/nope"), None);
    }

    #[test]
    fn palette_pick_completes_input() {
        let spec = all().iter().find(|c| c.name == "/generate").unwrap();
        assert_eq!(completed_input(spec, "/gen"), "/generate ");
        assert_eq!(completed_input(spec, "/generate"), "/generate ");
    }
}
