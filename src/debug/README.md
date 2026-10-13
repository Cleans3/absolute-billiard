# src/debug/

Dev-only debug layer (04 §4, `06 P3` debug requirement). Instanced as `Debug` in
`MainLevel.tscn`, wired to `Table`, `DemoRack` and `Player` by NodePath. `debug_root.gd`
frees the whole subtree in `_ready()` when `OS.is_debug_build()` is false, so none of this
exists, costs anything, or is reachable in a release export.

Gameplay code never references `src/debug` (`grep -r "debug" src/gameplay` is empty). Every
panel only calls public gameplay API — `Table.rebuild()`, `DemoRack.spawn_layout()`,
`Ball.strike()`, `Engine.time_scale` — or toggles built-in `Node` process flags on the
`Player` subtree to hand off control to the free camera; it never edits `src/gameplay`.

## Debug mode (adhoc-1012a) — the phone-usable one

Settings > Video & Audio > **Debug mode** (debug builds only; the phone APK is one). It shows `DebugStrip` in the free
stretch of the top bar (DEBUG, Rewind, Replay, Re-rack; `tests/ui/ui_probe.gd` keeps it clear of every HUD and touch
widget) and lets DEBUG open `DebugPanel`: a drawer on the right edge, so the table stays in view while a number moves. It is
one `UIModal` like every other screen — `UIRouter` keeps it the only one open, it blocks the player's input, Esc and
Close shut it. The strip stays above the drawer; a saved physics tuning is applied the first time the mode comes on.

| page | does |
|---|---|
| Feel | a slider (and −/+) for every `TableSpec.LIVE_FIELDS` number, grouped: ball to ball (cascade on/off, restitution, friction), cloth and rolling, settling (the creep tail: settle ramp, spin stop, tilt cap), cushion, rest/pockets/CCD; the `PhysicsSim` stats (cloth/cushion/cue-mass multipliers, tilt + direction); the live `CueSpec`. Each move is `TableSpec.set_live` + `Table.apply_physics()` once per frame: bodies, balls and the BallMotion model change, nothing is re-racked. Defaults / Save (loads again next time) / Copy (the changed numbers, to paste into `TableSpec`) |
| Shots | every shot is recorded with the table it started from (positions, shots left, points, clock, Cash): **Rewind** puts it all back, **Replay** rewinds and fires the recorded intent again through the normal shot path, **From here** replays that shot and every later one; a test shot (aim, power, spin, elevation, "aim at nearest") |
| Table | stop the balls, cue ball to the head spot, clear the table, rack presets (break, straight-in, cut, stun) dealt onto the Round's own balls, re-rack the live Round (same or new seed) |
| Game | the Phase / Night / shots / clock / Cash line, Advance (GO LIVE, next Night), Cash, shots, time, any Drink or Event |
| View | stats HUD, gizmos, net graph, free camera (not on touch), time scale |

**Host only.** Everything that changes the game or the physics is the host's (`DebugSession.is_host()`); a client's panel
locks those pages and shows its own numbers. A physics edit reaches the clients with the next `shot_started` stats (04 §5),
or the mid-Shot `motion_stats` RPC if a shot is live — `tests/debug/session_probe.gd` checks the wire carries every number.

**Replay is a re-simulation, not a recording.** Rewind restores every ball to where the recorded shot found it, zero
velocity, then the recorded `ShotIntent` goes through `PhysicsSim.request_shot` (validator, scoring, tricks, Cash all run
again). Jolt on one machine from the same state ends within a few thousandths of a millimetre of the first run for a shot
with few collisions (a stun shot, 0.002 mm in `session_probe.gd`) but not bit for bit: a break into a packed rack (the 20 m/s
break, adhoc-1013c W2) is chaotic, the same record replays to anywhere from 10 mm to 2.2 m from the original (a ball potting
or not, decided by float noise below what a transform prints), so its Δ is a report, not a promise; a miscue draws `randf` and
will differ. Each replay shows how far the balls ended from the original (`replay Δ mm` on the shot's line). A recording of ball poses would be exact, but it
could not answer "what happens with a different number" — that is the point of a replay here. Rewind does not restore
the crowd (`StreamManager`), live Effects or whose Turn it is.

## Keys

| Action | Key | Does |
|---|---|---|
| `debug_hud` | F1 | Toggle the stats HUD (fps, Round seed, physics tick, physics step ms, contact pairs, awake balls, per-ball speed) |
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
- `debug_session.gd` — `DebugSession` (`Node`): the debug mode's logic — live physics edits, the shot recorder, rewind / replay, table and game tools. No UI.
- `debug_panel.gd` / `debug_widgets.gd` — `DebugPanel` (`UIModal`, the drawer) and the touch-sized controls it builds from.
- `debug_strip.gd` — `DebugStrip` (`CanvasLayer`), the four always-on buttons.

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
