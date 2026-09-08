# Component Catalog

Contents: conventions · input controls · feedback & display · overlays & modals ·
navigation · layout containers · RPG kit (skill tree, movement, action, inventory,
quest, resources, map)

Planning checklist per asset: component · state · canvas (multiple of 32) · gen
ratio. Canvas sizes below are defaults — any multiple of 32 works, but ALL states
of one component MUST share the identical canvas, and related components (all
buttons, all slots, all nodes) should share one size family.

**Ratio key** — square → `1:1` 1K · wide → `3:2` 1K · very wide (≥4:1) → `16:9` 2K ·
tall → `2:3` 1K.

**State key** — generate ONLY states that logically apply. Abbreviations:
def default · hov hover · prs pressed · sel selected · foc focused · act active ·
dis disabled · lck locked · unl unlocked · cmp completed · err error · wrn warning ·
suc success · emp empty · fil filled · lod loading.

**Scaling key** — 9sl = nine-slice compatible (recommended padding in px) ·
tile = can tile/repeat · none = fixed size.

## Batch planning (cost control)

Generation is BATCH-FIRST: one AI image = one sheet of related items, split by
`split_group.py`. Three patterns (templates in prompt-playbook.md):

- **STATE ROW** — one component x all its states, one row. Default for every
  interactive component.
- **FAMILY GRID** — same-size stateless items in one grid (markers, icon
  buttons, dots, badges, frames).
- **FAMILY SHEET** — same-size family sharing a state set: rows = components,
  columns = states (button families, slot variants, bar types, d-pad
  directions, node types).

Sheet budget: max 5 columns x 4 rows, ONE canvas size per sheet. Suggested
sheet splits per category:

- Input controls: buttons as one FAMILY SHEET (primary/secondary/elevated/
  toggle x states); icon buttons a FAMILY GRID; checkbox+radio+switch one
  sheet; inputs/selects one sheet (text/search/filter x states); slider +
  stepper parts one grid.
- Feedback/display: all bar types one FAMILY SHEET (rows = bar, cols = emp/
  fil/cmp); badges+chips one sheet; indicators+spinners one grid (spinner
  frames = one row per animation).
- Overlays/modals: big panels are same-size batches of 2-4 or singles (the
  one legitimate singles case); close/confirm/cancel buttons ride the button
  sheets.
- Navigation: one FAMILY SHEET (tab variants x states) + one FAMILY GRID
  (icon buttons, arrows, dots).
- Layout containers: same-size batches of 2-4 (cards together, rows/headers
  together, scrollbars together); dividers/overlay tiles one grid.
- Skill tree: ALL node states one FAMILY SHEET (rows = node type, cols =
  state); connectors + junctions one grid. Keeps the 100-level tree
  consistent by construction.
- Movement/action: d-pad directions one FAMILY SHEET; joystick base+thumb one
  row; all action buttons one FAMILY SHEET (rows = action, cols = def/prs/
  cooldown/unavailable).
- Inventory: all slot variants x states one FAMILY SHEET; badges/indicators
  one grid.
- Quest/resources/map: entries+badges one sheet; counters one sheet; markers
  one grid; minimap frame+background one batch of 2.

## Core Input Controls

Default states for buttons: def, hov, prs, dis (+ sel/foc where the design uses
keyboard/gamepad focus). All 9sl, padding 8, unless noted.

| Component | Canvas | Ratio | States / notes |
|---|---|---|---|
| button_primary | 96x32 | wide | def hov prs foc dis |
| button_secondary | 96x32 | wide | def hov prs foc dis — same shape as primary, quieter palette |
| button_icon (icon-only) | 32x32 | square | def hov prs dis — icon centered, 2px inset |
| button_elevated | 96x32 | wide | def hov prs dis — raised face + drop step, keep shadow inside canvas |
| button_toggle | 64x32 | wide | def(off) sel(on) hov dis |
| switch (on/off) | 64x32 | wide | on off (+ dis of each) — track + knob, none/9sl |
| radio | 32x32 | square | def(unselected) sel hov dis — none |
| radio_group | 96x64 | square | def sel dis — ONE component: vertical stack of 2-4 radio rows, empty label areas |
| checkbox | 32x32 | square | def sel hov dis (+ indeterminate if needed) — none |
| select | 128x32 | wide | def hov foc dis — closed face with caret glyph |
| dropdown | 128x32 / open 128x96 | wide/square | def hov open dis — open state = face + empty list area |
| slider_track | 128x32 | wide | def emp fil dis — 9sl pad 4 |
| slider_thumb | 32x32 | square | def hov prs dis — none |
| stepper_increment / stepper_decrement | 32x32 | square | def hov prs dis — plus/minus glyphs are shapes, not font text |
| stepper_container | 96x32 | wide | def foc err dis — empty number-safe center |
| input_text | 128x32 | wide | def(emp) foc fil err wrn suc dis — empty interior, 9sl pad 8 |
| input_search / input_filter | 128x32 | wide | def(emp) foc fil dis — magnifier glyph zone at one end |

