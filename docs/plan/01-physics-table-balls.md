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
| `Ball.continuous_cd` | cue ball always; object balls only above `ccd_speed_mps = 0.8·R·LIVE_TICK = 5.5 m/s` (derived, 07 §1.2) | a 20 m/s break is 167 mm per 120 Hz tick against a 114 mm ball diameter — tunneling is certain without it; see "Speed ceiling" (§3) for the whole guard |
| `Ball.contact_monitor` / `max_contacts_reported` | on only during a live `Shot` (`PhysicsSim`) / `8` cue, `6` object | the contact log is the only input to trick detection |
| `Ball.mass` | `0.17 kg × (R / 0.0286)³` | regulation density; at `scale = 2.0` the ball is `≈1.36 kg` |
| friction | ball material `0.06 [tune]`; cloth `0.20 [tune]`, cushion `0.18`, jaw `0.6` all `rough = true` | combine rule is **MIN unless one side is `rough`**, so ball–ball gets the ball's value and ball–table gets the table's |
| restitution | ball material `TableSpec.BASE_BOUNCE = 1.0`; table bodies `absorbent = true` with `bounce = 1.0 − e_wanted` | Jolt **sums** the two bounces (clamped to 1) and an `absorbent` side subtracts, so cloth is 0, a cushion is `e0`, a cup `cup_bounce`. Ball–ball under that rule is always 1 (measured: bounce 0.3 + 0.3 → e 0.6, 0.5 + 0.5 → 1) — `ball_restitution` (0.97) is applied by `BallCollisions`, not by Jolt (§3 "Ball–ball impacts"). Ball–ball at 0.05 was the v0.0.1 stun bug: cue ball kept 47% of its speed |
| `physics/jolt_physics_3d/simulation/bounce_velocity_threshold` | `0.2` | Jolt default `1.0` kills restitution on slow rail hits — a soft ball slid along the cushion |
| `physics/jolt_physics_3d/limits/max_angular_velocity` | `600` | default `47 rad/s` is below pure rolling at 2 m/s on this ball |
| `physics/jolt_physics_3d/simulation/sleep_*` | velocity `0.05`, time `0.3` | 07 §1.3; Jolt's own sleep can take far longer than that for a body still in resting contact (or never trip), so `Ball.is_resting` — not `sleeping` — is what `PhysicsSim` counts (see "Rolling resistance, rest..." in §4) |
| `physics/common/physics_interpolation` | `true` | 07 §1.5–1.6; `max_physics_steps_per_frame` was removed (T1.1 WIP) so a slow frame reruns its full backlog instead of dropping ticks |
| cue speed | `mass × CueSpec.speed_at(power)`, `speed_at(1) = power_cap_speed_mps = 20` | derived in §3; a speed is scale-invariant, an impulse is not. Ceiling for any ball: `TableSpec.max_ball_speed_mps = 24` (§3 "Speed ceiling") |
| rolling resistance | custom force + torque in `_integrate_forces`, `0.025 [tune]` | Jolt has no rolling-resistance term |
| damping | `linear_damp` / `angular_damp` per ball, replace mode, `TableSpec.ball_linear_damp` / `ball_angular_damp = 0` | Godot's project default is **0.1 /s on both**, hidden in no file: a speed-proportional drag no real ball has, 0.5 m/s² at 5 m/s on top of the 0.25 of the rolling term (adhoc-1012a) |
| pockets | angled jaw stubs (part of the rail ends) + a **hole cut in the bed** at every pocket with a cup under it (06 P30) | a ball falls in under gravity; rattle and reject-at-speed emerge; `pocket_capture_speed_mps` is deleted |
| rail shapes | per-shape metadata `rail_id: StringName` | so the contact log can tell a rail from a ball from a jaw |

**Tick budget (P1).** 240 Hz is a hypothesis, not a decision: it is validated by 04's M0 spike (12 balls, max-power break, 60 fps sustained, physics step ≤ 8 ms on the target phone). If the spike misses, drop to 120 Hz and keep CCD — the visible cost is slightly softer cushion rebounds, not tunneling. Ball count per `Round` is capped by that budget at **≤ 12 balls total including the cue ball `[tune]`**; 02's "10 object balls" fits with headroom.

### TableSpec (Resource)
**Scale ruling (v0.0.3, plan.md `adhoc-wip-table-ball`):** every geometric value is a `REG_*` regulation constant (9-ft WPA table) times a single `scale` knob, default **2.0** — balls read clearly bigger and the table reads big in first person. `bed_height_m` is the one exception: it is **player-relative, not scale-relative** (real bed height × scale reads chest-high on a real-height player; `06` P-ruling). Mass follows radius³ (constant density) and the cue is a speed cap, so the physics formulas never see the scale.

`TableGeometry.layout(spec) -> TableLayout` derives all of this into plain data — pockets and their **holes**, rail segments (with their angled corner/side facings), spots, sights, the bed outline and its convex pieces — with no scene nodes, so it is headless-testable (`tests/physics/geometry_probe.gd`). `Table` (`table.gd`) calls it and hands the result to `table_builder.gd` (bodies/collision) and `table_visuals.gd` (meshes) — spec data, pure geometry and scene construction are three separate files, per `06`/`04`'s architecture split.

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
| `cushion_restitution_min` | 0.38 |
| `cushion_soft_speed_mps` | 3.0 |
| `cushion_hard_speed_mps` | 14.0 |
| `cushion_friction` | 0.18 |
| `cloth_friction` | 0.2 |
| `ball_friction` | 0.06 |
| `ball_restitution` | 0.97 |
| `ball_cascade_enabled` | true |
| `rolling_resistance` | 0.025 |
| `spin_decay` | 0.77 |
| `settle_speed_mps` | 0.3 |
| `settle_boost` | 1.5 |
| `spin_stop_rad_s2` | 4.0 |
| `tilt_max_vs_roll` | 2.8 |
| `ball_linear_damp` | 0.0 |
| `ball_angular_damp` | 0.0 |
| `rest_speed_mps` | 0.02 |
| `rest_ang_rad_s` | 0.15 |
| `rest_time_sec` | 0.3 |
| `cup_friction` | 0.02 |
| `cup_bounce` | 0.1 |
| `clearance_margin_m` | 0.003 |
| `jaw_restitution` | 0.55 |
| `ccd_step_radii` | 0.8 |
| `ccd_speed_mps` | 5.4864 |
| `max_ball_speed_mps` | 24.0 |

Derived getters at the default `scale = 2.0` (`REG_* × scale`, `bed_height_m` excepted):

| getter | value | formula |
|---|---:|---|
| `length_m` | 5.08 | REG_LENGTH × scale |
| `width_m` | 2.54 | REG_WIDTH × scale |
| `ball_radius_m` | 0.05715 | REG_BALL_RADIUS × scale |
| `corner_mouth_m` | 0.32 | REG_CORNER_MOUTH × scale (tip-to-tip nose gap, 2.8 D) |
| `side_mouth_m` | 0.32 | REG_SIDE_MOUTH × scale (2.8 D) |
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

`cushion_restitution_min` was retuned from 0.20 to 0.26 during the scale-2.0 pass (T1.7): at 0.20 a full-power head-spot shot lost too much energy off the foot rail to return half the table, and 0.35 made the hard-vs-soft cushion angle too close (`tests/physics/probe.gd` gates both). adhoc-1013c W2 (the 20 m/s break) moved it to **0.38** and `cushion_hard_speed_mps` from 7.5 to **14**: with the old curve a 15 m/s ball left the cushion at 4 m/s, so a break died at the first rail; now it leaves at ~6 (§3 "The break"). The probe's hard hit is 20 m/s (14.1 along the normal) so the gate still reads the flat end of the curve.

### Pocket geometry
Each pocket is a `PocketSpec { id: StringName, position: Vector3, mouth_normal: Vector2, mouth_width_m }`. **Mouth** = the tip-to-tip gap between the two cushion noses at the pocket, what a player sees (06 P30): `REG_CORNER_MOUTH` and `REG_SIDE_MOUTH` are both `0.160` ≙ **2.8 ball diameters**, past regulation on purpose (reg. ≈ 2.06 D corner / 2.27 D side); the floors are corner ≥ 2.5 D, side ≥ 2.7 D at every scale (`tests/physics/pocket_probe.gd`). A corner rail is cut `c = mouth/√2` short of the nose corner on each axis, a side rail `mouth/2` from the pocket axis.

