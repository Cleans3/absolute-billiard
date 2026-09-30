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
| `debug_netgraph` | F8 | Toggle the net readout: ball events/s, bytes/s, per-shot totals, playback lead, last SimDiff error |
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
- `net_graph.gd` / `NetGraph.tscn` — `NetGraph` (`CanvasLayer`), fed by `PhysicsSim.net_*` counters.
- `debug_rack_presets.gd` — `DebugRackPresets` (`RefCounted`, pure data).

Every panel builds its own UI procedurally in `_ready()` (no per-panel `.tscn`) — deviates
from the plan's "panels as child scenes" note; flagged to alpha, no functional difference.

HUD, gizmos and shot console all enumerate live balls via `Table.sim.get_balls()` (contract
§PhysicsSim), never by walking `DemoRack`'s child list directly. Gizmos (loop 1, T4.5) read
every shape straight from `Table.layout` — the same `TableGeometry.layout()` output
`table_builder.gd`/`table_visuals.gd` build from — converted to world space with
`table.to_global(pos + Vector3(0, bed_height_m, 0))`; no pocket/drop-zone/facing formula is
computed a second time here (`tests/physics/gizmo_probe.gd` asserts the two never drift).

`PHYSICS_3D_COLLISION_PAIRS` reads 0 the entire time under Jolt, verified live during a real
break (`~/work/.herdr/adhoc-wip-table-ball/gamma/gamma_probe.log`, case J: "max
PHYSICS_3D_COLLISION_PAIRS=0.0"); the 4.7 docs list no Jolt-specific replacement monitor. The
HUD's "contact pairs" instead sums `get_colliding_bodies().size()` over every ball while its
own `contact_monitor` is on (true only during a live shot — `PhysicsSim._on_struck`/`_recount`).
