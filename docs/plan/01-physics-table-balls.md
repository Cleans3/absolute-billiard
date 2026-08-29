# 01 — Physics, table, balls

*Rewritten against 06-final-decisions D1, D5, D7 as amended by Cleanse's rulings P1–P3.*

## 1. Purpose
Define the shot-to-shot physics model for `Ball`s, the cue API, table and pocket geometry, per-ball scoring, `TrickShot` recognition, and `Round` setup, so every later module scores against one foundation.
Target is mobile first: every number here has to survive a 2022 mid-range Android phone before it survives a desktop.

## 2. Concepts & data model

### Simulation model
`RigidBody3D` on **Jolt** in a thin 3D scene, all gameplay constrained to the table plane. Jolt applies Coulomb friction at contacts, so throw, english transfer and cut-induced deflection emerge instead of being scripted. The only missing term is rolling resistance, added as a velocity-opposing force/torque pair in `_integrate_forces` (§4). A custom 2D analytic sim was rejected: it cannot express jump shots, `table_tilt`, table bumps or bomb scatter, all of which 01 and 03 already spec. Cross-platform determinism is unreachable in GDScript (libm trig, float32 vectors), so replays record `Shot` intents plus the `Round` seed and re-run on the host only.

### Physics settings (non-negotiable)
| setting | value | why |
|---|---|---|
| `physics/3d/physics_engine` | `Jolt` (explicit, not "Default") | contact friction is the whole model |
| `physics/common/physics_ticks_per_second` | `240 [tune]`, **fallback `120`** | see tick budget below |
| `Ball.continuous_cd` | `true` (always, both tick rates) | 10 m/s at 120 Hz = 83 mm/step vs a 57 mm ball — tunneling is certain without it |
| `Ball.contact_monitor` / `max_contacts_reported` | `true` / `8` | the contact log is the only input to trick detection |
| `Ball.mass` | `0.17 kg` | regulation ball; was never specified before |
| `Ball.physics_material.friction` | `0.20 [tune]` ball–cloth, `0.06 [tune]` ball–ball | |
| cue impulse range | `0 .. 1.7 N·s [tune]` | derived in §3, replaces the dimensionally broken `18 N·s` |
| rolling resistance | custom torque in `_integrate_forces`, `0.020 [tune]` | Jolt has no rolling-resistance term |
| pockets | two jaw cylinders + drop plane per pocket | rattle and reject-at-speed emerge; `pocket_capture_speed_mps` is deleted |
| rail shapes | per-shape metadata `rail_id: StringName` | so the contact log can tell a rail from a ball from a jaw |

**Tick budget (P1).** 240 Hz is a hypothesis, not a decision: it is validated by 04's M0 spike (12 balls, max-power break, 60 fps sustained, physics step ≤ 8 ms on the target phone). If the spike misses, drop to 120 Hz and keep CCD — the visible cost is slightly softer cushion rebounds, not tunneling. Ball count per `Round` is capped by that budget at **≤ 12 balls total including the cue ball `[tune]`**; 02's "10 object balls" fits with headroom.

### TableSpec (Resource)
`length_m = 2.54 [tune]`, `width_m = 1.27 [tune]`, `ball_radius_m = 0.0286 [tune]`, `rail_height_m = 0.09 [tune]`, `cushion_restitution = 0.86 [tune]`, `cushion_friction = 0.18 [tune]`, `rolling_resistance = 0.020 [tune]`, `spin_decay = 0.55 [tune]`, `rest_speed_mps = 0.02 [tune]`, `rest_time_sec = 0.30 [tune]`, `clearance_margin_m = 0.002 [tune]`, `kitchen_line_x = -0.635 [tune]` (head-string quarter, used for foul respawn).

### Pocket geometry
Each pocket is a `PocketSpec { id: StringName, position: Vector3, mouth_normal: Vector2, mouth_width_m }` plus three bodies: **two vertical jaw cylinders** (`jaw_radius_m = 0.012 [tune]`, high friction, restitution `0.55 [tune]`) at the mouth corners, and a **drop plane** — an `Area3D` below cloth level inside the throat. Mouth widths: corner `0.114 [tune]`, side `0.127 [tune]` against a `0.0572 m` ball.

A pot is the ball's centre crossing the drop plane, and nothing else. Rattle (ball bouncing between jaws and staying up), reject-at-speed (fast ball hitting the far jaw and coming back out) and the pocket-cut asymmetry all fall out of the jaw collisions for free. There is no speed test and no capture cone; `pocket_capture_speed_mps` is deleted.