**The hole.** `TableGeometry.layout` gives every pocket a `TableLayout.Hole`: a circle round `PocketSpec.position` (one ball radius outside the nose corner / nose line) whose rim passes exactly through the two cushion tips. The bed is the nose rectangle minus these circles: `layout.bed_outline` is one simple polygon (the arcs inside the rectangle are cut out of its perimeter, ~1 ball-radius edges), `layout.bed_pieces` its convex decomposition (`Geometry2D.decompose_polygon_in_convex`, ~21 pieces). `table_builder.gd` builds the bed as flat convex prisms in **one** `StaticBody3D` — never a trimesh, so Jolt's internal-edge removal keeps seams invisible to a rolling ball and the roll-out / cushion / draw-follow numbers of `probe.gd` are identical to the pre-hole table (1.5 m/s roll 2.56 m in 3.6 s, cushion 46.4° / 35.2°, draw −0.22 m / follow +0.18 m). `table_visuals.gd` cuts the cloth along the same outline (visual only: each arc's two ends run `2 x bed_thickness_m` on into the cushion, so no seam is a bare edge contact, 07 §2). At 1.0× the hole is `0.289` m (corner) / `0.170` m (side) in radius at scale 2.0 and reaches `radius − R` inside the nose line at the pocket axis (1.9 R at a side pocket): a ball whose centre crosses the nose line inside the mouth is already over it. The angled facings are unchanged (they still narrow a side pocket's throat to ≈ 1.6 D past the tips), so rattle and reject-at-speed stay.

**The rail round a pocket (visual, adhoc-1013c W1).** The wood is one continuous frame: each rail block and apron is an extruded polygon (`TableVisuals._wood_slab`) and the pockets are *cut out of it* — the hole's ring grown `bed_thickness_m / 2 + 2 mm`, which stands just behind the liner wall, so from the pit you see the dark liner up to rail-top height and from above a wooden rail top round the opening. A corner's blocks run out to the table's outer footprint; the two halves of a side rail run on past the pocket axis and overlap there, so the side pocket is a round cut in an unbroken rail, not a notch behind a liner with no top. A ring never reaches the outer footprint (`EDGE_INSET`), so a corner pocket keeps a hair of wood at its two extreme points. Nothing here is collision: the cup and its back wall are the ball's pocket, the wood is dressing. `tests/physics/table_top_probe.gd` is the check (rail top everywhere outside the cuts, no wood or cloth over a pit).

**The cup.** Under each hole hangs `Cup_<id>`: a floor `cup_depth_m` (5 R ≥ 2 D) below the cloth, a thick wall round the ring from floor to just under the slab (the slab's own rim is the wall above that, so no cup top sits on the playing surface — a second body's coplanar edge is a ghost bump), and on the arc *outside* the nose rectangle a back wall (4 R above the cloth) that starts two arc segments past each cushion tip. Felt-like: friction `0.02`, restitution `0.1` (a spinning ball hitting a grippy wall climbs it — found at 8 m/s into a corner), thickness floored at the step-safe minimum as for the cushions, so a 3 m/s ball cannot skip across and a 9 m/s one cannot tunnel. A `SafetyFloor` still catches anything that falls through a gap rather than a pocket.

**Pot rule (06 P30).** A ball is potted when its **centre is inside the hole and `pot_depth_m = 1.5 R` below the cloth top** — not at the lip, never while it is on or above the cloth. Implemented as one `Area3D` cylinder per cup (`Drop_<id>`, monitored only while balls are awake, as before) whose top plane sits `pot_depth_m + R` under the cloth, so the ball's own sphere touches it exactly when its centre is `pot_depth_m` down; `Ball.pocket()` then fires (`POCKETED`) and `RETIRED` follows `Ball.POCKET_SETTLE_SEC = 0.4 s` later, the ball seen dropping and settling in the cup meanwhile. A ball inside any hole circle is never "off the table" (`RoundDirector._is_off_table`). A ball that drops **between** shots (a hole that grew or moved under a resting ball) scores nothing and costs nothing: `RoundDirector._return_stray` puts it back on the cloth (the cue ball in the kitchen, as `wedged`).

**Moving the real hole (03 `pocket_radius_mult`, `pocket_oscillation_m`).** A new `pocket_radius_mult` re-lays the cushion tips and the hole with them (`Table.rebuild()`); every resting ball near an old or new hole is thawed first, so the changed support drops it instead of leaving it hovering. Moving Pockets (amplitude `A`) cuts the bed hole `A` wider than the opening and lays a kinematic `Cover_<id>` (`AnimatableBody3D`) over it: an annulus whose inner circle *is* the opening, outer radius `radius + 2A + 2 cm`, top 1.5 mm above the cloth and ramped down at its rim (never coplanar with the bed), friction 0 so a resting ball is not dragged along. `Table` slides it along the rail on `PhysicsSim.pocket_time()` (host `_physics_process`, clients `_process`; `Table.pocket_offset(seed, id, t, A)` is the pure function), the cup and sensor stay put, and a frozen ball the opening reaches is released (`_release_balls_over_openings`). The cover shares the cloth material, so a `BarSkin` felt recolours it too.

**Client drop.** The shared `BallMotion` model puts a ball below the cloth plane into free fall onto `cup_floor_y` (`BallMotion._drop`), and a pocketed ball's floor is the cup floor; the divergence stream (`> 2 mm` Jolt vs model) therefore carries the lip crossing, the cup walls and the landing without a new codec flag or RPC (`tests/sync/pocket_pair_probe.gd`: the client sees the ball below the cloth before the pot flag, hidden only once well below it, no frame-to-frame jump above 0.25 m).

The corner rail truncation no longer carries an extra ball radius (the old `+R` margin was for a mouth measured on the diagonal); the straight-in and seam probes in `tests/physics/probe.gd` hold it.

A pot is the ball reaching the cup (above), and nothing else. Rattle (ball bouncing between jaws and staying up), reject-at-speed (fast ball hitting the far jaw and coming back out) and the pocket-cut asymmetry all fall out of the jaw collisions for free. There is no speed test and no capture cone; `pocket_capture_speed_mps` is deleted.

Jaw/cushion/cup-wall collider thickness is floored against `TableSpec.max_ball_speed_mps` (24.0 since adhoc-1013c W2, scale-invariant, 20% above `CueSpec.power_cap_speed_mps`) ÷ `PhysicsSim.LIVE_TICK` (200 mm; it was 83 mm at 10 m/s), not just `ball_radius_m`/`jaw_radius_m` — those shrink at a small `scale` while a ball's absolute cue-power-cap speed never does, so the collider-vs-per-step-travel ratio that protects against tunnelling gets worse the smaller the table (loop 1, gamma H: a 9 m/s ball into a side jaw stayed on a scale-2.0 table but tunnelled/launched off a scale-1.0 one). That floor alone did not fully close it: Jolt can still resolve a fast, high-spin ball's contact right where a cushion ends and a facing begins (or where the ball, still slightly airborne from one such contact, comes down almost level with a cushion's own short top edge) with several m/s of spurious *vertical* speed and, in the worst observed case, an almost-vertical contact normal — reproducible with CCD on, at 4× the tick rate, and with collider thickness well above the floor, so it is a Jolt contact-generation artifact at that specific geometry, not a tunnelling/step-size problem. `Ball._integrate_forces` treats every cushion/jaw hit as what it geometrically is — a purely horizontal contact normal — and restores the vertical speed it itself produced the tick before, but only on the first physics step of a new contact (a ball still touching a jaw several steps into the same contact, e.g. settling into a corner pocket, keeps integrating normally, or it could never actually fall).

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

**Gimmick behaviour (built, `RoundDirector`).** `bomb_ball`: a contact whose relative pre-impact speed is ≥ `3.0 m/s [tune]` sets it off — every ball within `14` radii gets a horizontal kick of `3.0 m/s [tune]` × linear falloff, the bomb retires itself (no score, not a pot, ignored by the clear test). `split_ball`: after the Shot resolves, each potted split spawns one `red_basic` at its rest spot (nearest clear spot otherwise), respecting the 12-ball cap; clients spawn it at the Shot's playback end (`_spawn_rpc`). `joker_ball`: `wild` — see Scoring. `stone_ball`: 3× mass, never scored; when it is in a Night's pool one is placed per rack (`STONES_PER_RACK`) and it counts toward the 12 cap (`RackDropper.rack_size`). Each unlocked gimmick appears once per rack.

**Authored racks.** `NightConfig.authored_racks: Array[RackLayout]` (index = Round − 1; missing = seeded drop). A `RackLayout` is `type_ids` + `positions`, fractions of the playfield interior's half-extents in [-1, 1] so it survives any `TableSpec.scale`. Night 1 ships three as `authored_racks` and Night 3 three as `finale_racks` (`racks/n1_r*`, `racks/finale_r*`; `GameLoop._start_round` plays the finale ones only in Campaign mode, 02 §3.4); `tests/round/rules_probe.gd` checks exact positions, spacing, pocket-hole clearance and — **06 P31** — that the black ball sits on the centre slot (N1 Round 1: the middle ball of the triangle's third row).

**Shop overrides (P3).** The gimmicks are not unlocked on a schedule — the player buys the order from the Bartender shop that 02 owns. Ball purchases are `BallTypeOverride { ball_type_id, unlocked: bool, base_value_override: int }` resources; 02 hands `RoundDirector` the active override set at `Round` setup and 01 resolves `value(ball_type) = override.base_value_override if set else ball_type.base_value`. Nothing in 01 mutates a `BallType` resource in place, so a tier-value upgrade is one row of save data, not a migration.

### CueSpec (Resource) and the cue API
The cue is a shop item too (P3), so its limits are data, not constants:

| field | default | upgrade does |
|---|---|---|
| `power_cap_speed_mps` | `20 m/s [tune]` (10 before adhoc-1013c W2) | raises the top of the power curve, up to `×1.2` (the 24 m/s ceiling, `TableSpec.max_ball_speed_mps`) |
| `power_top_boost` | `0.5 [tune]` (0..1) | the cubic share of the power curve (below); not upgraded |
| `spin_offset_radius` | `0.35 [tune]` (fraction of ball radius) | more english before a miscue, up to `0.50 [tune]` |
| `jump_unlocked` | `true` (from the start; adhoc-1014a V4: the `jump_cue` shop item is now the Massé cue) | enables jump intent; a cue without it clamps the elevation to 29° |
| `masse_unlocked` | `false` | enables massé intent |
| `wobble_reduction` | `0.0 [tune]` (0..1) | scales 03's `aim_wobble` Effects by `(1 - wobble_reduction)`, floored at 0 |
| `miscue_threshold` | `0.92 [tune]` | fraction of `spin_offset_radius` past which the strike miscues |

The Player module is still deferred and stays a black box. It produces exactly one struct, and 01 never asks where it came from — mouse, touch drag, gamepad or a replay file are indistinguishable at this boundary (P1):

`ShotIntent { aim_dir: Vector2, power: float (0..1), spin_offset: Vector2 (unit disc), elevation_deg: float, jump: bool, masse: bool, shooter_id: int }`

**Power curve.** `CueSpec.speed_at(p) = power_cap_speed_mps × lerp(p, p³, power_top_boost)` (`power_top_boost` 0.5): half of the slider is the old linear 10 m/s feel (`p = 0.25` → 2.7 m/s, `0.5` → 6.3, `0.75` → 11.7) and the top spends the doubled cap — a full charge is 20 m/s (adhoc-1013c U12: "the force I'm able to output is still too low on a full charge break"). A plain doubling of the linear cap would have made every half-charge touch shot twice as fast.

### Shot and the contact log
`Shot { id: String, shooter_id: int, intent: ShotIntent, seed: int, contacts: Array[ContactEvent] }`. A `Turn` is one `Shot`; only **one `Shot` exists at a time** (P2) — free-roaming friends never get a second cue ball, so shot boundaries, trick attribution and camera framing all survive intact.

`ContactEvent { tick: int, kind: enum {BALL, RAIL, JAW, POCKET, NUDGE}, a: String, b: String, rail_id: StringName, pocket_id: StringName, position: Vector3, impact_speed: float }`, appended in tick order. This ordered log is the *only* input to trick detection and foul detection — no per-trick state machines.

## 3. Rules/formulas

### Shot lifecycle
A `Shot` opens on cue contact and closes when every ball satisfies `speed < rest_speed_mps` and `angular_speed < 0.15 rad/s [tune]` continuously for `rest_time_sec`. Hard ceiling `12 s [tune]`: past it, balls are frozen and the shot resolves anyway. A `Round` runs until its timer expires, its shot budget is spent, or `table_cleared` fires.

### Cue impulse, derived
Impulse is momentum: `J = m · Δv`. A top break speed of `20 m/s` is the cap (real breaks land 8–12 m/s; this table is 2× regulation and the user asked for chaos, adhoc-1013c U12), and it is stated as a **speed** so it survives a scale change: `J = Ball.mass × CueSpec.speed_at(power)`, clipped to `TableSpec.max_ball_speed_mps` (`≈ 27 N·s` at full power at `scale = 2.0` on the `≈1.36 kg` ball). `Ball.plan_strike` is the one place this is computed — `Ball.strike` (host) and the shot guide (below) both call it. Applied as a single `apply_impulse(J * aim, contact_offset)` in the **cue frame**:

```
right  = aim_flat × UP                       # before elevation
aim    = aim_flat rotated about right by −elevation_deg
up_c   = right × aim                          # "top of the ball" as the cue sees it
contact_offset = −aim·R + (right·spin.x + up_c·spin.y) · R · CueSpec.spin_offset_radius
```

`spin.y > 0` is follow, `< 0` draw, `spin.x` is side; stop/stun are centre-ball at the right distance. Because the impulse is applied off-centre, Jolt derives the angular velocity itself (`ω₀ = |spin| · spin_offset_radius · 2.5 · v/R`, so at `0.35R` full offset the ball starts with 0.88× its rolling spin), and cloth friction turns it into follow, draw and curve: one line of physics, not three special cases. `|spin_offset| > miscue_threshold` is a miscue — power scaled by `0.35 [tune]`, aim scattered by `4° [tune]`.

**Jump** (adhoc-1014a V4; unlocked from the start) requires `jump_unlocked`, a slider `power ≥ Ball.JUMP_MIN_POWER = 0.40 [tune]` and `elevation_deg ≥ 30`. The ball really hops: the cue drives it into the cloth and the cloth answers. `Ball.Plan.launch` is that answer, the one number set both sides read: the velocity and spin the impulse gives, then `BallMotion.cloth_impact` — Coulomb friction at the contact point works the slip for as long as the impact lasts (`μ·|vy|`, or what stops the slip, `u/3.5`), and `BallMotion.JUMP_E = 0.45` of the downward speed comes back up (capped at `JUMP_VY_MAX = 3 m/s`, so the apex never passes 0.46 m). `Ball.strike` fires exactly that state (a central impulse and a torque impulse) instead of leaving the downward cue to Jolt's dead cloth (`BASE_BOUNCE` cancels the cloth's bounce, §2; a flat or sub-threshold elevated stroke still gets that dead cloth: no hop, a ball that rolls faster forward). The part of the slider from `0.40` to `1.0` is spread over `JUMP_MIN_POWER..JUMP_TOP_POWER = 0.40..0.65` of the cue's own power curve (4.6 to 9.2 m/s on the stock cue; a full-power jump is not a leap off the table). Stock cue, 45° / 60°: slider 0.40 hops 0.11 / 0.17 m high for about 1 m; slider 1.0 hops 0.44 / 0.46 m high for about 3.9 / 2.8 m. One object ball is 0.114 m: a 60° stroke at the bottom of the range (slider 0.40, 0.17 m) clears it; 35° at 0.45 (77 mm) does not.

