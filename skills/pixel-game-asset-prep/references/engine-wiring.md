# Engine Wiring — Flame + Bonfire (Flutter)

How to consume this skill's outputs in a Flame/Bonfire game. Tested against
bonfire 3.17.2 / flame 1.37.0. Adapt the concepts for other engines.

## 1. Sprite animations from the repacked sheet + manifest

Manifest gives `cellWidth`, `cellHeight`, `rows` (directions, top→bottom),
`columnGroups` (actions, each with `firstColumn` and `frames`).

```dart
// Frame (group g, direction d, frame f):
// texturePosition = Vector2((g.firstColumn + f) * cellW, d * cellH)
final anim = await SpriteAnimation.load(
  'player.png',
  SpriteAnimationData.sequenced(
    amount: 3,                       // frames in the group
    stepTime: 0.15,                  // idle ~0.35, walk ~0.15, run ~0.12
    textureSize: Vector2(cellW, cellH),
    texturePosition: Vector2(firstCol * cellW, row * cellH),
  ),
);
```

Bonfire `SimpleDirectionAnimation`: supply `idleRight`/`runRight` from the
RIGHT row (Bonfire auto-flips for LEFT) plus explicit `idleDown`/`runDown`,
`idleUp`/`runUp`. Use the WALK group for `run*` params (Bonfire's "run" =
its movement animation).

Player display size ≈ 0.5× cell (e.g. cell 112×186 → size 56×93); collision
hitbox on the bottom ~30% of the body (the feet).

## 2. Loading the map JSON — layout rules that prevent the "void map"

Bonfire resolves tileset images by STRING CONCATENATION and never normalizes
`..`. The only reliable layout:

```
assets/images/tiles/zone.json      <- JSON here
assets/images/tiles/map_zone.png   <- PNG in the SAME dir
# tileset "image" inside JSON: "map_zone.png"  (bare filename)
```

```dart
WorldMapByTiled(WorldMapReader.fromAsset('tiles/zone.json'))
// fromAsset hardcodes the assets/images/ prefix; basePath becomes 'tiles/';
// builder key = 'tiles/' + 'map_zone.png' -> resolves correctly.
```

Violation symptom: game runs, player moves and collides, but the background
is empty darkness (the tile layer silently fails to find the image). If you
see this, check the concatenated path first. In pubspec.yaml, declare
`assets/images/tiles/` explicitly (directory declarations are not recursive
on all Flutter versions).

## 3. Collisions, doors, NPCs, spawns

Do NOT rely on Bonfire's auto-import of `type: 'collision'` objects (version-
dependent). Parse the same JSON yourself with rootBundle + jsonDecode and
build components:

- collision rect → `GameDecoration(position, size)` + `RectangleHitbox(size)`
- door rect → `GameDecoration with Sensor<Player>`; `onContact` → zone switch
  (gate on progression level BEFORE switching; debounce the "locked" toast —
  sensors re-fire every ~100 ms)
- npc point → your NPC component (`SimpleNpc`), interact via `TapGesture.onTap`
  with a range check and/or a joystick action button
- spawn points → plain `Vector2` lookup table

Zone switching: keep zone state in the Flutter widget, rebuild `BonfireWidget`
with a `ValueKey(zone)`, new map + player at the target spawn. Verify: spawn
feet do not overlap any door rect (zone bounce) OR any collision rect
(soft-lock), and door target/spawn names resolve on both sides of every
transition (`make_tiled_json.py` warns about both). NPCs standing behind a
counter will sit inside collision geometry — that is fine; collisions
constrain the player, not NPCs.

## 4. Bonfire 3.x API gotchas (verified against 3.17.2 source)

- `WorldMapReader.fromAsset(...)` (NOT the v2 `TiledReader`).
- `BonfireWidget(playerControllers: [Joystick(...), Keyboard(config:)])` —
  the v2 `joystick:` / `keyboardConfig:` params are gone.
- Action callback: `onJoystickAction(JoystickActionEvent)`; check
  `event.id == 'interact' && event.event == ActionEvent.DOWN`.
- Movement toggle: `setupMovementByJoystick(enabled: false)`; to actually
  STOP a moving player call `stopMove(forceIdle: true)` (`idle()` is a no-op
  on velocity).
- `TapGesture` requires `void onTap()` (not v2's onTapDown).
- `BonfireWidget` creates its own game instance — pass extra world objects
  via its `components:` param instead of subclassing BonfireGame.
- `Sensor<Player>` auto-creates a hitbox covering the decoration's size.