### Ball
`id: String`, `ball_type: BallType`, `is_cue_ball: bool`, `is_pocketed: bool`, `pocketed_in: StringName` (pocket id), `spawn_index: int`. Live state (`position`, `linear_velocity`, `angular_velocity`) is read from the `RigidBody3D`, never mirrored into a second field.

### BallType (Resource) and value tiers
`id: String`, `display_name: String`, `color: Color`, `base_value: int`, `behaviour_tags: Array[StringName]`, `mass_multiplier: float = 1.0`, `radius_multiplier: float = 1.0`, `counts_for_clear: bool = true`.

Values are **100 / 250 / 500** — three tiers wide enough to read mid-aim, unlike the old 20% spreads. Tags are descriptive; other modules read them but must never branch on a hardcoded id.

| id | value | tags | note |
|---|---:|---|---|
| `cue` | 0 | `cue` | white; `counts_for_clear = false` |
| `red_basic` | 100 | `tier1`, `common` | the bread-and-butter ball |
| `blue_mid` | 250 | `tier2`, `common` | |
| `gold_prize` | 500 | `tier3`, `high_value` | one or two per `Round` |
| `black_penalty` | -250 | `penalty`, `risk` | scales with the full multiplier stack — deliberate (D4) |
| `stone_ball` | 0 | `obstacle`, `heavy` | `mass_multiplier = 3.0`, `counts_for_clear = false`; blocks lines, never a target |
| `bomb_ball` | 250 | `gimmick`, `volatile` | shop unlock; scatters neighbours when struck above `3.0 m/s [tune]` |
| `split_ball` | 250 | `gimmick`, `splitter` | shop unlock; on pot, spawns one `red_basic` at its last rest position |
| `joker_ball` | 250 | `gimmick`, `wild` | shop unlock; `×2` on the highest-value ball potted in the same `Shot` |

**Shop overrides (P3).** The gimmicks are not unlocked on a schedule — the player buys the order from the Bartender shop that 02 owns. Ball purchases are `BallTypeOverride { ball_type_id, unlocked: bool, base_value_override: int }` resources; 02 hands `RoundDirector` the active override set at `Round` setup and 01 resolves `value(ball_type) = override.base_value_override if set else ball_type.base_value`. Nothing in 01 mutates a `BallType` resource in place, so a tier-value upgrade is one row of save data, not a migration.

### CueSpec (Resource) and the cue API
The cue is a shop item too (P3), so its limits are data, not constants:

| field | default | upgrade does |
|---|---|---|
| `power_cap_impulse` | `1.7 N·s [tune]` | raises the top of the power curve, up to `2.2 [tune]` |
| `spin_offset_radius` | `0.35 [tune]` (fraction of ball radius) | more english before a miscue, up to `0.50 [tune]` |
| `jump_unlocked` | `false` | enables jump intent |
| `masse_unlocked` | `false` | enables massé intent |
| `wobble_reduction` | `0.0 [tune]` (0..1) | scales 03's `aim_wobble` Effects by `(1 - wobble_reduction)`, floored at 0 |
| `miscue_threshold` | `0.92 [tune]` | fraction of `spin_offset_radius` past which the strike miscues |

The Player module is still deferred and stays a black box. It produces exactly one struct, and 01 never asks where it came from — mouse, touch drag, gamepad or a replay file are indistinguishable at this boundary (P1):

`ShotIntent { aim_dir: Vector2, power: float (0..1), spin_offset: Vector2 (unit disc), elevation_deg: float, jump: bool, masse: bool, shooter_id: int }`

### Shot and the contact log
`Shot { id: String, shooter_id: int, intent: ShotIntent, seed: int, contacts: Array[ContactEvent] }`. A `Turn` is one `Shot`; only **one `Shot` exists at a time** (P2) — free-roaming friends never get a second cue ball, so shot boundaries, trick attribution and camera framing all survive intact.

`ContactEvent { tick: int, kind: enum {BALL, RAIL, JAW, POCKET, NUDGE}, a: String, b: String, rail_id: StringName, pocket_id: StringName, position: Vector3, impact_speed: float }`, appended in tick order. This ordered log is the *only* input to trick detection and foul detection — no per-trick state machines.

## 3. Rules/formulas

### Shot lifecycle
A `Shot` opens on cue contact and closes when every ball satisfies `speed < rest_speed_mps` and `angular_speed < 0.15 rad/s [tune]` continuously for `rest_time_sec`. Hard ceiling `12 s [tune]`: past it, balls are frozen and the shot resolves anyway. A `Round` runs until its timer expires, its shot budget is spent, or `table_cleared` fires.

