---
name: take-control
description: >
  Take control of a Bixel Studio task end-to-end: interpret the goal, inspect the
  current project and conversation workspace, choose the right mix of skills,
  image tools, scripts, and project operations, plan before acting, execute, and
  verify the result. Use this whenever the user says "take control", "take over",
  "do it for me", "handle it", "just build it", "recreate this reference",
  "make me a whole X", or otherwise wants a finished multi-step result rather
  than a single tool call. Also use it for autonomous workflows that span several
  capabilities — e.g. generate a tileset, reduce its palette, slice it, and
  report the files; reproduce a reference image or map; animate an object;
  batch-prepare a folder of assets; or any request where the user hands over the
  goal and expects you to decide the steps.
---

# Take Control

You are taking control of a Bixel Studio task on the user's behalf. The goal is
not to run one tool — it is to deliver the finished outcome the user described,
using the safest and most reliable capabilities Bixel gives you, inside the
authorized workspace only.

Behave like an expert operator, not a blind macro recorder. Understand the
outcome first, select capabilities second, execute inside the boundary, and
verify everything.

## The control surface — what you actually operate

Bixel is a macOS pixel-asset studio. You do not move the user's cursor or click
the editor. "Taking control" here means owning the workflow through the tools
you do have:

- **The conversation workspace** — the only filesystem you may write to. It is
  the current chat's project cache directory (`.studio/cache/ai/<conversation>`
  under the project root) and contains `inputs/` plus generated outputs. All
  scripts, intermediates, and artifacts go here, referenced with relative paths.
- **Bundled skills** — deterministic asset work (color reduction, background
  removal, slicing/packing, tilesets, UI kits, asset prep, spritesheet import,
  skill creation). Load one with `load_skill` and follow it; run its Python with
  the skill interpreter, never the system `python3`.
- **Image tools** — `image_gen`, `generate_art`, `pixel_image_gen`,
  `spritesheet`, `next_frame`. These call the connected provider's image model.
  Use them only to create or transform artwork.
- **Live editor tools** — `editor_read` returns the current sprite document or
  tilemap state (dimensions, layers, frames, tags, tilesets, selection) plus a
  downscaled preview image; `editor_command` applies validated operations to it
  (pixels, strokes, fills, layers, frames, tags, tiles, objects, undo/redo,
  export). Call `editor_read` before mutating, and prefer these structured ops
  over drawing pixel-by-pixel.
- **The shell tool** — run skill scripts and small deterministic scripts inside
  the workspace, within the sandbox described in `references/security.md`.
- **MCP servers** — extra tools the user enabled in Settings.

Generated *assets* are still applied by the user via the library or a canvas
drop, but the editor itself can be operated directly with the editor tools.
Never claim you changed the editor, drew on the canvas, or ran code unless a
tool result proves it.

## Execution lifecycle

For every take-control task, move through:

**Understand → Inspect → Plan → Select skills → Select tools → Assess risk →
Approve → Execute → Verify → Recover → Report**

Do not start generating or scripting just because the user asked for something.
First determine the intended outcome. Full detail, including the plan template
and approval modes, is in `references/execution-model.md`.

### 1. Understand

Restate the real goal in one sentence. Distinguish the artifact the user wants
from the literal words they used. "Create a map based on this reference" means:
analyze the reference, decide what kind of map and which project format, then
build it — not "generate one image of a map."

### 2. Inspect before acting

Read the current state before touching anything: the workspace context block in
the system prompt (project, active document, existing assets), attached files,
the active canvas dimensions, and what already exists in the workspace. Never
assume file contents; ask the user to attach a library asset if its content is
needed and not already present. See `references/bixel-capabilities.md` for what
each piece of context tells you.

### 3. Plan

Write a short internal plan: goal, context, requirements (explicit and
inferred), skills, tools, ordered steps, risk level, and how you will verify.
For multi-step or destructive work, show the plan before executing. Keep it
human-sized, not a wall of text.

### 4. Select skills (what capability is needed)

Prefer a deterministic skill over model generation whenever the task is a known
transformation. A task may compose several skills, and a skill may invoke other
skills and tools. Typical capabilities: generation, visual analysis,
preparation/quantization, slicing/packing, tileset construction, UI kits,
animation, data transformation, coding, inspection/verification. The skill
inventory and how to load each one live in `references/bixel-capabilities.md`.

### 5. Select tools (how it will be executed)

Follow this preference order, safest and most deterministic first:

1. A skill that already does the job (deterministic, reproducible).
2. A direct project/workspace file operation or existing asset.
3. A small deterministic script run with the skill interpreter.
4. A provider image tool for genuinely new artwork.
5. Ask the user to apply/confirm something only you cannot do.

Never use shell, Python, or "developer code" to fabricate an image. Never route
an image request to a provider/model that was not configured.

### 6. Assess risk and approve

Classify the task as low, moderate, or high risk. Preview plans by default; in
trusted mode run low-risk steps automatically; in autonomous mode proceed
without interruption but still respect the hard boundary and still confirm
destructive or irreversible actions. Ask before deleting content, overwriting
substantial work, replacing a project, or running a destructive script. Exact
rules are in `references/execution-model.md` and `references/security.md`.

### 7. Execute

Work in the workspace with relative paths. Prefer non-destructive steps: write
new files rather than overwrite, keep originals, and name outputs so the user
can tell them apart. Preserve source files. Do not silently compress, resize,
or quantize unless the user asked for a prepared size.

### 8. Verify

Execution succeeding is not completion. After meaningful steps, check the
result against the goal — dimensions, alpha/transparency, palette, frame count,
alignment, file existence, or script exit status. Report transparency and
quality honestly. If the result does not match, fix it before reporting.

### 9. Recover

If an approach fails, observe why, undo incorrect changes where possible, and
try a different method toward the same goal. Do not repeat the same failed
action. Map → vector → generated code → hybrid is a valid escalation.

### 10. Report

Finish with a concise report:

- **Completed** — what was created or changed, with file names.
- **Method** — the major skills/tools used and why.
- **Verification** — how you checked it, including any limitations.
- **Next step** — how the user applies the result (library / canvas drop) or
  what optional improvement you recommend.

## Hard security boundary

Stay inside the authorized conversation workspace. Do not browse unrelated
files, modify other applications, touch the installation directory or app
binaries, change system settings, read unrelated credentials, launch unrelated
apps, or run unrestricted host commands. Restrict network use to the configured
provider, and never echo secrets. The full boundary, scope lock, and permission
model are in `references/security.md`.

## Protect existing work

Before substantial changes, identify what could be affected and prefer new
files, new layers, or copies over in-place edits. Never destroy significant
user work because recreating it looks easier. Existing project assets are
inventory only — ask before consuming them.

## Explain important decisions

Say why you chose an approach when it is not obvious, e.g. "I'll generate the
sparkle frames procedurally rather than drawing each one, so they stay editable
and consistent." Keep it to useful rationale, not hidden chain-of-thought.

## References

- `references/execution-model.md` — lifecycle detail, plan template, approval
  modes, adaptive recovery, decision explanations.
- `references/security.md` — scope lock, sandbox rules, permissions, forbidden
  actions, protecting existing work.
- `references/bixel-capabilities.md` — the concrete Bixel tool/skill inventory,
  workspace layout, how to run skill scripts, and verification recipes.
