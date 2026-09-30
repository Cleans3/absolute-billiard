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
| `Ball.continuous_cd` | cue ball always; object balls only above `ccd_speed_mps = 3.0 [tune]` (07 §1.2) | 10 m/s at 120 Hz = 83 mm/step vs a 86 mm ball — tunneling is certain without it |
| `Ball.contact_monitor` / `max_contacts_reported` | on only during a live `Shot` (`PhysicsSim`) / `8` cue, `6` object | the contact log is the only input to trick detection |
| `Ball.mass` | `0.17 kg × (R / 0.0286)³` | regulation density; at `scale = 2.0` the ball is `≈1.36 kg` |
| friction | ball material `0.06 [tune]`; cloth `0.20 [tune]`, cushion `0.18`, jaw `0.6` all `rough = true` | combine rule is **MIN unless one side is `rough`**, so ball–ball gets the ball's value and ball–table gets the table's |
| restitution | ball material `0.95 [tune]`; table materials `absorbent = true` with `bounce = 0.95 − e_wanted` | combine rule is **MAX unless one side is `absorbent`** (then subtract), so ball–ball is 0.95, cloth 0, cushion `e0`, jaw `0.55`. Ball–ball at 0.05 was the v0.0.1 stun bug: cue ball kept 47% of its speed |
| `physics/jolt_physics_3d/simulation/bounce_velocity_threshold` | `0.2` | Jolt default `1.0` kills restitution on slow rail hits — a soft ball slid along the cushion |
| `physics/jolt_physics_3d/limits/max_angular_velocity` | `600` | default `47 rad/s` is below pure rolling at 2 m/s on this ball |
| `physics/jolt_physics_3d/simulation/sleep_*` | velocity `0.05`, time `0.3` | 07 §1.3; Jolt's own sleep can take far longer than that for a body still in resting contact (or never trip), so `Ball.is_resting` — not `sleeping` — is what `PhysicsSim` counts (see "Rolling resistance, rest..." in §4) |
| `physics/common/physics_interpolation` | `true` | 07 §1.5–1.6; `max_physics_steps_per_frame` was removed (T1.1 WIP) so a slow frame reruns its full backlog instead of dropping ticks |
| cue speed cap | `power × mass × CueSpec.power_cap_speed_mps` | derived in §3; a speed cap is scale-invariant, an impulse cap is not |
| rolling resistance | custom force + torque in `_integrate_forces`, `0.035 [tune]` | Jolt has no rolling-resistance term |
| pockets | angled jaw stubs (part of the rail ends) + a tall drop-zone chute per pocket | rattle and reject-at-speed emerge; `pocket_capture_speed_mps` is deleted |
| rail shapes | per-shape metadata `rail_id: StringName` | so the contact log can tell a rail from a ball from a jaw |

**Tick budget (P1).** 240 Hz is a hypothesis, not a decision: it is validated by 04's M0 spike (12 balls, max-power break, 60 fps sustained, physics step ≤ 8 ms on the target phone). If the spike misses, drop to 120 Hz and keep CCD — the visible cost is slightly softer cushion rebounds, not tunneling. Ball count per `Round` is capped by that budget at **≤ 12 balls total including the cue ball `[tune]`**; 02's "10 object balls" fits with headroom.

### TableSpec (Resource)
**Scale ruling (v0.0.3, plan.md `adhoc-wip-table-ball`):** every geometric value is a `REG_*` regulation constant (9-ft WPA table) times a single `scale` knob, default **2.0** — balls read clearly bigger and the table reads big in first person. `bed_height_m` is the one exception: it is **player-relative, not scale-relative** (real bed height × scale reads chest-high on a real-height player; `06` P-ruling). Mass follows radius³ (constant density) and the cue is a speed cap, so the physics formulas never see the scale.

`TableGeometry.layout(spec) -> TableLayout` derives all of this into plain data — pockets, rail segments (with their angled corner/side facings), spots, sights, drop zones — with no scene nodes, so it is headless-testable (`tests/physics/geometry_probe.gd`). `Table` (`table.gd`) calls it and hands the result to `table_builder.gd` (bodies/collision) and `table_visuals.gd` (meshes) — spec data, pure geometry and scene construction are three separate files, per `06`/`04`'s architecture split.

The table below is `src/tools/spec_dump.gd`'s own output, pasted verbatim — the defaults here cannot drift from the code that defines them:

