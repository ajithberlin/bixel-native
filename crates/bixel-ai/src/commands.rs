//! Skill slash-commands, delegated to goose.
//!
//! Instead of hand-rolling a skill catalog, this re-exports goose's own
//! slash-command machinery: `list_commands` powers the UI's command picker,
//! `resolve_command` expands an invoked `/skill` into the loaded `SKILL.md`
//! context (exactly how goose runs a skill command), and
//! `installed_skills_markdown` is the catalog goose injects into its system
//! prompt.

use std::path::Path;

use serde::Serialize;

/// A slash command surfaced to the host UI.
#[derive(Debug, Clone, Serialize)]
pub struct AgentCommand {
    pub name: String,
    pub description: String,
    /// `skill` (installed SKILL.md), `recipe`, or `builtin`.
    pub source: &'static str,
    pub input_hint: Option<String>,
}

/// Installed skill commands for `working_dir` (global + project skills),
/// excluding skills the user disabled in Settings.
pub fn list_commands(working_dir: Option<&Path>) -> Vec<AgentCommand> {
    let disabled = crate::settings::disabled_skills();
    goose::slash_commands::skill_slash_command::list_commands(working_dir)
        .into_iter()
        .filter(|command| !disabled.contains(&command.name))
        .map(|command| AgentCommand {
            name: command.name,
            description: command.description,
            source: "skill",
            input_hint: command.input_hint,
        })
        .collect()
}

/// Expand an invoked `/skill` (with optional args) into the loaded skill
/// context, using goose's own resolver. `Ok(None)` means no such skill (or the
/// skill is disabled in Settings).
pub fn resolve_command(
    name: &str,
    args: &str,
    working_dir: Option<&Path>,
) -> Result<Option<String>, String> {
    if crate::settings::is_skill_disabled(name) {
        return Ok(None);
    }
    goose::slash_commands::skill_slash_command::resolve_command(name, args, working_dir)
}

/// goose's markdown catalog of installed skills (used in the system prompt),
/// with disabled skills filtered out.
pub fn installed_skills_markdown(working_dir: Option<&Path>) -> String {
    let disabled = crate::settings::disabled_skills();
    if disabled.is_empty() {
        return goose::slash_commands::skill_slash_command::format_installed_skills(working_dir);
    }
    let sources = goose::skills::list_installed_skills(working_dir);
    let skills: Vec<_> = sources
        .iter()
        .filter(|skill| {
            let is_skill = matches!(
                skill.source_type.to_string().as_str(),
                "skill" | "builtin skill"
            );
            is_skill && !disabled.contains(&skill.name)
        })
        .collect();
    if skills.is_empty() {
        return "No skills installed.\n".to_string();
    }
    let mut output = format!("**Installed skills ({}):**\n\n", skills.len());
    for skill in skills {
        let builtin = skill.source_type.to_string() == "builtin skill";
        let label = if builtin { " *(builtin)*" } else { "" };
        output.push_str(&format!(
            "- **{}**{}: {}\n",
            skill.name, label, skill.description
        ));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_and_resolves_a_project_skill() {
        let tmp = std::env::temp_dir().join(format!("bixel-commands-{}", std::process::id()));
        let skill = tmp.join(".agents/skills/demo-skill");
        std::fs::create_dir_all(&skill).unwrap();
        std::fs::write(
            skill.join("SKILL.md"),
            "---\nname: demo-skill\ndescription: A demo\n---\nDemo body.",
        )
        .unwrap();

        let commands = list_commands(Some(&tmp));
        assert!(
            commands.iter().any(|c| c.name == "demo-skill" && c.source == "skill"),
            "goose should list the project skill: {commands:?}"
        );

        let resolved = resolve_command("demo-skill", "", Some(&tmp)).unwrap();
        assert!(resolved.unwrap_or_default().contains("Demo body."));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
