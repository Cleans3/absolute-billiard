# src/debug/

Dev-only debug layer (04 §4, `06 P3` debug requirement). Instanced as `Debug` in
`MainLevel.tscn`, wired to `Table`, `DemoRack` and `Player` by NodePath. `debug_root.gd`
frees the whole subtree in `_ready()` when `OS.is_debug_build()` is false, so none of this
exists, costs anything, or is reachable in a release export.

Gameplay code never references `src/debug` (`grep -r "debug" src/gameplay` is empty). Every
panel only calls public gameplay API — `Table.rebuild()`, `DemoRack.spawn_layout()`,
`Ball.strike()`, `Engine.time_scale` — or toggles built-in `Node` process flags on the
`Player` subtree to hand off control to the free camera; it never edits `src/gameplay`.

## Keys

| Action | Key | Does |
|---|---|---|
| `debug_hud` | F1 | Toggle the stats HUD (fps, physics tick, physics step ms, contact pairs, awake balls, per-ball speed) |
| `debug_freecam` | F2 | Toggle the free-fly camera (WASD + mouse look, Q/E up/down, scroll wheel = fly speed); player input is suppressed while active |
| `debug_gizmos` | F3 | Toggle world-space gizmos: pocket mouths, drop zones, rail inward normals, jaw markers, kitchen line, head/foot/centre spots, plus live ball velocity vectors + trails |
| `debug_spec` | F4 | Toggle the TableSpec panel — a spinbox per numeric `@export`; edits call `Table.rebuild()` and re-spawn the rack |
| `debug_console` | F5 | Toggle the shot console — place the cue ball (x, z), set power/spin/elevation, Fire / Replay |
| `debug_timescale` | F6 | Cycle `Engine.time_scale` through 1.0 → 0.5 → 0.25 → 0.1 → 2.0 → 1.0 |
| `debug_rack_next` | F7 | Cycle rack presets: break → straight-in → cut → stun |

`debug_spec` and `debug_console` set `Input.mouse_mode` to `MOUSE_MODE_VISIBLE` while open so
the panel is clickable; closing both restores `MOUSE_MODE_CAPTURED`.

## Files

- `DebugRoot.tscn` / `debug_root.gd` — root: release guard, input routing, owns every panel.
- `debug_hud.gd` — `DebugHud` (`CanvasLayer`).
- `debug_free_camera.gd` — `DebugFreeCamera` (`Node3D`, owns its own `Camera3D`).
- `debug_gizmos.gd` — `DebugGizmos` (`Node3D`, one `ImmediateMesh`).
- `debug_spec_panel.gd` — `DebugSpecPanel` (`CanvasLayer`).
- `debug_shot_console.gd` — `DebugShotConsole` (`CanvasLayer`).
- `debug_rack_presets.gd` — `DebugRackPresets` (`RefCounted`, pure data).

Every panel builds its own UI procedurally in `_ready()` (no per-panel `.tscn`) — deviates
from the plan's "panels as child scenes" note; flagged to alpha, no functional difference.

## Contract guards (adhoc-wip-table-ball, remove at P3 sync)

Coded against the table-branch contract before it merged. Two guards remain until T3.1:

- `debug_spec_panel.gd` `_apply()` — `table.has_method("rebuild")` / `rack.has_method("spawn_layout")`
  fall back to `rack.spawn()` only on the pre-merge `Table`. Spec edits still change live
  cloth/cushion feel either way (Ball/PhysicsSim read `TableSpec` every physics tick); only
  the baked CSG geometry doesn't regenerate pre-merge.
- `debug_root.gd` `debug_rack_next` — same `spawn_layout` / `spawn()` fallback.

Everything else (HUD, gizmos, shot console) reads live `Ball` instances via
`DemoRack.get_children()` instead of the contract's `PhysicsSim.get_balls()`, so those needed
no guard and work identically before and after the merge.

**Check at sync (T3.1):** the contract notes `PocketSpec.position` may become relative to bed
height instead of absolute post-merge; if so, `debug_gizmos.gd`'s pocket/drop-zone gizmos
will sit at the wrong height until `_geometry()` is updated to add `table.cloth_y()`.