<!-- BEGIN spec_dump.gd output -->
`REG_*` constants (metres/degrees, 9-ft WPA regulation):

| constant | value |
|---|---:|
| `REG_LENGTH` | 2.54 |
| `REG_WIDTH` | 1.27 |
| `REG_BALL_RADIUS` | 0.028575 |
| `REG_CORNER_MOUTH` | 0.1175 |
| `REG_SIDE_MOUTH` | 0.13 |
| `REG_CUSHION_NOSE_H` | 0.036 |
| `REG_RAIL_WIDTH` | 0.178 |
| `REG_RAIL_TOP_H` | 0.042 |
| `REG_APRON_H` | 0.18 |
| `REG_JAW_RADIUS` | 0.012 |
| `REG_CORNER_SHELF` | 0.04 |
| `REG_SIDE_SHELF` | 0.005 |
| `REG_CORNER_FACING_DEG` | 142.0 |
| `REG_SIDE_FACING_DEG` | 103.0 |
| `REG_CUE_REACH` | 1.75 |

`@export` fields (feel, `[tune]`, plus `scale` and `bed_height_m`):

| field | default |
|---|---:|
| `scale` | 2.0 |
| `bed_height_m` | 0.9 |
| `cushion_restitution` | 0.86 |
| `cushion_restitution_min` | 0.26 |
| `cushion_soft_speed_mps` | 3.0 |
| `cushion_hard_speed_mps` | 7.5 |
| `cushion_friction` | 0.18 |
| `cloth_friction` | 0.2 |
| `ball_friction` | 0.06 |
| `ball_restitution` | 0.95 |
| `rolling_resistance` | 0.035 |
| `spin_decay` | 0.55 |
| `rest_speed_mps` | 0.02 |
| `rest_time_sec` | 0.3 |
| `ccd_speed_mps` | 3.0 |
| `clearance_margin_m` | 0.003 |
| `jaw_restitution` | 0.55 |

Derived getters at the default `scale = 2.0` (`REG_* × scale`, `bed_height_m` excepted):

| getter | value | formula |
|---|---:|---|
| `length_m` | 5.08 | REG_LENGTH × scale |
| `width_m` | 2.54 | REG_WIDTH × scale |
| `ball_radius_m` | 0.05715 | REG_BALL_RADIUS × scale |
| `corner_mouth_m` | 0.235 | REG_CORNER_MOUTH × scale |
| `side_mouth_m` | 0.26 | REG_SIDE_MOUTH × scale |
| `jaw_radius_m` | 0.024 | REG_JAW_RADIUS × scale |
| `kitchen_line_x` | -1.27 | -length_m / 4 |
| `rail_height_m` | 0.084 | REG_RAIL_TOP_H × scale |
| `cushion_nose_h_m` | 0.072 | REG_CUSHION_NOSE_H × scale |
| `rail_width_m` | 0.356 | REG_RAIL_WIDTH × scale |
| `apron_h_m` | 0.36 | REG_APRON_H × scale |
| `corner_shelf_m` | 0.08 | REG_CORNER_SHELF × scale |
| `side_shelf_m` | 0.01 | REG_SIDE_SHELF × scale |
| `foot_spot_x` | 1.27 | length_m / 4 |
| `cue_reach_m` | 3.5 | REG_CUE_REACH × scale |
<!-- END spec_dump.gd output -->

`cushion_restitution_min` was retuned from 0.20 to 0.26 during the scale-2.0 pass (T1.7): at 0.20 a full-power head-spot shot lost too much energy off the foot rail to return half the table, and 0.35 made the hard-vs-soft cushion angle too close (`tests/physics/probe.gd` gates both).