**Flight** (S3 airborne rule, adhoc-1014a): a ball is airborne when its centre is more than `BallMotion.AIRBORNE_EPS = 3 mm` over the cloth (`BallMotion.is_airborne(y, rest_y)`), or when it leaves the cloth faster than `AIR_VY` (0.25 m/s) or comes down on it faster than `Ball.FLIGHT_VY` (0.5 m/s). While it is, **no cloth friction, spin decay, tilt, water/sand or other ground term acts on it** (`Ball._integrate_forces` returns early; `BallMotion._fly` has none), and pins and rails collide only if the ball's centre is below their top. Jolt integrates the velocity before the position, which flies the true parabola of `lin.y − g·dt/2`: `BallMotion._fly` draws that one (`TICK_DT = 1/120`), so a hop agrees with Jolt to 0.7 mm over half a second and not 2 cm low. **The last `TOUCHDOWN_H = 3 cm` of a descent are the model's, not Jolt's**: Jolt's speculative contact takes a falling ball's speed away a few millimetres before the cloth and its landing is dead, so `Ball._air_step` runs that step on `BallMotion.advance` (friction at the contact point, then `LAND_E = 0.4` of the speed back up when that is over `MIN_HOP_VY = 0.30` m/s, then the roll) and puts the result in place when Jolt has run the step (`_forced`). Over a pocket's mouth, a cushion or a rail, or when another ball or a cushion shares the step, Jolt's own solve stands. A ball that comes down in a pocket's mouth falls into it like any other, and the pot sensor (a cup cylinder `pot_depth_m` under the cloth, §Real pockets) never sees a ball that is in the air. The vertical state needs **no codec change**: `BallEventCodec` already carries `pos.y` (s16, 0.1 mm, ±3.27 m about the table origin; a hop is under 0.5 m) and `lin.y` (s16, 1 mm/s, ±32.7 m/s; a hop launches at ≤ 3 m/s, the 24 m/s ceiling fits), and the host's divergence rule (`DIVERGE_M`, 2 mm) covers whatever the model does not draw: a hop streams 2-13 events. `Ball.effective_elevation` clamps to `Ball.MAX_ELEVATION_DEG = 80`: the host does not trust the wire for it.

**Massé** requires `masse_unlocked`, `elevation_deg ≥ 45 [tune]` and `|spin_offset| ≥ 0.60`; the curve emerges from sidespin plus cloth friction. No scripted "curve bias" term exists in either case. A locked technique does not fail the shot: `Ball.strike` clamps elevation to `29°` without `jump_unlocked` and to `44°` for a ≥0.6 spin without `masse_unlocked`. The clamp is `Ball.effective_elevation(deg, spin, cue)`, and the touch cue-angle overlay (08 §2.8) asks the same function, so it shows the angle the ball gets.

### Shot guide and the cue tip (`ShotModel`, `ShotGuide`; adhoc-1013c U13)
While the local player aims (`CueController.active`) the cloth shows where the cue ball will go. **Local shooter only**: it hangs off the local `CueController`; a puppet's cue is the fixed stick (spin is not on the wire, 08 §2.6) and carries no guide.