### Cue impulse, derived
Impulse is momentum: `J = m · Δv`. With `m = 0.17 kg` and a top break speed of `10 m/s` (real breaks land 8–12 m/s), `J_max = 0.17 × 10 = 1.7 N·s`. The old `18 N·s` implied `Δv = 106 m/s` — 380 km/h, dimensionally broken. So `J = power × CueSpec.power_cap_impulse`, applied as a single `apply_impulse(J * aim_dir_3d, contact_offset)` where

`contact_offset = (-aim_dir_3d * R) + (spin_offset * R * CueSpec.spin_offset_radius)`

Because the impulse is applied off-centre, Jolt derives the angular velocity itself: follow, draw and english are one line of physics, not three special cases. `|spin_offset| > miscue_threshold` is a miscue — power scaled by `0.35 [tune]`, aim scattered by `4° [tune]`.

**Jump** requires `jump_unlocked`, `power ≥ 0.70 [tune]` and `elevation_deg ≥ 30`; the elevated aim vector simply has a downward `Y` component, and the hop is Jolt's response to hitting a sphere above centre against the cloth. **Massé** requires `masse_unlocked`, `elevation_deg ≥ 45 [tune]` and `|spin_offset| ≥ 0.60`; the curve emerges from sidespin plus cloth friction. No scripted "curve bias" term exists in either case.

### Cloth, cushions, rails
Sliding friction is Jolt's. Rolling resistance is ours: a force of magnitude `mass · g · rolling_resistance` opposing travel, plus the matching torque at the contact point so the ball keeps rolling rather than skidding (§4 code). At `0.020` that is `≈0.20 m/s²` — a ball struck at 2 m/s runs about 10 m, four table lengths. Spin about the table normal decays at `spin_decay × rolling_resistance`.

Cushions reflect normal velocity by `cushion_restitution` and shed tangential velocity by `cushion_friction`; both are `PhysicsSim`-modifiable so 03's `glass_cushions` is a value change, not a code path. Every rail shape carries `rail_id`, which is what makes a `RAIL` contact countable.

### Foul
**A legal `Shot` must produce at least one `BALL` contact between the cue ball and any non-cue ball.** Without this rule the dominant strategy is tapping the nearest ball forever; with it, a whiff costs a shot. A foul is: no object-ball contact, *or* the cue ball entering a drop plane (the old scratch), *or* any ball leaving the table. Consequences: the `Shot` scores nothing, one shot is deducted from the `Round` budget, 02 applies its viewer drop, and the cue ball respawns in the kitchen — the quarter of the table behind `kitchen_line_x`, at the first Poisson-disk candidate that clears every other ball. No ball-in-hand, no spotting, no other standard pool rules.

### Scoring
`raw_points` for a `Shot` is the sum over potted balls of `value(ball_type)`, then tag modifiers: `high_value` `+25%`, `wild` applies `×2` to the single highest-value ball potted this shot, `penalty` stays negative and rides the same multiplier stack the positive balls do. `raw_points` **excludes** trick multipliers; 02 applies the winning trick multiplier and converts to `Cash`.

### TrickShot detection — five tricks, disjoint
All five are counters over the ordered contact log, evaluated once at shot end. Flat bonuses are gone: a `+50` flat was `+50%` on a red and `+10%` on a gold, so tricks were only worth doing on cheap balls.

| id | condition (over the contact log) | multiplier |
|---|---|---|
| `ComboPot` | ≥2 object balls potted this shot | `1.15`, `1.30 [tune]` at 3+ |
| `BankShot` | a potted object ball has ≥1 `RAIL` contact between its first `BALL` contact and its `POCKET` event | `1.20` |
| `KickShot` | the cue ball has ≥1 `RAIL` contact before its first object-ball `BALL` contact | `1.25` |
| `Carom` | the cue ball contacts ≥2 distinct object balls before the first `POCKET` event | `1.35` |
| `RailRunner` | a potted object ball has ≥3 `RAIL` contacts before its `POCKET` event | `1.60` |

**Disjointness: a `Shot` pays exactly one trick multiplier — the highest that fired.** `trick_ids` is emitted sorted by multiplier descending, and 02 multiplies by the first entry only. Everything detected is still emitted, so 03's Effects can react to a `KickShot` that lost to a `RailRunner`. `TrickShot { id: StringName, multiplier: float, shot_id: String, tags: Array[StringName] }` — no `bonus_points` field, because there are no flat bonuses.