### Pocket geometry
Each pocket is a `PocketSpec { id: StringName, position: Vector3, mouth_normal: Vector2, mouth_width_m }`. `TableGeometry.layout` also derives, per rail segment ending at a pocket, an angled **facing** direction (`RailSegment.facing_a`/`facing_b`, rotated off the straight rail direction toward the pocket bisector by `(180° - facing_deg) / 2`, corner `142°` / side `103°`) — `table_builder.gd` builds these as short jaw stubs at nose height, replacing the old free-standing jaw cylinders, so the jaws are part of the rail ends; the stub's own thickness is shifted entirely to the outward side of the parent rail's `inward_normal`, so its inner face sits flush with the nose line instead of straddling it and rejecting a moderate-speed ball before it ever reaches the mouth (loop 1, gamma F2). A **drop zone** (`Area3D`, one per pocket) is one or two tall vertical chutes rather than a thin trigger plane — a corner gets two flush strips (one per axis it sits outside of), a side gets one — each strip sitting entirely outside the nose-to-nose playfield rectangle on its own axis alone, so a ball still resting or rolling anywhere inside that rectangle can never read as pocketed (loop 1, gamma F1: the original single box, centred on the pocket itself, reached back into the bed far enough to catch a ball that was nowhere near falling). Each strip's top still reaches up to the ball's own resting centre height (there is no bed under a pocket mouth, so a ball centred there belongs to the pocket immediately, before it has fallen any real distance) and extends far down so a fast fall cannot tunnel past a one-physics-step-thin trigger — pulling the top down to one radius *below* the cloth instead (requiring a centre to have actually fallen first) was tried and breaks fast shots outright, since a ball can cross a strip's whole footprint faster than gravity drops it one radius. A `SafetyFloor` catches anything that still falls through a gap instead of a pocket rather than free-falling forever.

The corner rail truncation (`c` in `table_geometry.gd`) carries one extra ball radius of clearance beyond the bare mouth-width span: the straight cushion collider keeps its full outward depth (`2R`) right up to where it is cut, so without the margin a dead-centre shot at the pocket grazes the cushion's outward corner with exactly zero clearance (found via `tests/physics/probe.gd`'s straight-in-pot case).

A pot is the ball's centre entering the drop-zone chute, and nothing else. Rattle (ball bouncing between jaws and staying up), reject-at-speed (fast ball hitting the far jaw and coming back out) and the pocket-cut asymmetry all fall out of the jaw collisions for free. There is no speed test and no capture cone; `pocket_capture_speed_mps` is deleted.