**The model is the host's own pieces, not a second physics** (`src/gameplay/cue/shot_model.gd`, pure data, `ShotModel.trace(cue, intent, cue_spec, table)`):
- *launch*: `Ball.plan_strike` — speed (`CueSpec.speed_at`, the shooter's `cue_power_mult`, the 24 m/s ceiling, miscue ×0.35 without the random scatter), the swayed aim, the effective elevation, the spin offset with the shooter's resolved `cue_spin_radius_mult` — then `ω = (offset × aim) · speed / (0.4 R²)` from the off-centre impulse. A downward (elevated) cue meets the cloth: the cloth takes the downward speed (`Ball.Plan.launch`: a jump shot gets `BallMotion.JUMP_E` of it back up, see the Jump note; a flat or locked stroke gets none) and Coulomb friction at the contact point (`cloth_friction × cloth_friction_mult`) works on the slip for as long as that impulse lasts, so an elevated stroke leaves faster-rolling and a little slower;
- *every stretch between contacts*: `BallMotion.advance` with the cue ball's own `Params` — the model clients reconstruct the host with, so cloth friction, table tilt, rolling resistance, the settle ramp and every live `TableSpec` number are the host's. Slide, roll, curve (massé: the side spin's horizontal axis component slips the ball sideways until it rolls) and a ballistic arc (jump, when the launch has an upward speed) all come out of it;
- *a ball*: the swept first touch against every resting ball (3-D, so an arc clears a ball it flies over), then `BallCollisions.simulate` on the pair with `ball_restitution` / `ball_friction` and the real masses — the host's resolver — for both balls' velocity and spin;
- *a cushion*: the nose line pushed in by R, within the cushion's span (a mouth is not one; a flying ball whose bottom is above the nose clears it); normal speed × `cushion_restitution_at(approach) × rail_restitution_mult` (hazards: glass cushions) and Coulomb friction on the tangent at `cushion_friction` (sidespin turns the angle), the vertical speed left alone because `Ball._integrate_forces` undoes whatever a wall does to it; the jaw stubs at each cushion end are cushions of their own (`TableBuilder.FACING_LENGTH_RATIO`), and a ball is in a pocket (the line ends) only when its centre is 1.5 R inside the hole's rim or beyond the nose line over the hole: the hole's circle reaches 0.2 m into the playfield, and a ball there is still on its way to a jaw.
Where the hazards and stats live they are read live (the shooter's `cue_power_mult`, `cue_spin_radius_mult`, `cloth_friction_mult`, tilt, rail multipliers): the guide never draws a shot the host would not fire.

**Drawn** (`src/gameplay/cue/shot_guide.gd`, a ribbon `ImmediateMesh`, unshaded alpha, render priority 8, 4 mm above the cloth and 2 mm more per metre from the cue ball so the thin depth buffer far away never fights the cloth): the cue ball's path an **opaque white stripe, 4 cm across (a third of a ball) and widening 30 % per metre from the cue ball** so it keeps a few pixels at the far end on a phone, like the aiming line of a 2D pool game (cyan where it is off the cloth, with a small ring where it first lands; red for a miscue; the arc of a jump has a second strip standing on edge, so it reads from the side, and a dim shadow on the cloth, so it reads from behind), a **solid ghost-ball ring** (1.4 cm wide, opaque, with a faint disc inside) at the cue ball's first touch, an **orange line + arrow** a little thinner than the stripe from the struck ball along its post-impact direction, and the same path again, dimmer (alpha 0.55 fading to 0.2), past the contact (the cue ball past or off the object ball, or the bounce off the cushion). With no power charged it previews at 0.5 (0.7 when the elevation allows a jump, which needs 0.40), at 75 % opacity; the instant a charge starts it follows the real power. It is rebuilt only when an input changed (swayed yaw, power, spin, elevation, the ball, the cloth/tilt/hazard numbers): one draw call in CUE, a few hundred vertices, nothing allocated per frame beyond the mesh itself.

**On the table, in world space** (adhoc-1014a V7: it drew on the ceiling): the ribbon is built in world coordinates and the node is `top_level`, which keeps the transform the node had when it entered the tree, and `CueController` sits under `Player/Head` (1.6 m up, a seat to the side). `ShotGuide._ready` therefore resets `global_transform` to the identity. Visible to the local shooter only, from `CueController.begin` to `end` (hidden the instant the shot fires); layer 12 only, which the mirror's window pass (`Mirror.LAYER | HEAD_LAYER`), its room capture (`ROOM_LAYER`) and the TV feeds (`StreamTv.feed_mask`) leave out. **What the guide ignores:** the rail wood past the cushion (a hop is checked against the cushion's nose only: a ball that lands on the rail top, or flies over the cushion and off the table, is not drawn), a pocket drop and what comes after one, a ball the struck ball hits, a second contact of the cue ball, the hazards that are not stats (pins, water/sand, once they land), the host's random scatter of a miscue, and anything another player does while you aim. It draws the cushion bounce, the first ball and the stretch after it, the object ball's line, the massé curve and the jump arc: nothing the host would not do.

**Length limits.** The first stretch stops at its first contact, at rest, at `6 m` or `8 s`, or off the table (`ShotModel.LEG1_MAX_M`); **one** more stretch follows a contact — the cue ball past a ball, the ball off a cushion — up to `2.5 m` or the next contact (`LEG2_MAX_M`); the struck ball's line runs `1.2 m` or to its first contact (`OBJ_MAX_M`). Jaws, a drop into a pocket's cup, and chains of struck balls are not followed.

**Gate** (`tests/physics/shot_guide_probe.gd`): 80 strokes (aim × spin × elevation 0/25/40/60° × power 0.45/0.85, with the object ball in the line and as a 20° bank), each traced and then struck for real: the same first contact (ball / cushion / none), the contact time inside the host's step ± the tolerance, and the cue ball's path up to the contact within the tolerance of the host's, sampled every physics tick on the physics clock. Tolerance: a flat stroke (no elevation, spin < 0.6) **12 mm / 15 ms**; an elevated, massé or hard-sidespin stroke **40 mm / 40 ms**; the struck ball's direction **6°**. Measured on the 80 strokes (first engine run, adhoc-1013c): flat worst **4.1 mm / 2 ms / 1.6°**, elevated and massé worst **5.5 mm / 34 ms / 1.8°** — the position error is the cloth-friction model's, a few mm over half a second; the time error is the host's 1/120 s step plus the contact margin (it reports a cushion up to a step after the touch). A pass that grazes the object ball by under 6 mm is not held to a verdict (Jolt reports a touch within its contact margin, nothing moves), and a Jolt ball contact only counts when the object ball really moved. Since adhoc-1014a the elevated strokes of 40° and 60° at 0.45 / 0.85 are real jumps (40 of the 80), held to the same tolerances through the flight, the touch-down and the bounces; a jump that clears the object ball must agree that nothing is touched; worst special **38.0 mm / 28.6 ms / 1.9°** (a 60° stroke with draw, 0.45).

**Gates for the jump and the world-space guide** (adhoc-1014a): `tests/physics/jump_probe.gd` — `BallMotion` on its own (Jolt's integrator is the model's parabola to 0.3 mm, the cloth impact, a bounce chain comes to rest and never freezes at its top), 8 strokes (elevation 35-80°, power 0.45-1.0, follow / draw / side) each watched by `SimDiff`: the host leaves the cloth (hops 77-446 mm), the model from `Ball.Plan.launch` is the host's to **0.68 mm in the air** (the first step after a rest-rate strike is 1/60 s), the first touch-down **0.13 mm** and the 0.4 s after it ≤ 6.2 mm, the client stays within **2.0 mm** of the host, 2-13 events a hop; a jump clears one object ball (passes 410 mm up; the same stroke flat hits it; the guide agrees on both); an airborne ball over a side pocket's mouth is not potted and one that comes down in it is; with cloth friction ×3 and a 1.5° tilt the flight is the same to under 1 mm; a stock cue can jump, a cue without it clamps below 30°, the host never trusts an elevation over 80°. `tests/sync/jump_pair_probe.gd` — two processes over ENet: the client shoots a 50° / 0.5 stroke, the host's ball hops 161 mm, the client draws 161 mm, and at every frame of the first second the position the client drew is within **2.05 mm** of where the host's ball was at that tick (rest positions 0.34 mm apart). `tests/physics/shot_guide_world_probe.gd` — a real `CueController` under a translated, rotated, tilted `Head`, 10 random shots: every vertex is on the cloth of the world table (within 4 mm of the guide's own lift) and inside the rails, the ghost ring within 15 mm of where the host's cue ball first touches (11.0 mm at worst; the probe's estimate carries the ball-ball throw), hidden outside aiming, on layer 12 and in no mirror / TV cull mask; the probe fails without the `global_transform` line (the ribbon is 2.3 m up).

**The cue tip shows the spin** (`CueController._pose_cue`): the cue's axis passes through the ball centre + `(right · spin.x + up_c · spin.y) · R · spin_offset_radius` (with the shooter's resolved radius), the same formula `Ball.plan_strike` uses for the impulse point, along the elevation the strike will really use (`Ball.effective_elevation`), so side spin shows the tip to the side, follow above, draw below, and a locked jump shows the clamped angle. A puppet's cue stays fixed (A14): spin is not on the wire.

### Cloth, cushions, rails
Sliding friction is Jolt's (`cloth_friction`): a struck ball slides until its contact point stops, then rolls — that phase is where follow, draw and side do their work. Rolling resistance is ours, Coulomb-like (magnitude independent of speed):

```
F = −v̂ · m · g · μ_r                              central, opposing travel
τ = −(UP × v̂) · (2/5) · m · R · g · μ_r           opposing the rolling axis, so ω slows in step with v (I = 2/5 m R², α = a/R)
τ_z = −ω_normal · m · R · μ_r · spin_decay        english about the table normal bleeds off faster than roll
        − sign(ω_normal) · I · spin_stop_rad_s2       plus a constant (pivot) loss, so it reaches zero
F, τ use μ_r · (1 + settle_boost · clamp(1 − v / settle_speed_mps, 0, 1) · clamp(1 − slip / 0.05, 0, 1))   the roll settles
```

At `μ_r = 0.025` that is `0.245 m/s²`: a ball rolling at 1 m/s stops in `≈2.0 m` (`transfer_probe.gd`), and a full-power break settles in 5–9 s (`perf_break`, 12 balls; 0.01 — real cloth — takes 20 s, past `RoundDirector.SHOT_CEILING_SEC = 12`). Before adhoc-1012a it was `0.035` **plus** Godot's hidden 0.1 /s linear and angular damping on every body: the same 1 m/s roll stopped in 1.2 m, and a 4 m/s ball lost 0.74 m/s² against the 0.25 now. The damping is explicit now (`TableSpec.ball_linear_damp` / `ball_angular_damp`, default 0, replace mode), `spin_decay` was raised 0.55 → 0.77 so english about the table normal bleeds as before.

**The creep tail (REQ#creep).** With constant drag alone a shot ended long after anything was happening: from the last moment a ball moved faster than 0.3 m/s the table took a median 2.9 s (the playtest bot saw 2.8 s) to be still, split 1.15 s of slow linear creep (0.3 m/s at 0.245 m/s² takes 1.2 s) and 1.46 s of english turning a ball in place (`spin_decay` is exponential: 8 rad/s needs 4.7 s to fall under `rest_ang_rad_s`). Two fixes, both live fields: **settle** — below `settle_speed_mps` the rolling drag ramps linearly up to `1 + settle_boost` times at standstill (a ball that is still slipping keeps plain cloth friction: it is the sliding that drives draw and follow), so a 0.3 m/s roll stops in 0.74 s / 13 cm instead of 1.2 s / 18 cm; **spin stop** — english also loses a constant `spin_stop_rad_s2`, as real pivot friction does, so 8 rad/s is gone in ≈1.1 s. `BallMotion` has both in closed form (`_roll`, `_spin`), so clients stay exact (`creep_probe`: lone ball 1.0 m/s, Jolt 1.993 m / 3.63 s, model 1.986 m / 3.60 s). Result on 12-ball breaks (`creep_probe`): tail 3.0 s → 0.77 s, shot median 6.7 s → 5.9 s; the part over 0.8 m/s is unchanged. The ramp is kept soft on purpose (REQ#feel-2): a ramp that starts at 0.4 m/s or boosts 8× also stops the slow rolls that used to creep into a pocket (bot: flat pots/shot 0.29 → 0.17–0.18 at 0.4 m/s), while 0.3 m/s / 1.5× keeps the pot rate and ends the tail inside 0.8 s. **Tilt.** `table_tilt_deg` 4° pulls a moving ball with `g·sin(4°) = 0.68 m/s²`, 2.8× the drag (1.15° already beats it), so a ball rolling downhill never slows and a tilted shot never ends by itself (12-ball breaks: 15 s median in `creep_probe`; a ball jammed on a pocket bevel can keep the table awake for seconds). That drift *is* the Event (`tilted_table`, pays 1.25×: before adhoc-1012a's creep fix the bot potted 0.83 balls/shot on it and cleared the table in 3–6 shots), so the pull stays above the drag: `tilt_max_vs_roll` (2.8) caps it at that × the rolling drag, which is the 4° Event's own pull, so a steeper tilt (Event + bump) saturates there. The shot ends by `RoundDirector.SHOT_CEILING_TILTED_SEC` (7.5 s): past it every ball on a tilted table is stilled, as `SHOT_CEILING_SEC` (12 s) does on a flat one (`round_probe`). A ball at rest stays at rest (the rest snap, `rest_speed_mps`): only struck and hit balls drift. The first cap (0.75 — friction always wins) turned the Event into a flat table that still paid 1.25× (0.20–0.30 pots/shot).

**Bot A/B (REQ#feel-2, `src/tools/playtest.gd`, headless, 10 seeds, default vote).** Noise is large: 3 seeds swung pots/Night between 4 and 14 on the same code, so judge rows of ≥10 Nights.

| | pre-creep `7c876e2` | creep `238d888` (0.3 m/s, 8×, tilt 0.75) | feel-2 (0.3 m/s, 1.5×, tilt 2.8, ceiling 7.5 s) |
|---|---|---|---|
| pots / Night | 7.9 | 7.8 | 8.4 |
| flat Rounds, pots / shot | 0.21 | 0.29 | 0.29 |
| combo shots / Night | 1.8 | 2.0 | 1.9 |
| shot median | 7.1 s | 4.85 s | 5.15 s |
| creep tail median | 2.3 s | 0.37 s | 0.77 s |
| Tilted Table, pots / shot | 0.83 (n=47) | 0.30 (n=40) | 0.55 (n=20); 0.54 forced on 140 shots |
| Tilted Table, shots over 8 s | 33 of 47 | 1 of 40 | 0 of 20; 1 of 140 forced (a ball on a pocket bevel, 9.5 s) |

**Gotcha (v0.0.1 "ice"):** applying the resistance *force at the contact point* (`τ = r_contact × F`) spins the ball **up**, not down — Jolt's contact friction then pushes it forward and the ball never stops. The torque must oppose `UP × v̂`.

Cushions shed tangential velocity by `cushion_friction` (Jolt), and reflect normal velocity by a restitution that **falls with impact speed** — a design ruling, not a measurement: soft hits mirror, hard hits deform the rubber and come off flat.

```
e(v_n) = lerp(e0, e_min, clamp((v_n − v_soft) / (v_hard − v_soft), 0, 1))
         e0 = cushion_restitution 0.86, e_min = 0.38, v_soft = 3.0 m/s, v_hard = 14 m/s   [tune]  (e_min 0.26, v_hard 7.5 until the cap went to 20 m/s)
tan(θ_out) = e(v_n) · tan(θ_in)        θ measured from the cushion face, tangential speed retained
```

| 45° into a long rail | v_n | e | θ_out |
|---|---|---|---|
| soft (< 3 m/s along the normal) | ≤ 3 | 0.86 | ≈ 41° (probe: 46°, sliding phase adds a little) |
| half charge (6.3 m/s) | 4.4 | 0.80 | ≈ 39° |
| full charge (20 m/s) | 14.1 | 0.38 | ≈ 21° (probe at 20 m/s) |

Mechanically: the rail material is `absorbent` with `bounce = ball_restitution − e0`, so Jolt bounces at `e0`; `Ball` catches `body_entered` from a body carrying `rail_normal` meta, stores the inward normal, and on the **next** `_integrate_forces` rescales the leaving normal component by `e(v_n)/e0` with `v_n = v_out/e0`. Next tick, because `body_entered` fires pre-solve for discrete contacts and post-solve for CCD ones. Both `e0` and `cushion_friction` are `PhysicsSim`-modifiable so 03's `glass_cushions` is a value change, not a code path. Every rail shape carries `rail_id` (countable `RAIL` contact) and `rail_normal`.

### Ball–ball impacts (`BallCollisions`, adhoc-1012a)
**Root cause of "rigid, lossy transfer".** Jolt solves every contact of a step together. Two balls hitting is fine (e ≈ 1, see the restitution row in §2), but balls already touching each other — a rack, a frozen combo — are solved as one lump: the contact that approaches gets its restitution, the contacts behind it have no approach speed and are plastic. The cue ball rebounds off a rack as off a wall, the balls behind it share what is left, and the restitution bias of the lump even adds energy. Measured at the tick after the impact (`tests/physics/transfer_probe.gd`, frictionless cloth, no drag, `ball_cascade_enabled` off vs on):

| shot | Jolt: cue / fastest ball / KE | `BallCollisions`: cue / fastest ball / KE |
|---|---|---|
| stun hit, 2 balls, 3 m/s | 0 % / 100 % / 100 % | +1 % / 98 % / 97 % (e = 0.97) |
| 3 touching in line, 3 m/s | −41 % / 59 % / 86 % | +1 % / 96 % (the far end) / 91 % |
| 10-ball rack, 6 m/s | −55 % / 55 % / **132 %** | −17 % / 64 % / 91 % |

**What runs.** `PhysicsSim._resolve_impacts` (host, every live tick, before the stream): from the state every ball had *before* the step (`_snapshot`) it finds the balls that could have touched this tick, replays the tick for that cluster in `BallCollisions.simulate` — impacts in time order, impacts within one contact duration (`1e-4 s`, a real ball's 0.1–0.3 ms) solved together by projected Gauss-Seidel so a symmetric hit stays symmetric, normal restitution `ball_restitution`, Coulomb friction `ball_friction` with solid-sphere spin — and sets `linear_velocity` / `angular_velocity` of the balls that took part. Positions stay Jolt's, so nothing overlaps; the clients are untouched (the event stream carries the corrected velocity, `_dirty` marks every ball that took part). A cluster touching a cushion or jaw this step, a potted ball, or an impact Jolt did not make (no ball's velocity moved by `PHANTOM_DV`) is left to Jolt. `ball_cascade_enabled = false` is Jolt's own response everywhere.

### The break and the speed ceiling (adhoc-1013c U12)
**Why a full-charge break moved two or three balls** (measured with a 2-D port of the model — `BallMotion` ground model, `BallCollisions`, the cushion curve — used to choose the settings; `tests/physics/break_probe.gd` is the engine measurement, the port is not Jolt): (1) **the seeded rack was a table-wide scatter**: the Bridson samples cover the whole cloth and `RackDropper` kept a *random* 12 of them, so the cue ball reached one or two balls (12 % of the rack moved, any cap); (2) **the authored triangle was a Newton's cradle**: balls 2.5–3 mm apart are hit one after another, the middle ones pass the speed on and stay put (20 % moved at 10 m/s; whether a gap/speed pair counts as one impact or a chain is `BallCollisions.CONTACT_SEC = 0.1 ms` against `gap / v`, a knife-edge); (3) the cue topped out at 10 m/s on a table twice regulation; (4) a hard hit left the cushion at a quarter of its speed.

**What changed.** (1) `RackDropper.drop` keeps the `n` Bridson samples **nearest the foot spot** (a formation, its spacing 2.4 → 2.2 R) instead of a random `n` — still seeded and reproducible, black ball on the centre slot (P31), pocket keep-outs, no overlap; `place_near` (respawns) unchanged. (2) The authored Night 1 triangle (`n1_r1.tres`) has 0.8 mm gaps (was 2.5 mm; a real rack touches); the other authored racks are spread out on purpose and are puzzles, not breaks. (3) `power_cap_speed_mps` 10 → **20** with the power curve above, so the lower half of the slider keeps its old feel. (4) `cushion_restitution_min` 0.26 → **0.38**, `cushion_hard_speed_mps` 7.5 → **14**. Result of the port (10 seeds of 12 balls, full charge from the head spot at the formation's centre): moved 12 % → 95 % (worst seed 83 %), Night 1 triangle 20 % → 84 %, shot length 4.2 → 4.5 s median for typical half-power shots and 5.5–6.6 s for the break (ceiling 12 s, `perf_break` gate 10 s). Acceptance: **mean ≥ 70 % of a seeded 12-ball rack moved (> 1 R or potted) over 10 seeds, no seed under 50 %, the Night 1 triangle ≥ 70 %, nothing off the table or through it, every break at rest inside 10 s** (`break_probe.gd`; the median shot of the playtest bot must stay ≤ 7 s, 02 / `playtest.gd`).

**Speed ceiling (no tunnelling).** `TableSpec.max_ball_speed_mps = 24` (scale-invariant) is enforced twice: `Ball.plan_strike` never launches faster (a `cue_power_mult` stat can ask for more), and `Ball._integrate_forces` clips a ball that gets faster anyway (a heavy cue ball into a light one, a blast) — one length compare per awake ball per tick. A ball moves at most `24 / 120 = 200 mm` per live tick (120 Hz, `PhysicsSim.LIVE_TICK`; the `240` in the physics-settings table is the unrealised hypothesis, not the build), against **cushion, facing and cup-wall colliders at least that thick** (`TableBuilder._min_step_safe_thickness`), so a step cannot carry a ball clean through one (a ball needs `thickness + 2R` of travel to skip a wall). Ball against ball: every ball faster than `ccd_speed_mps` (5.5) has CCD on, and the host re-solves every pair from the pre-step state with the swept test in `BallCollisions` (positions stay Jolt's). The event codec carries 24 m/s and 700 rad/s (`BallEventCodec`: lin 1 mm/s ±32.7 m/s, ang 1/32 rad/s ±1023). `tests/physics/speed_probe.gd` fires balls at the ceiling into every rail, a ball, a line of four and every pocket's facings and asserts nothing is crossed.

### Foul
**A legal `Shot` must produce at least one `BALL` contact between the cue ball and any non-cue ball.** Without this rule the dominant strategy is tapping the nearest ball forever; with it, a whiff costs a shot. A foul is: no object-ball contact, *or* the cue ball entering a drop plane (the old scratch), *or* any ball leaving the table. Consequences: the `Shot` scores nothing, one shot is deducted from the `Round` budget, 02 applies its viewer drop, a **scratch or off-table cue ball also costs the crew the 02 §3.8 fine** (10% of the Night's Quota, min $25, Cash may go negative — 06 P16; a whiff, a shot-clock foul and a wedged cue ball cost no Cash), and the cue ball respawns in the kitchen — the quarter of the table behind `kitchen_line_x`, at the first Poisson-disk candidate that clears every other ball. No ball-in-hand, no spotting, no other standard pool rules.

### Scoring
`raw_points` for a `Shot` is the sum over potted balls of `value(ball_type)` (`RoundDirector.value_of`, shop overrides applied; with `rule_call_pocket` only balls potted in the called pocket count), then tag modifiers: `high_value` `+25%`, `wild` applies `×2` to the single highest-value ball potted this shot, `penalty` stays negative and rides the same multiplier stack the positive balls do. `raw_points` **excludes** trick multipliers; 02 applies the winning trick multiplier and converts to `Cash`.

### TrickShot detection — five tricks, disjoint
All five are counters over the ordered contact log, evaluated once at shot end. Flat bonuses are gone: a `+50` flat was `+50%` on a red and `+10%` on a gold, so tricks were only worth doing on cheap balls.

| id | condition (over the contact log) | multiplier |
|---|---|---|
| `ComboPot` | ≥2 object balls potted this shot | `1.15`, `1.30 [tune]` at 3+ |
| `BankShot` | a potted object ball has ≥1 `RAIL` contact between its first `BALL` contact and its `POCKET` event | `1.20` |
| `KickShot` | the cue ball has ≥1 `RAIL` contact before its first object-ball `BALL` contact | `1.25` |
| `Carom` | the cue ball contacts ≥2 distinct object balls before the first `POCKET` event | `1.35` |
| `RailRunner` | a potted object ball has ≥3 `RAIL` contacts before its `POCKET` event | `1.60` |

**Disjointness: a `Shot` pays exactly one trick multiplier — the highest that fired.** `trick_ids` is emitted sorted by multiplier descending, and 02 multiplies by the first entry only. Everything detected is still emitted, so 03's Effects can react to a `KickShot` that lost to a `RailRunner`. `TrickShot { id: StringName, multiplier: float, shot_id: String, tags: Array[StringName] }` — `multiplier` and `tags` are pure functions of `id` (`TrickShot.make`, `TrickShot.TAGS`), so a client rebuilds the same object from the wire id — no `bonus_points` field, because there are no flat bonuses.

Cut and not coming back: `MasséCurve` (curve-radius fitting is noise), `DoubleCushionExit` (fires on nearly every rail), `ScratchEscape` (undefinable), `SplitChain` and `BombCascade` (they described balls that did not exist yet).

### Random drop — Poisson-disk
Bridson sampling over the table interior, seeded from `round_seed`: inset the rectangle by `ball_radius + clearance_margin_m`, subtract a disc of `hole_radius + 1.35 × ball_radius` at each pocket (`RackDropper.keepouts`: a ball placed on a hole would fall in), sample with minimum spacing `r = 2.2 × ball_radius [tune]` and `k = 30` candidates per active point. About 15 lines, and it cannot fail: if it yields fewer points than balls, shrink `r` by 5% and resample. **The rack is the `n` samples nearest the foot spot** (adhoc-1013c W2: a random `n` of the whole table's samples left the cue ball one or two balls to hit — "The break", §3): a loose formation about 0.35 m across that a full-power break scatters. **The black ball goes first (06 P31):** it takes the slot nearest the formation's centroid (a tie goes to the slot nearer the foot spot, then the lower index — `RackDropper.centre_slot`), whatever the seed; the remaining balls are then dealt to the remaining slots by openness, high-value-first, so a `gold_prize` takes the most open *remaining* slot and never lands in the one awkward spot by accident. (A change to the earlier "highest value takes the most open of all slots": the prize now yields the centre slot to the black.) A rack without a `penalty` ball is dealt exactly as before; a second black keeps its dealt spot.

The seed is **shown in the round UI** — the same seed reproduces the rack, which is what makes a shared "watch this" moment possible. Night 1 and the Campaign finale's racks are hand-authored position arrays (`.tres`), because a first impression and a finale should not be a dice roll.

### Stuck state and table bump
If, after a `Shot` resolves, no ball with `counts_for_clear` and `value > 0` remains, the `Round` ends immediately via `table_cleared` with **no penalty** — being left with only `black_penalty` and `stone_ball` is not a player mistake. If the cue ball comes to rest wedged (its `test_move` is blocked in all 16 sampled directions), it is respawned free in the kitchen with no foul and no shot cost.

Non-shooters can shove the table (P2). `PhysicsSim.nudge(direction: Vector2, strength: float, source_peer_id: int)` applies a central impulse of `strength × 0.06 N·s [tune]` to every non-resting ball and appends a `NUDGE` contact event, so the log stays the complete record of what happened. Sustained tilt is the same hook by another name: `apply_modifier("table_tilt", ...)`. 03 owns the Effect that wraps either, 02 owns the viewer/hype price of using it.

### Round staging — the set-up and the clean-up (adhoc-1013c U15/U16, 06 P33 A4)
A Round starts and ends in front of the crew, and neither is physics. **Set-up:** the vent above the table's east rail (`MainLevel/Vent`, the end nearest the Blackboard, §4) slides its louvres apart, a saucer flies out of its mouth and hovers over the table, the louvres slide shut behind it, and its beam walks along the rack — the cue ball first, then the object balls in `net_id` order — materialising each ball where it stands (a glow shell over the ball's own material, then plain again); then the saucer dematerialises. **Clean-up:** the bed splits into 8 flaps hinged across the table's width that drop open from the middle outward, every ball rides its flap, lets go and falls into a dark pit inside the table body, vanishing as it sinks, and the flaps close; the table is then empty. (Two halves cannot do it: under the bed there is only the apron's 0.34 m and a half is 1.27 m wide, so a half hinged at the rail would open 15°; a flap is a 0.32 m strip.)

**One flag, one budget.** `RoundDirector.staging` is true for the whole of either sequence (`staging_changed(on)`; a plain `bool` to everything that reads it). While it is true: `can_strike` is false and the validator answers `staging` (so a client's `request_shot` is rejected with it), the shooter's clock is not armed (the host arms it when the set-up ends), `GameLoop`'s Round clock does not run on the host and the client's cosmetic countdown stands still, GO LIVE is refused (`toggle_ready`, the host's `go_live` validator, `advance()`; the pedestal says *Table clearing*), and the Shoot button and hostile prompts are off (`Player._staging()`). Budgets: **set-up ≤ 5 s, clean-up ≤ 3 s, for any ball count** (`StagingPlan`: the reveals share a 2.2 s beam window — at most 0.3 s a ball — so 1 or 64 balls end by 4.75 s; the clean-up is a fixed 2.3 s). `RoundDirector.skip_staging` (static) turns both off: probes, tools and the playtest bot (it defaults to *true* in a headless run and `SoloSupport.until_playable` sets it; a staging probe asks for them with `keep_staging`), and a View-page toggle in the debug panel. With no `MainLevel/Staging` node (the `-s` probes that build a bare director) there is nothing to stage either.

**Same picture on every peer, no new rpc.** The balls exist on the host from the first frame, spawned and frozen where the rack puts them, hidden until the beam reaches them: physics never waits on the picture. Each peer plays the schedule from its own clock, started by data it already has — the host when `start_round` has placed the rack, a client when `push_rack` arrives (so it trails the host by network latency; it ends later, never earlier, and a strike it asks for before then is refused by the host). The reveal order and times are a function of `(net_id, ball count)` alone (`StagingPlan.reveal_start`). A `full_state`, a new rack or a re-rack snaps a running sequence to its end. The clean-up starts on the host at `end_round()` and on a client from `GameLoop.round_ended`, once the playback clock has shown the Round's last shot; the real balls are hidden and left alone (a client's replica keeps writing their positions), stand-ins fall instead, and the host clears the balls when it ends. `tests/world/staging_pair_probe.gd` holds the two peers to ≤ 0.3 s per ball.

**Nothing in it collides.** The saucer, its beam and landing pad, the vent, the flaps, the pit and the ghost balls have no collision object (probe-checked), so nothing can snag a player or a ball. **The lid:** `Table` carries one `Lid` slab on the player layer (world, 4) over the bed and every pocket opening, its top level with the rail tops; a player who jumps onto the table stands on it instead of in the playfield (the bed and the cushion strips are layer-2 colliders a player can stand on) or in a pocket, and it stays solid while the bed opens. Balls (mask 1|2|3) never test it.

## 4. Godot implementation sketch

### Scenes and nodes (no autoloads — D7)
- `src/gameplay/table/Table.tscn` — `StaticBody3D` bed (flat convex pieces with a hole at every pocket), rail shapes each carrying `rail_id`, per-pocket angled jaw stubs + a cup (`Cup_<id>` body, `Drop_<id>` pot `Area3D`, `Cover_<id>` under Moving Pockets), and a **`PhysicsSim` child node** that owns the live modifier stack. `table.gd` only orchestrates: `table_geometry.gd` derives a `TableLayout` from the `TableSpec`, `table_builder.gd` turns that into bodies, `table_visuals.gd` turns it into meshes. `PhysicsSim` is *not* an autoload and there is no global `Signals` bus; listeners connect directly to the node that emits.
- `src/gameplay/balls/Ball.tscn` — `RigidBody3D`, `continuous_cd`, `contact_monitor`, mesh, `SphereShape3D`.
- `src/gameplay/cue/CueController.tscn` — consumes a `ShotIntent`, renders aim arc / power / spin cursor. Input device is the Player module's problem.
- `src/gameplay/round/RoundDirector.gd` — child of `MainLevel`; owns the rack, the shot state machine, the contact log, scoring and the signals below.

### Physics modifiers
`PhysicsSim` is a **stat sink, not a timer stack**. 03's `EffectManager` resolves every stat (base → ADDs → MULs) and owns all timers (Shot / Round expiry); it pushes the *resolved* value with host-only `PhysicsSim.set_stat(stat, value)`: `cue_ball_mass_mult`, `cloth_friction_mult` (scales rolling resistance, slide friction and the bed's contact friction), `cushion_restitution_mult`, `table_tilt_deg` (+ `set_tilt_direction(Vector2)`), and per-rail `set_rail_restitution_mult(rail_id, mult)`. Per-Shot stats (`cue_power_mult`, `cue_spin_radius_mult`) are pulled at strike through `stat_source(stat, peer_id, base) -> float`. The resolved cushion `e` is clamped to ≤ 1.0 (a glass cushion never adds energy). Tilt is a constant force along `tilt_direction` on **moving** balls only, `min(g·sin(tilt), tilt_max_vs_roll · g · μ_r · cloth_friction_mult)` (`PhysicsSim.tilt_accel()`); a ball at rest stays put. Effects never write `TableSpec`; the debug panel does (`Table.apply_physics()` below). Pocket stats are RULES' (wave 2). Plus `PhysicsSim.nudge(...)` as above, which also emits `nudged` so `RoundDirector` logs the `NUDGE` entry.

### Rolling resistance, rest, CCD gate, cushion rescale — one function
`Ball._integrate_forces` (implemented, `src/gameplay/balls/ball.gd`) does exactly four things in order: apply a pending `rail_normal` rescale, snap to rest below `rest_speed_mps` / `0.15 rad/s` (then `is_resting = true` and `rested` emitted, deferred), gate `continuous_cd` on `ccd_speed_mps` for object balls, then the three rolling-resistance terms above. `up` becomes `sim.surface_normal` when `table_tilt` lands. Keep it ~30 lines (07 §5.2).

`Ball.is_resting` (not Jolt's own `sleeping`) is the source of truth for "at rest": a ball with an *active contact* (resting in the pocket-throat sense, or just sitting on the cloth) can go a long time — far longer than `rest_time_sec` — without Jolt's own sleep threshold ever tripping, and `sleeping` genuinely never flips for some resting configurations. `is_resting` is ours, set the instant `rest_speed_mps` is met and cleared on `strike()`; `PhysicsSim` counts `awake` from it, never from `sleeping`.

### Live tuning (`TableSpec.LIVE_FIELDS`, `Table.apply_physics()`)
Every feel number is an `@export` on `TableSpec` (with an `@export_range` the debug panel builds its slider from); `LIVE_FIELDS` is the subset that applies without a rebuild: cushion curve and friction, cloth and ball friction, ball restitution, `ball_cascade_enabled`, rolling resistance, spin decay, the settle ramp and spin stop, the tilt cap, damping, rest thresholds, cup friction and bounce, the CCD step. `Table.apply_physics()` re-applies them to the live bodies (`TableBuilder.apply_materials`), the balls (`Ball.apply_spec`: material, damping, CCD gate) and every `BallMotion.Params` — no re-rack, no rebuild. Geometry (`scale`, `bed_height_m`, `max_ball_speed_mps`) still goes through `Table.rebuild()`. A change must reach the clients before the next strike or `SimDiff` diverges: the `shot_started` stats array carries `live_values()` after its four stats (04 §5), and a change made mid-Shot rides `_motion_stats_rpc` like the cloth stat does. `BallMotion` reads the same fields, so host prediction and client reconstruction model from identical numbers (values pass through float32 on both sides, `TableSpec.set_live`).

### PhysicsSim
Child of `Table`; `register(ball)` wires `struck` / `resting_changed` / contacts, and gives the ball its wire `net_id` and `BallMotion.Params`. On strike: `contact_monitor` on for every ball, tick `120 Hz` (`LIVE_TICK`, the one tick constant), `shot_started`, and the host starts the event stream (04 §2.4). When the awake count (from `Ball.is_resting`) hits zero: final rest events flushed, `contact_monitor` off, tick `60 Hz`, `all_resting` — the shot boundary of 07 §1.3 and the idle downclock of 07 §7.2. Exposes `Game/AwakeBalls` (removed in `_exit_tree`: a monitor callable left behind corrupts the heap at quit), `get_balls()`, `request_shot(intent)` (any peer; host validates through `shot_validator(peer_id, intent) -> StringName`, then strikes with `active_cue` (a CueSpec; RULES sets it at Round setup, never taken from a client)), the stat sink above, and the presentation gate `playback_tick()` / `at_playback(tick, fn)`. Clients register balls as kinematic puppets (`Ball.set_client_mode`) and never run Jolt on them.

### Signals (emitted by `RoundDirector`, connected directly)
- `ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)` — the pocket id is what lets 02 score which `Camera` had the shot; `Table.get_pocket(pocket_id) -> PocketSpec` gives it the world position for the distance + occlusion test (P2).
- `shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)`
- `trick_detected(trick: TrickShot, shot_id: String)`
- `table_cleared(round_id: String)`
- `shooter_changed(peer_id: int)` — whose Turn it is; `RoundDirector.current_shooter_id` rotates by `NetManager.seat_order()` after every `shot_ended` (04 `set_shooter`). `PhysicsSim.shot_validator` (installed here) rejects out-of-turn, mid-shot, no-Round, bad power/aim requests.
- `cue_respawned(reason: StringName)` — `scratch | wedged | off_table`; the cue ball was put back in the kitchen before `shot_ended` (wedged costs nothing, HUD only)
- `staging_changed(on: bool)` — the Round's set-up / clean-up picture started or ended on this peer (see "Round staging"); `RoundDirector.staging` is the flag, `GameLoop.staging_changed` relays it to the GO LIVE pedestal.

### File paths under `src/`
`gameplay/table/TableSpec.gd`, `gameplay/table/table_geometry.gd` (`TableGeometry`, pure `layout()`), `gameplay/table/table_layout.gd` (`TableLayout` data, incl. `RailSegment`), `gameplay/table/table_builder.gd` (`TableBuilder`, bodies), `gameplay/table/table_visuals.gd` (`TableVisuals`, meshes), `gameplay/table/PocketSpec.gd`, `gameplay/table/PhysicsSim.gd`, `gameplay/balls/BallType.gd`, `gameplay/balls/BallTypeOverride.gd`, `gameplay/balls/Ball.gd`, `gameplay/cue/CueSpec.gd`, `gameplay/cue/shot_model.gd` (`ShotModel`), `gameplay/cue/shot_guide.gd` (`ShotGuide`), `gameplay/cue/CueAim.gd`, `gameplay/round/RoundDirector.gd`, `gameplay/round/ContactLog.gd`, `gameplay/round/ShotScoring.gd`, `gameplay/round/TrickShotDetector.gd`, `gameplay/round/PoissonDrop.gd`, `gameplay/staging/` (`round_staging.gd` `RoundStaging`, `staging_plan.gd` `StagingPlan`, `vent.gd`, `ufo.gd`, `trapdoor.gd`, `table_pit.gd`, `materialise.gd`, `staging_tray.gd`; shaders `materialise`, `ufo_beam`, `ufo_rim`, `staging_tray`). Demo-only until the Player module lands: `gameplay/cue/cue_controller.gd` (spin cursor I/J/K/L, elevation Q/E, reset C; reach and pullback follow the struck ball's own `cue_reach_m`/radius, no metre literal) and `gameplay/cue/spin_disc.gd` (HUD); `resources/cues/demo_cue.tres` has jump and massé unlocked and is `cue_controller.gd`'s own `@export` default. `tools/spec_dump.gd` (headless, prints the table pasted into §2 above) and `tools/screenshot_table.gd` (headless-launched with a real GPU context, not `--headless`; saves a PNG of the built table from a player-height view).

### Physics test fixtures (`tests/physics/`, headless)
The cheapest insurance in the plan — each is a scripted `ShotIntent` against a fixed rack, asserted on outcome. `tests/physics/probe.gd` (`godot --path . --headless -s tests/physics/probe.gd`) is the first cut: roll-out distance and rest time, cushion angle soft vs hard, draw returns / follow passes, straight-in pot, jaw hit (never tunnels/leaves the table), resting/rolling balls on the bed side of a hole's rim never pot and over it do, full-power rail return, cue reach limit. `tests/physics/pocket_probe.gd` is the real-pocket fixture (06 P30): mouths ≥ 2.5 / 2.7 D at scales 1 and 2, the drop visibly below the cloth before the pot, 0.6 R off-line shots still dropping at corners and sides, a cushion shot beyond the mouth still rejected, a 3 m/s ball not skipping across, a creeping 0.6 m/s ball falling in, a grown mouth swallowing a resting ball, and Moving Pockets moving the opening (ball over the cover stays, drops when the opening arrives). `tests/physics/geometry_probe.gd` checks `TableGeometry.layout()` alone, headless and scene-free: pocket/rail/sight counts, spots, and every derived `TableSpec` value against `REG_* × scale`. `tests/physics/table_top_probe.gd` ray-casts the table's visual meshes from above (adhoc-1013c W1): a rail top at rail height wherever the wood is not cut for a pocket, no wood or cloth over a pit. Gotcha for every fixture: a GDScript lambda captures locals **by value** — signal handlers must set a member, not a local.
0. **Transfer and collisions** — `tests/physics/collisions_probe.gd` (pure data, no engine: two-ball e, Newton's cradle, a 15-ball break keeps the cue ball and the energy, symmetric splits stay symmetric, gaps, friction throw) and `tests/physics/transfer_probe.gd` (the table above in the engine, Jolt vs `BallCollisions`, plus the 1 m/s roll-out and the cushion rebound at 2/4/6/9 m/s). **Creep** — `tests/physics/creep_probe.gd`: the `BallMotion` roll and spin closed forms against a 0.1 ms numeric integration, a lone ball in Jolt against the model (0.25 / 0.6 / 1.0 m/s and 8 rad/s of english), 12-ball breaks (tail after the last ball over 0.3 m/s ≤ 0.8 s, 3.0 s without the settle ramp and spin stop) and the 4° tilt's pull against its cap (the 7.5 s tilted shot ceiling is `round_probe`'s).
1. **Straight-in pot** — ball 0.5 m off a corner pocket, centre-ball strike: 100/100 runs pot.
2. **Stun stop** — centre-ball at 2 m/s into a full ball: cue ball residual speed `< 0.05 m/s`.
3. **30° cut** — object ball crosses the target line within `±15 mm [tune]` at 1.0 m.
4. **Break integrity** — max power into a 12-ball rack, 200 runs: zero tunneling, zero balls off table, all at rest inside 12 s. Built as `tests/physics/break_probe.gd` (10 seeded racks + the authored ones: ≥ 70 % of the rack moves, nothing leaves the table, rest inside 10 s) and `tests/physics/speed_probe.gd` (balls at the 24 m/s ceiling into every rail, ball, line and pocket facing); `tests/physics/shot_guide_probe.gd` holds the shot guide against the host (§3 "Shot guide").
5. **Trick log** — a scripted bank, kick, carom, combo and rail-runner each detect their own trick and exactly one multiplier is paid.
6. **Mobile budget** — fixture 4 on the target phone: 60 fps sustained, physics step `≤ 8 ms`. This one gates the 240 Hz setting.

## 5. Interfaces to other modules

**To 02 (economy/shop).** `shot_ended(...)` → 02 applies `trick_ids[0]`'s multiplier to `raw_points`, then the stream multipliers, then converts to `Cash`; `foul = true` costs a shot from the `Round` budget and drops `Viewers`; the scratch / off-table Cash fine is 02's, taken from `cue_respawned`. `ball_potted(ball, shot_id, pocket_id)` → per-ball reward flow and the camera-view score for that pot. `table_cleared(round_id)` → close the `Round`. 02's `Shop` supplies `Array[BallTypeOverride]` and the active `CueSpec` at `Round` setup; 01 reads both and never writes them. 01 states the ball cap (`≤ 12`) that 02's "10 object balls per `Round`" sits inside.

**To 03 (drinks/events).** `PhysicsSim.apply_modifier(...)` and `PhysicsSim.nudge(...)` are the entire physics surface for `Effect`s and `Event`s, host-only. `BallType.behaviour_tags` are readable by both. `trick_detected` is amplifiable. `aim_wobble` is applied by the Player module and scaled by `CueSpec.wobble_reduction`, floored at 0.

**To 04 (architecture/netcode).** The host owns the sim; clients get contact events plus a low-rate heartbeat, so the contact log doubles as the sync payload. `Shot.intent` + `Round` seed is the whole replay record. `PhysicsSim` lives in `Table.tscn` as a plain node — 01 declares no autoload.

## 6. Open questions
*Ruled 2026-09-30 (06 P8):* `bomb_ball` scatters its neighbours and removes only itself (no fragments); `split_ball` spawns one `red_basic` per pot, not per carom; no "house" pocket; `stone_ball` counts toward the `≤ 12` ball cap.
- Jaw restitution `0.55` decides how often shots rattle; that is a feel dial — who owns it after the first playtest, 01 or 03?

## 7. MVP cut vs later

**MVP.** Jolt `RigidBody3D` sim at a validated tick rate with CCD on every ball. Cue impulse, spin offset, miscue, and the `ShotIntent` boundary. Pockets as holes in the bed with cups (06 P30). Rolling resistance in `_integrate_forces`. Foul rule with kitchen respawn. Three value tiers plus `black_penalty` plus `stone_ball`; gimmick balls stubbed as buyable but only `bomb_ball` implemented. All five tricks with the disjointness rule. Poisson-disk drop with a visible seed and the two authored racks. `CueSpec` read from the shop, `BallTypeOverride` resolution. Stuck-state rule. All four signals. Fixtures 1–4 and 6 green before any netcode work starts.

**Later.** `split_ball` and `joker_ball` behaviours. Table bump/tilt tuning past the raw hook. Shot ghost previews and spin visualisers. Adaptive layout difficulty by `Round`. Same-machine replay playback from intents. A second table with different `TableSpec` values as a shop item.