## Feedback and Display Components

| Component | Canvas | Ratio | States / notes |
|---|---|---|---|
| bar_xp / bar_level / bar_loading / bar_health / bar_energy / bar_stat | 128x32 | wide | emp fil cmp — health adds wrn(low) err(critical); 9sl pad 4; fill reads as empty frame + separate fill strip (tile) if the engine layers fills |
| meter_streak | 96x32 | wide | emp fil act |
| badge | 32x32 | square | def sel act dis |
| label_container | 96x32 | wide | def dis — empty text-safe interior, 9sl |
| chip | 96x32 | wide | def hov sel dis — 9sl |
| badge_achievement | 64x64 | square | lck unl cmp (+ new) |
| toast | 128x32 | wide | def suc err wrn — 9sl |
| snackbar | 160x32 | wide | def suc err wrn — 9sl |
| tooltip | 96x64 | square | def — tail pointer variant optional, 9sl |
| spinner_loading / loader_circular | 32x32 | square | animation: 4-8 frames, ONE frame per image, `..._lod_1..N` — none |
| indicator_success / indicator_error / indicator_warning | 32x32 | square | def — emblem-only, none |
| indicator_correct_answer / indicator_wrong_answer | 32x32 | square | def prs |
| indicator_new_skill / indicator_xp_reward | 64x32 | wide | def — empty text zone beside emblem |

## Overlays and Modals

Containers are mostly stateless (def only). Interactive children (close/confirm/
cancel) carry their own states.

| Component | Canvas | Ratio | States / notes |
|---|---|---|---|
| dialog_box | 160x96 | wide | def — 9sl pad 8 |
| modal_window | 160x128 | wide | def — title bar zone + empty body, 9sl |
| dialog_confirmation | 160x96 | wide | def — empty message zone + 2 button slots (empty), 9sl |
| panel_settings | 160x128 | wide | def — rows of empty setting slots, 9sl |
| dialogue_npc | 192x96 | wide | def — empty 2-3 line text area, 9sl |
| nameplate_speaker | 96x32 | wide | def — small empty plate, 9sl |
| portrait_frame_dialogue | 64x64 | square | def — empty portrait interior |
| button_dialogue_choice | 160x32 | wide | def hov prs sel dis — 9sl |
| sheet_bottom | 192x96 | wide | def — top grab handle, 9sl |
| panel_quick_menu_mobile | 128x160 | tall | def — empty grid of action slots, 9sl |
| window_popup | 128x96 | wide | def — 9sl |
| banner_achievement / banner_level_up | 192x64 | very wide | def — 9sl |
| panel_milestone | 192x128 | wide | def — celebration frame, empty center, 9sl |
| overlay_pause_menu | 192x128 | wide | def — dim frame + empty menu slot column |
| tile_overlay_dimmed | 32x32 | square | def — tile; semi-dark dither pattern, opaque (no alpha!) |
| button_close | 32x32 | square | def hov prs dis — X glyph, none |
| button_confirm / button_cancel | 96x32 | wide | def hov prs dis — match button_primary family |

## Navigation Components

| Component | Canvas | Ratio | States / notes |
|---|---|---|---|
| tab / tab_bar_segment | 96x32 | wide | def(unselected) hov sel dis — sel connects visually to content area |
| nav_bottom_item | 64x64 | square | def sel dis — icon zone + empty label zone |
| nav_bottom_background | 192x32 | very wide | def — tile or 9sl |
| dot_pagination | 32x32 | square | def(emp) act(fil) — none |
| button_back_icon / button_close_icon / button_home_icon | 32x32 | square | def hov prs dis — none |
| button_previous / button_next | 64x32 | wide | def hov prs dis — chevron glyph |
| button_menu | 32x32 | square | def hov prs dis |
| segment_breadcrumb | 96x32 | wide | def hov dis — separator glyph zone |
| arrow_page_nav | 32x32 | square | def hov prs dis |

## Layout Containers

Mostly def only; 9sl pad 8 unless noted.