Jaw/cushion collider thickness is floored against `TableSpec.max_ball_speed_mps` (10.0, scale-invariant, matches `CueSpec.power_cap_speed_mps`) ÷ `PhysicsSim.LIVE_TICK`, not just `ball_radius_m`/`jaw_radius_m` — those shrink at a small `scale` while a ball's absolute cue-power-cap speed never does, so the collider-vs-per-step-travel ratio that protects against tunnelling gets worse the smaller the table (loop 1, gamma H: a 9 m/s ball into a side jaw stayed on a scale-2.0 table but tunnelled/launched off a scale-1.0 one). That floor alone did not fully close it: Jolt can still resolve a fast, high-spin ball's contact right where a cushion ends and a facing begins (or where the ball, still slightly airborne from one such contact, comes down almost level with a cushion's own short top edge) with several m/s of spurious *vertical* speed and, in the worst observed case, an almost-vertical contact normal — reproducible with CCD on, at 4× the tick rate, and with collider thickness well above the floor, so it is a Jolt contact-generation artifact at that specific geometry, not a tunnelling/step-size problem. `Ball._integrate_forces` treats every cushion/jaw hit as what it geometrically is — a purely horizontal contact normal — and restores the vertical speed it itself produced the tick before, but only on the first physics step of a new contact (a ball still touching a jaw several steps into the same contact, e.g. settling into a corner pocket, keeps integrating normally, or it could never actually fall).

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
| `power_cap_speed_mps` | `10 m/s [tune]` | raises the top of the power curve, up to `13 [tune]` |
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
Impulse is momentum: `J = m · Δv`. A top break speed of `10 m/s` (real breaks land 8–12 m/s) is the cap, and it is stated as a **speed** so it survives a scale change: `J = power × Ball.mass × CueSpec.power_cap_speed_mps` (`≈ 13.6 N·s` at full power at `scale = 2.0` on the `≈1.36 kg` ball; regulation `0.17 kg` gives the same `10 m/s` at `1.7 N·s`). Applied as a single `apply_impulse(J * aim, contact_offset)` in the **cue frame**:

```
right  = aim_flat × UP                       # before elevation
aim    = aim_flat rotated about right by −elevation_deg
up_c   = right × aim                          # "top of the ball" as the cue sees it
contact_offset = −aim·R + (right·spin.x + up_c·spin.y) · R · CueSpec.spin_offset_radius
```

`spin.y > 0` is follow, `< 0` draw, `spin.x` is side; stop/stun are centre-ball at the right distance. Because the impulse is applied off-centre, Jolt derives the angular velocity itself (`ω₀ = |spin| · spin_offset_radius · 2.5 · v/R`, so at `0.35R` full offset the ball starts with 0.88× its rolling spin), and cloth friction turns it into follow, draw and curve: one line of physics, not three special cases. `|spin_offset| > miscue_threshold` is a miscue — power scaled by `0.35 [tune]`, aim scattered by `4° [tune]`.

**Jump** requires `jump_unlocked`, `power ≥ 0.70 [tune]` and `elevation_deg ≥ 30`; the elevated aim vector simply has a downward `Y` component, and the hop is Jolt's response to hitting a sphere above centre against the cloth. **Massé** requires `masse_unlocked`, `elevation_deg ≥ 45 [tune]` and `|spin_offset| ≥ 0.60`; the curve emerges from sidespin plus cloth friction. No scripted "curve bias" term exists in either case. A locked technique does not fail the shot: `Ball.strike` clamps elevation to `29°` without `jump_unlocked` and to `44°` for a ≥0.6 spin without `masse_unlocked`.

### Cloth, cushions, rails
Sliding friction is Jolt's (`cloth_friction`): a struck ball slides until its contact point stops, then rolls — that phase is where follow, draw and side do their work. Rolling resistance is ours, Coulomb-like (magnitude independent of speed):

```
F = −v̂ · m · g · μ_r                              central, opposing travel
τ = −(UP × v̂) · (2/5) · m · R · g · μ_r           opposing the rolling axis, so ω slows in step with v (I = 2/5 m R², α = a/R)
τ_z = −ω_normal · m · R · μ_r · spin_decay        english about the table normal bleeds off faster than roll
```

At `μ_r = 0.035` that is `0.34 m/s²`: a ball rolling at 1.5 m/s stops in `≈2.6 m` and `3.7 s` (probe), a 2 m/s ball in one and a half table lengths. **Gotcha (v0.0.1 "ice"):** applying the resistance *force at the contact point* (`τ = r_contact × F`) spins the ball **up**, not down — Jolt's contact friction then pushes it forward and the ball never stops. The torque must oppose `UP × v̂`.

Cushions shed tangential velocity by `cushion_friction` (Jolt), and reflect normal velocity by a restitution that **falls with impact speed** — a design ruling, not a measurement: soft hits mirror, hard hits deform the rubber and come off flat.

```
e(v_n) = lerp(e0, e_min, clamp((v_n − v_soft) / (v_hard − v_soft), 0, 1))
         e0 = cushion_restitution 0.86, e_min = 0.20, v_soft = 3.0 m/s, v_hard = 7.5 m/s   [tune]
tan(θ_out) = e(v_n) · tan(θ_in)        θ measured from the cushion face, tangential speed retained
```

| 45° into a long rail | v_n | e | θ_out |
|---|---|---|---|
| soft (< 50 % power) | ≤ 3 | 0.86 | ≈ 41° (probe: 46°, sliding phase adds a little) |
| 75 % power (7.5 m/s) | 5.3 | 0.52 | ≈ 27° |
| max (10 m/s) | 7.1 | 0.27 | ≈ 15° (probe at 9 m/s: 30°) |

Mechanically: the rail material is `absorbent` with `bounce = ball_restitution − e0`, so Jolt bounces at `e0`; `Ball` catches `body_entered` from a body carrying `rail_normal` meta, stores the inward normal, and on the **next** `_integrate_forces` rescales the leaving normal component by `e(v_n)/e0` with `v_n = v_out/e0`. Next tick, because `body_entered` fires pre-solve for discrete contacts and post-solve for CCD ones. Both `e0` and `cushion_friction` are `PhysicsSim`-modifiable so 03's `glass_cushions` is a value change, not a code path. Every rail shape carries `rail_id` (countable `RAIL` contact) and `rail_normal`.

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
- `src/gameplay/table/Table.tscn` — `StaticBody3D` bed, rail shapes each carrying `rail_id`, per-pocket angled jaw stubs + a tall drop-zone `Area3D` chute, and a **`PhysicsSim` child node** that owns the live modifier stack. `table.gd` only orchestrates: `table_geometry.gd` derives a `TableLayout` from the `TableSpec`, `table_builder.gd` turns that into bodies, `table_visuals.gd` turns it into meshes. `PhysicsSim` is *not* an autoload and there is no global `Signals` bus; listeners connect directly to the node that emits.
- `src/gameplay/balls/Ball.tscn` — `RigidBody3D`, `continuous_cd`, `contact_monitor`, mesh, `SphereShape3D`.
- `src/gameplay/cue/CueController.tscn` — consumes a `ShotIntent`, renders aim arc / power / spin cursor. Input device is the Player module's problem.
- `src/gameplay/round/RoundDirector.gd` — child of `MainLevel`; owns the rack, the shot state machine, the contact log, scoring and the signals below.

### Physics modifiers
`PhysicsSim` is a **stat sink, not a timer stack**. 03's `EffectManager` resolves every stat (base → ADDs → MULs) and owns all timers (Shot / Round expiry); it pushes the *resolved* value with host-only `PhysicsSim.set_stat(stat, value)`: `cue_ball_mass_mult`, `cloth_friction_mult` (scales rolling resistance, slide friction and the bed's contact friction), `cushion_restitution_mult`, `table_tilt_deg` (+ `set_tilt_direction(Vector2)`), and per-rail `set_rail_restitution_mult(rail_id, mult)`. Per-Shot stats (`cue_power_mult`, `cue_spin_radius_mult`) are pulled at strike through `stat_source(stat, peer_id, base) -> float`. The resolved cushion `e` is clamped to ≤ 1.0 (a glass cushion never adds energy). Tilt is a constant force along `tilt_direction` on **moving** balls only; a ball at rest stays put. Nothing writes `TableSpec`. Pocket stats are RULES' (wave 2). Plus `PhysicsSim.nudge(...)` as above, which also emits `nudged` so `RoundDirector` logs the `NUDGE` entry.