Cut and not coming back: `MasséCurve` (curve-radius fitting is noise), `DoubleCushionExit` (fires on nearly every rail), `ScratchEscape` (undefinable), `SplitChain` and `BombCascade` (they described balls that did not exist yet).

### Random drop — Poisson-disk
Bridson sampling over the table interior, seeded from `round_seed`: inset the rectangle by `ball_radius + clearance_margin_m`, subtract a disc of `pocket_radius + ball_radius + 0.01 m [tune]` at each pocket, sample with minimum spacing `r = 2.4 × ball_radius [tune]` and `k = 30` candidates per active point. About 15 lines, and it cannot fail: if it yields fewer points than balls, shrink `r` by 5% and resample. Balls are assigned to points high-value-first so a `gold_prize` never lands in the one awkward spot by accident.

The seed is **shown in the round UI** — the same seed reproduces the rack, which is what makes a shared "watch this" moment possible. Night 1 and Night 5 racks are hand-authored position arrays (`.tres`), because a first impression and a finale should not be a dice roll.

### Stuck state and table bump
If, after a `Shot` resolves, no ball with `counts_for_clear` and `value > 0` remains, the `Round` ends immediately via `table_cleared` with **no penalty** — being left with only `black_penalty` and `stone_ball` is not a player mistake. If the cue ball comes to rest wedged (its `test_move` is blocked in all 16 sampled directions), it is respawned free in the kitchen with no foul and no shot cost.

Non-shooters can shove the table (P2). `PhysicsSim.nudge(direction: Vector2, strength: float, source_peer_id: int)` applies a central impulse of `strength × 0.06 N·s [tune]` to every non-resting ball and appends a `NUDGE` contact event, so the log stays the complete record of what happened. Sustained tilt is the same hook by another name: `apply_modifier("table_tilt", ...)`. 03 owns the Effect that wraps either, 02 owns the viewer/hype price of using it.

## 4. Godot implementation sketch

### Scenes and nodes (no autoloads — D7)
- `src/gameplay/table/Table.tscn` — `StaticBody3D` bed, rail shapes each carrying `rail_id`, per-pocket jaw cylinders + drop-plane `Area3D`, and a **`PhysicsSim` child node** that owns the live modifier stack. `PhysicsSim` is *not* an autoload and there is no global `Signals` bus; listeners connect directly to the node that emits.
- `src/gameplay/balls/Ball.tscn` — `RigidBody3D`, `continuous_cd`, `contact_monitor`, mesh, `SphereShape3D`.
- `src/gameplay/cue/CueController.tscn` — consumes a `ShotIntent`, renders aim arc / power / spin cursor. Input device is the Player module's problem.
- `src/gameplay/round/RoundDirector.gd` — child of `MainLevel`; owns the rack, the shot state machine, the contact log, scoring and the signals below.

### Physics modifiers
`PhysicsSim.apply_modifier(field: StringName, delta: float, duration_sec: float)` — host-only, called only by 03's Effect system. Fields: `friction`, `restitution`, `ball_mass`, `pocket_mouth_width`, `table_tilt`, `cushion_friction`, `cushion_restitution`, `spin_transfer`, `shot_power_scale`, `rolling_resistance`. Plus `PhysicsSim.nudge(...)` as above. Modifiers are additive deltas over `TableSpec` values with independent timers; nothing writes the resource.

### Rolling resistance
```gdscript
# Ball.gd — Jolt does contact friction; rolling resistance it does not.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
    var v := state.linear_velocity
    if v.length() < sim.rest_speed and state.angular_velocity.length() < 0.15:
        state.linear_velocity = Vector3.ZERO
        state.angular_velocity = Vector3.ZERO
        return
    var up := sim.surface_normal                      # tilts with apply_modifier("table_tilt")
    var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
    # Coulomb-like: magnitude independent of speed, direction opposing travel.
    var f_roll := -v.normalized() * mass * g * sim.rolling_resistance
    state.apply_central_force(f_roll)
    # same force at the contact point, so the ball keeps rolling instead of skidding
    state.apply_torque((-up * radius).cross(f_roll))
    # english about the table normal bleeds off faster than roll
    var spin := up * state.angular_velocity.dot(up)
    state.apply_torque(-spin * mass * radius * sim.rolling_resistance * sim.spin_decay)
```

### Signals (emitted by `RoundDirector`, connected directly)
- `ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)` — the pocket id is what lets 02 score which `Camera` had the shot; `Table.get_pocket(pocket_id) -> PocketSpec` gives it the world position for the distance + occlusion test (P2).
- `shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)`
- `trick_detected(trick: TrickShot, shot_id: String)`
- `table_cleared(round_id: String)`

