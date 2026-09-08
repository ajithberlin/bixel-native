# Inspecting AI-Generated Game Images — Pitfalls Checklist

Read this before extracting anything. AI image models produce assets that
*look* game-ready but violate every assumption a game engine makes.

## Spritesheets

1. **Frames are NOT on a fixed pixel grid.** Adjacent frames drift by 5–30 px
   and vary in size (in one real sheet: widths 63–107 px, heights 147–179 px
   within the same row). Never slice with a fixed stride — segment with
   connected components per cell.
2. **Text labels are baked in.** Action headers (IDLE / WALK / RUN / TALK) sit
   above column groups; direction labels (DOWN / LEFT / RIGHT / UP) sit at row
   starts. They pollute projection profiles and connected-component detection.
   Filter them: label bands are much shorter than sprite rows (keep row bands
   ≥ 40% of the tallest band); analyze column groups within the first sprite
   row only.
3. **Background is near-uniform, not uniform.** Sample the median of the four
   corner patches, then threshold on summed RGB distance (~60 works for dark
   gray). Do not hardcode a color value.
4. **Row order is usually DOWN, LEFT, RIGHT, UP** (top→bottom) and action
   groups IDLE, WALK, RUN, TALK (left→right) — but CONFIRM from the labels;
   generators sometimes swap LEFT/RIGHT or omit a direction.
5. **Attached props travel with frames.** Speech-bubble icons on TALK frames,
   motion dust, shadows. They key out fine (same bg) but widen the bounding
   box — that's OK; uniform cells absorb it.
6. **Feet alignment matters.** Repack frames bottom-anchored so the character
   doesn't bob up/down during animation playback.
7. **Frame count per cell may be inconsistent** (e.g. 3 idle but 4 walk).
   Detect per cell and record actual counts in the manifest; don't force it.

## Scene maps (top-down RPG interiors/overworlds)

1. **Coordinate-label borders.** Generators often add a black border with
   column/row numbers — a grid reference that is NOT part of the map. Crop it
   (content = rows/cols where >50% of pixels are non-black). If you skip this,
   every collision coordinate is shifted and the labels render in-game.
2. **Watermarks.** Small "AI-generated" text in a corner. Crop or inpaint;
   check all four corners at high zoom.
3. **The map is a painting, not a tileset.** You cannot re-tile it. Use the
   "single giant tile" trick (one tile = whole image) with an object layer for
   collisions, or render it as a plain background sprite.
4. **Collision geometry must be hand-authored.** Estimate normalized rects
   from the labeled original (walls, counters, shelves, water, fences), then
   convert to pixels of the CROPPED size. Expect ±5% error; put all rects in
   one JSON/config so tuning is a one-file edit.
5. **Solid vs decorative is ambiguous.** Rugs/carpets look raised but are
   walkable; counters behind which NPCs stand are solid. When unsure, make it
   solid — players forgive blocked decor, not walking through furniture.
6. **Entrances need a walkable gap + a door sensor,** and spawn points must
   be placed with clearance: the player's collision box sits at the feet, so a
   spawn whose feet overlap the door rect triggers an instant return trip.
7. **Perspective is "fake top-down"** (3/4 view). Collide with footprints
   (bottom edges of furniture), not with the visible top faces.