### Rolling resistance, rest, CCD gate, cushion rescale — one function
`Ball._integrate_forces` (implemented, `src/gameplay/balls/ball.gd`) does exactly four things in order: apply a pending `rail_normal` rescale, snap to rest below `rest_speed_mps` / `0.15 rad/s` (then `is_resting = true` and `rested` emitted, deferred), gate `continuous_cd` on `ccd_speed_mps` for object balls, then the three rolling-resistance terms above. `up` becomes `sim.surface_normal` when `table_tilt` lands. Keep it ~30 lines (07 §5.2).

`Ball.is_resting` (not Jolt's own `sleeping`) is the source of truth for "at rest": a ball with an *active contact* (resting in the pocket-throat sense, or just sitting on the cloth) can go a long time — far longer than `rest_time_sec` — without Jolt's own sleep threshold ever tripping, and `sleeping` genuinely never flips for some resting configurations. `is_resting` is ours, set the instant `rest_speed_mps` is met and cleared on `strike()`; `PhysicsSim` counts `awake` from it, never from `sleeping`.

### PhysicsSim
Child of `Table`; `register(ball)` wires `struck` / `resting_changed` / contacts, and gives the ball its wire `net_id` and `BallMotion.Params`. On strike: `contact_monitor` on for every ball, tick `120 Hz` (`LIVE_TICK`, the one tick constant), `shot_started`, and the host starts the event stream (04 §2.4). When the awake count (from `Ball.is_resting`) hits zero: final rest events flushed, `contact_monitor` off, tick `60 Hz`, `all_resting` — the shot boundary of 07 §1.3 and the idle downclock of 07 §7.2. Exposes `Game/AwakeBalls` (removed in `_exit_tree`: a monitor callable left behind corrupts the heap at quit), `get_balls()`, `request_shot(intent)` (any peer; host validates through `shot_validator(peer_id, intent) -> StringName`, then strikes with `active_cue` (a CueSpec; RULES sets it at Round setup, never taken from a client)), the stat sink above, and the presentation gate `playback_tick()` / `at_playback(tick, fn)`. Clients register balls as kinematic puppets (`Ball.set_client_mode`) and never run Jolt on them.

### Signals (emitted by `RoundDirector`, connected directly)
- `ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)` — the pocket id is what lets 02 score which `Camera` had the shot; `Table.get_pocket(pocket_id) -> PocketSpec` gives it the world position for the distance + occlusion test (P2).
- `shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)`
- `trick_detected(trick: TrickShot, shot_id: String)`
- `table_cleared(round_id: String)`
- `shooter_changed(peer_id: int)` — whose Turn it is; `RoundDirector.current_shooter_id` rotates by `NetManager.seat_order()` after every `shot_ended` (04 `set_shooter`). `PhysicsSim.shot_validator` (installed here) rejects out-of-turn, mid-shot, no-Round, bad power/aim requests.
- `cue_respawned(reason: StringName)` — `scratch | wedged | off_table`; the cue ball was put back in the kitchen before `shot_ended` (wedged costs nothing, HUD only)

### File paths under `src/`
`gameplay/table/TableSpec.gd`, `gameplay/table/table_geometry.gd` (`TableGeometry`, pure `layout()`), `gameplay/table/table_layout.gd` (`TableLayout` data, incl. `RailSegment`), `gameplay/table/table_builder.gd` (`TableBuilder`, bodies), `gameplay/table/table_visuals.gd` (`TableVisuals`, meshes), `gameplay/table/PocketSpec.gd`, `gameplay/table/PhysicsSim.gd`, `gameplay/balls/BallType.gd`, `gameplay/balls/BallTypeOverride.gd`, `gameplay/balls/Ball.gd`, `gameplay/cue/CueSpec.gd`, `gameplay/cue/CueAim.gd`, `gameplay/round/RoundDirector.gd`, `gameplay/round/ContactLog.gd`, `gameplay/round/ShotScoring.gd`, `gameplay/round/TrickShotDetector.gd`, `gameplay/round/PoissonDrop.gd`. Demo-only until the Player module lands: `gameplay/cue/cue_controller.gd` (spin cursor I/J/K/L, elevation Q/E, reset C; reach and pullback follow the struck ball's own `cue_reach_m`/radius, no metre literal) and `gameplay/cue/spin_disc.gd` (HUD); `resources/cues/demo_cue.tres` has jump and massé unlocked and is `cue_controller.gd`'s own `@export` default. `tools/spec_dump.gd` (headless, prints the table pasted into §2 above) and `tools/screenshot_table.gd` (headless-launched with a real GPU context, not `--headless`; saves a PNG of the built table from a player-height view).

### Physics test fixtures (`tests/physics/`, headless)
The cheapest insurance in the plan — each is a scripted `ShotIntent` against a fixed rack, asserted on outcome. `tests/physics/probe.gd` (`godot --path . --headless -s tests/physics/probe.gd`) is the first cut: roll-out distance and rest time, cushion angle soft vs hard, draw returns / follow passes, straight-in pot, jaw hit (never tunnels/leaves the table), full-power rail return, cue reach limit. `tests/physics/geometry_probe.gd` checks `TableGeometry.layout()` alone, headless and scene-free: pocket/rail/sight counts, spots, and every derived `TableSpec` value against `REG_* × scale`. Gotcha for every fixture: a GDScript lambda captures locals **by value** — signal handlers must set a member, not a local.
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
*Ruled 2026-09-30 (06 P8):* `bomb_ball` scatters its neighbours and removes only itself (no fragments); `split_ball` spawns one `red_basic` per pot, not per carom; no "house" pocket; `stone_ball` counts toward the `≤ 12` ball cap.
- Jaw restitution `0.55` decides how often shots rattle; that is a feel dial — who owns it after the first playtest, 01 or 03?

## 7. MVP cut vs later

**MVP.** Jolt `RigidBody3D` sim at a validated tick rate with CCD on every ball. Cue impulse, spin offset, miscue, and the `ShotIntent` boundary. Jaw-cylinder pockets with drop planes. Rolling resistance in `_integrate_forces`. Foul rule with kitchen respawn. Three value tiers plus `black_penalty` plus `stone_ball`; gimmick balls stubbed as buyable but only `bomb_ball` implemented. All five tricks with the disjointness rule. Poisson-disk drop with a visible seed and the two authored racks. `CueSpec` read from the shop, `BallTypeOverride` resolution. Stuck-state rule. All four signals. Fixtures 1–4 and 6 green before any netcode work starts.

**Later.** `split_ball` and `joker_ball` behaviours. Table bump/tilt tuning past the raw hook. Shot ghost previews and spin visualisers. Adaptive layout difficulty by `Round`. Same-machine replay playback from intents. A second table with different `TableSpec` values as a shop item.