### File paths under `src/`
`gameplay/table/TableSpec.gd`, `gameplay/table/PocketSpec.gd`, `gameplay/table/PhysicsSim.gd`, `gameplay/balls/BallType.gd`, `gameplay/balls/BallTypeOverride.gd`, `gameplay/balls/Ball.gd`, `gameplay/cue/CueSpec.gd`, `gameplay/cue/CueAim.gd`, `gameplay/round/RoundDirector.gd`, `gameplay/round/ContactLog.gd`, `gameplay/round/ShotScoring.gd`, `gameplay/round/TrickShotDetector.gd`, `gameplay/round/PoissonDrop.gd`.

### Physics test fixtures (`tests/physics/`, headless)
The cheapest insurance in the plan — each is a scripted `ShotIntent` against a fixed rack, asserted on outcome:
1. **Straight-in pot** — ball 0.5 m off a corner pocket, centre-ball strike: 100/100 runs pot.
2. **Stun stop** — centre-ball at 2 m/s into a full ball: cue ball residual speed `< 0.05 m/s`.
3. **30° cut** — object ball crosses the target line within `±15 mm [tune]` at 1.0 m.
4. **Break integrity** — max power into a 12-ball rack, 200 runs: zero tunneling, zero balls off table, all at rest inside 12 s.
5. **Trick log** — a scripted bank, kick, carom, combo and rail-runner each detect their own trick and exactly one multiplier is paid.
6. **Mobile budget** — fixture 4 on the target phone: 60 fps sustained, physics step `≤ 8 ms`. This one gates the 240 Hz setting.

## 5. Interfaces to other modules

**To 02 (economy/shop).** `shot_ended(...)` → 02 applies `trick_ids[0]`'s multiplier to `raw_points`, then the stream multipliers, then converts to `Cash`; `foul = true` costs a shot from the `Round` budget and drops `Viewers`. `ball_potted(ball, shot_id, pocket_id)` → per-ball reward flow and the camera-view score for that pot. `table_cleared(round_id)` → close the `Round`. 02's `Shop` supplies `Array[BallTypeOverride]` and the active `CueSpec` at `Round` setup; 01 reads both and never writes them. 01 states the ball cap (`≤ 12`) that 02's "10 object balls per `Round`" sits inside.

**To 03 (drinks/events).** `PhysicsSim.apply_modifier(...)` and `PhysicsSim.nudge(...)` are the entire physics surface for `Effect`s and `Event`s, host-only. `BallType.behaviour_tags` are readable by both. `trick_detected` is amplifiable. `aim_wobble` is applied by the Player module and scaled by `CueSpec.wobble_reduction`, floored at 0.

**To 04 (architecture/netcode).** The host owns the sim; clients get contact events plus a low-rate heartbeat, so the contact log doubles as the sync payload. `Shot.intent` + `Round` seed is the whole replay record. `PhysicsSim` lives in `Table.tscn` as a plain node — 01 declares no autoload.

## 6. Open questions
- `bomb_ball`: does the scatter destroy the bomb only, or convert its neighbours into 0-value fragments?
- `split_ball`: one spawn per pot, or one per carom chain within the shot?
- Should one pocket per table be a deliberately awkward "house" pocket (narrower mouth, harsher jaws)?
- Does `stone_ball` count against the ≤12 cap, or sit outside it as scenery with collision?
- Jaw restitution `0.55` decides how often shots rattle; that is a feel dial — who owns it after the first playtest, 01 or 03?

## 7. MVP cut vs later

**MVP.** Jolt `RigidBody3D` sim at a validated tick rate with CCD on every ball. Cue impulse, spin offset, miscue, and the `ShotIntent` boundary. Jaw-cylinder pockets with drop planes. Rolling resistance in `_integrate_forces`. Foul rule with kitchen respawn. Three value tiers plus `black_penalty` plus `stone_ball`; gimmick balls stubbed as buyable but only `bomb_ball` implemented. All five tricks with the disjointness rule. Poisson-disk drop with a visible seed and the two authored racks. `CueSpec` read from the shop, `BallTypeOverride` resolution. Stuck-state rule. All four signals. Fixtures 1–4 and 6 green before any netcode work starts.

**Later.** `split_ball` and `joker_ball` behaviours. Table bump/tilt tuning past the raw hook. Shot ghost previews and spin visualisers. Adaptive layout difficulty by `Round`. Same-machine replay playback from intents. A second table with different `TableSpec` values as a shop item.
