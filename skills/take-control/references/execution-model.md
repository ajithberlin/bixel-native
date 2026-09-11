# Execution model

Detailed companion to the lifecycle in `SKILL.md`. Read this when a task is
multi-step, risky, or ambiguous, or when you need the plan template or approval
rules.

## Why this model

The user hands over a goal and expects a finished result. Jumping straight to a
tool call usually produces the wrong artifact, or an artifact with the right
content but the wrong size, palette, or format. The lifecycle exists to prevent
wasted generations and destructive edits: understand, inspect, plan, then act.

## Planning template

Keep the plan short and concrete. Internally it should contain:

- **Goal** — the final result, in one sentence.
- **Application context** — active project, active document, selected tool,
  canvas size, existing assets that matter.
- **Requirements** — explicit constraints (size, palette, transparency, frame
  count, format) plus inferred ones (established project style, engine export
  format).
- **Skills required** — capabilities such as generation, visual analysis,
  preparation, slicing/packing, tileset construction, animation, coding,
  inspection, verification.
- **Tools required** — the specific mechanisms (a named skill, an image tool, a
  script, a workspace file operation).
- **Execution steps** — ordered actions.
- **Risk level** — low, moderate, or high.
- **Verification strategy** — the concrete check that will prove success.

Show the plan to the user when approval is required or the task is broad. Phrase
it as intent, e.g.:

> I'll: (1) analyze the reference, (2) generate the base sheet, (3) reduce its
> palette, (4) slice and pack frames, (5) verify frame count and transparency,
> (6) report the files. This stays in this chat's workspace.

## Approval modes

- **Preview** — always show the plan and wait for approval before modifying
  anything. This is the safe default for broad or ambiguous requests.
- **Trusted** — low-risk steps run automatically; ask before deleting content,
  overwriting substantial work, replacing an entire project, running a
  potentially destructive script, or making security-sensitive changes.
- **Autonomous** — normal in-workspace tasks proceed without interruption, but
  the hard security boundary still applies and destructive or irreversible
  actions may still need confirmation.

If you are unsure which mode applies, preview. One extra question is cheaper
than a wrong generation or an overwritten asset.

## Asking good questions

Ask one or two focused questions only when a missing choice materially changes
the result and is not already established by the project or conversation:
frame dimensions, direction count, frame count, tile size, background policy,
export format. Always offer a sensible default and explain its purpose. Do not
ask again for choices the user already supplied.

## Skill selection

A skill is a capability, not an implementation. Choose by desired outcome:

- Known deterministic transformation → use the matching bundled skill.
- New artwork from a description or reference → provider image tool, optionally
  preceded/followed by a preparation skill.
- Analysis of a reference (layout, palette, shapes, spatial relationships) →
  visual understanding first, then act on what you found.
- Complex geometry, repetition, or data transforms → a small script.

Skills compose. A single task can chain generation → reduce colors → slice →
pack → verify. Load each skill with `load_skill` and follow its instructions
rather than guessing at its behavior.

## Tool selection hierarchy

1. A bundled skill that already does the job.
2. A direct workspace/project file operation or an existing asset.
3. A small deterministic script run with the skill interpreter.
4. A provider image tool for new artwork.
5. Asking the user to perform the one step only they can (applying an asset to
   the editor).

Prefer deterministic actions over fragile, repetitive ones. If a structured
path exists, use it instead of many manual steps.

## Adaptive problem solving

When an action fails:

1. Observe the result and read the error honestly.
2. Determine why it failed (wrong dimensions, missing dependency, model refusal,
   non-dividing sheet, opaque background, etc.).
3. Undo incorrect changes where possible, or discard the bad intermediate.
4. Select an alternative method toward the same goal.
5. Continue.

Do not repeat an action that already failed unchanged. Escalate through
approaches: native/deterministic → script → model generation → hybrid. If the
goal is genuinely unreachable with the available capabilities, say so plainly
and propose the closest achievable result instead of pretending.

## Explain important decisions

When you pick one approach over another, give the reason briefly — especially
for non-obvious tradeoffs like procedural vs. manual, or regenerate vs. repair.
This keeps the user in control without exposing hidden chain-of-thought.

## Completion criteria

A task is complete only when the requested outcome exists, the result has been
verified, no blocking error remains, and temporary state is cleaned up. Then
deliver the report described in `SKILL.md`.