| Component | Canvas | Ratio | Notes |
|---|---|---|---|
| card | 128x96 | wide | def hov(sel) — empty header + body zones |
| panel_general | 128x96 | wide | def |
| card_quest | 128x64 | wide | def hov sel cmp |
| card_npc_profile | 96x128 | tall | def — portrait zone + empty info rows |
| row_list | 128x32 | wide | def hov sel dis |
| container_list | 128x96 | wide | def — empty rows area |
| cell_grid | 32x32 | square | def emp fil — none |
| container_grid | 128x128 | square | def — empty cell matrix |
| grid_inventory | 160x128 | wide | def — matrix of empty slot frames |
| grid_kanji | 160x160 | square | def — uniform empty cells (e.g. 5x5 of 32px) |
| grid_skill_tree | 192x128 | wide | def — empty node sockets on a 32px lattice |
| container_scrollable | 128x96 | wide | def — content area + scrollbar gutter |
| scrollbar_track | 32x96 | tall | def dis — 9sl pad 4 |
| scrollbar_thumb | 32x32 | square | def hov prs(drag) dis |
| header_accordion | 128x32 | wide | def hov sel — chevron zone |
| panel_accordion_expanded / panel_accordion_collapsed | 128x96 / 128x32 | wide | def |
| divider | 32x32 | square | def — tile (horizontal + vertical variants) |
| container_section_header | 128x32 | wide | def — empty title zone |

## RPG Kit

### Skill Tree — must serve a 100-level progression tree

Hard consistency rules: every node state shares ONE canvas (64x64); every
connector is 32x32 and snaps to node edge midpoints; connector stroke width is
constant (e.g. 4px) across all variants; ONE style anchor for the whole set.

| Component | Canvas | States |
|---|---|---|
| node_skill_tree | 64x64 | lck unl available sel act cmp mastered dis (+ def = available) |
| highlight_node | 64x64 | def — ring/glow frame that overlays a node |
| connector_horizontal / connector_vertical / connector_curved | 32x32 | lck act cmp (+ def) — curved in 4 rotations or one rotatable variant |
| junction_branch | 32x32 | def act cmp |
| node_level_milestone | 96x96 | lck unl cmp — every-10-level gate, grander frame |

### Movement Controls

| Component | Canvas | States |
|---|---|---|
| joystick_base | 96x96 | def dis |
| joystick_thumb | 64x64 | def prs dis |
| dpad_base | 96x96 | def dis — cross plate with 4 direction zones |
| dpad_up / dpad_down / dpad_left / dpad_right / dpad_diagonal | 96x96 | prs state of one direction (highlight that zone) — keep base identical |
| movement_control_disabled | 96x96 | dis overlay variant of base |

### Action Controls (all 64x64, square; cluster background 128x64)

interact, attack, talk, examine, pick_up, use_item, menu, context_action —
each: def hov prs dis cooldown unavailable. `cluster_action_background`: def, 9sl.
Cooldown = darkened face with radial sweep wedge; unavailable = grayed + no emblem glow.

### Inventory (slots 64x64 unless noted; keep ONE size for all slot variants)

| Component | States |
|---|---|
| slot_inventory | emp fil sel hov lck dis |
| slot_rare / slot_quest_item / slot_equipped | def — frame tier variants (rare=accent trim, quest=glyph corner, equipped=raised) |
| indicator_new_item | def — corner ribbon/glint overlay (32x32) |
| badge_stack_count | def — 32x32 mini plate, empty number zone |
| slot_drag | def — dashed-outline lifted variant |
| slot_drop_target | def — highlighted inset variant |

### Quest System

| Component | Canvas | States |
|---|---|---|
| panel_quest_log | 160x128 | def — 9sl |
| entry_quest | 128x32 | def act cmp failed lck |
| row_quest_objective | 128x32 | def cmp — empty text zone |
| checkbox_objective | 32x32 | def sel |
| marker_quest | 32x32 | def — overworld "!"/"?" emblem (shape, not font) |
| badge_main_quest / badge_side_quest / badge_daily_quest | 32x32 | def — distinct emblem shapes |
| container_reward | 96x32 | def emp fil — 9sl |

### Resources and Currency (counters 96x32, 9sl; frames 32x32)

counter_xp, counter_streak, counter_coin, counter_gem, counter_energy,
counter_learning_point: def — icon zone + empty number zone.
frame_resource_icon: def — empty mini frame.
anim_resource_increase / anim_resource_decrease: 4 frames each, one per image
(`..._1..4`) — sparkle-up / drain-down.

### Map Components

| Component | Canvas | States |
|---|---|---|
| frame_minimap | 128x128 | def — 9sl, empty interior |
| background_minimap | 128x128 | def — flat empty ground tone, no terrain art |
| marker_player / marker_npc / marker_quest / marker_shop / marker_school / marker_locked_area | 32x32 | def — distinct silhouettes |
| arrow_direction | 32x32 | def — one rotatable variant |
| button_map_zoom / button_map_expand | 32x32 | def hov prs dis |

## Rules that apply everywhere

- Containers that normally hold text are EMPTY visual containers with a clean
  text-safe interior (no glyphs, no placeholder scribbles).
- Steppers/spinners that seem to need glyphs: glyphs are drawn SHAPES
  (+, -, chevrons, padlocks, checkmarks), never font characters.
- Animation assets (spinners, loaders, resource +/-) ship as N separate images,
  one frame per image, identical canvas, `name_<state>_<frame>.png`.
- Keep a padding of >= 2px of pure background on every side of every canvas.
