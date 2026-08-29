# Absolute Billiard — Design Plan Index

Systems-only pass. **Player (character, controller, input, cosmetics) deferred** — every doc treats Player as a black box.

| # | Doc | Scope | Author |
|---|-----|-------|--------|
| 00 | [00-contract.md](00-contract.md) | pitch, shared vocabulary, doc template, ownership | alpha (claude) |
| 01 | [01-physics-table-balls.md](01-physics-table-balls.md) | Jolt RigidBody3D settings, cue/CueSpec, 3 tiers + penalty + shop gimmicks, 5 tricks, Poisson drop, fixtures | copilot → opus rewrite |
| 02 | [02-economy-loop.md](02-economy-loop.md) | Night/Round/Quota ×1.5 curve, income sheet, Stream/Viewers, Bartender Shop catalog, persistent unlocks | agy → opus rewrite |
| 03 | [03-bar-drinks-events.md](03-bar-drinks-events.md) | typed StatMod/Effect, Drinks, crew-chosen Events, world-interaction catalog (free-roam), griefing guard | sonnet → opus rewrite |
| 04 | [04-architecture-netcode.md](04-architecture-netcode.md) | mobile-first platform matrix, ENet+Noray (Steam optional), event-based sync, RPC/channel table, SaveProfile broadcast, M0 perf spike | omp → opus rewrite |
| 07 | [07-optimization.md](07-optimization.md) | per-aspect mobile budgets: physics, render, net, memory, GDScript, load, battery, assets, CI gates | opus |

## Cross-module signal map (post-rewrite, 2026-08-29)

| Producer (doc) | Signal / call | Consumer (doc) |
|---|---|---|
| RoundDirector (01) | `ball_potted(ball, shot_id, pocket_id)` | EconomyManager, StreamManager (02 camera-view scoring uses `pocket_id`) |
| RoundDirector (01) | `shot_ended(shot_id, shooter_id, raw_points, trick_ids, foul)` | EconomyManager (02) → NetManager relays as `shot_resolved(shot_id, shooter_id, end_tick, raw_points, trick_ids, foul)` (04) |
| RoundDirector (01) | `trick_detected(trick, shot_id)`, `table_cleared(round_id)` | StreamManager, GameLoop (02) |
| GameLoop (02) | `night_started / round_started / round_ended / night_ended` | EventScheduler (03), NetManager `round_state` (04) |
| EconomyManager (02) | `cash_changed(absolute)`, `quota_evaluated` | UI, NetManager `update_cash(absolute_balance)` (04) |
| EffectManager (03) | `effect_applied/expired`, `reward_mult_changed` | EconomyManager reads `Reward = Drink_Mult × Event_Mult` at shot resolve; `PhysicsSim.apply_modifier` (01, host-only) |
| World interactions (03) | `request_world_interaction(kind, target_id)` client→host (04) | EffectManager (03) with `owner_peer_id` |
| PhysicsSim (01/04) | `shot_started`, `push_contact_events` (reliable ch1, 30 Hz flush), `push_heartbeat` (unreliable_ordered ch2, 2 Hz) | clients dead-reckon + interpolate |
| SaveManager (04) | `SaveProfile` broadcast each Round end | every peer (any friend can re-host) |

Autoload: `NetManager` only. `SaveManager` static. `GameLoop`, `EconomyManager`, `StreamManager`, `EffectManager`, `EventScheduler`, `RoundDirector` = `MainLevel` children; `PhysicsSim` = Table-scene node. (D7)

## Integration notes / conflicts found (first pass — all superseded by 06 + rewrites; kept for history)
1. **`shot_ended` signature drift inside 01** — §4 emits `(shot_id, raw_points, trick_ids)`, §5 lists `(raw_points, trick_ids, scratch)`. Canonical: `shot_ended(shot_id: String, raw_points: int, trick_ids: Array[StringName], scratch: bool)`. **Fixed** (REQ#ab-1b).
2. **02 `award_shot_reward(base_points, trick_shot_tag: String, camera_id)` takes ONE trick tag; 01 emits an array.** Change 02 to `trick_ids: Array[StringName]` and sum trick bonuses (01 already folds bonus into `raw_points`? — 01 §3 says raw_points includes trick bonus; 02 §3.2 adds `TrickShot_Bonus` again → **double count**). Decide: 01 emits `raw_points` WITHOUT trick bonus + `trick_ids`; 02 applies bonus. **Fixed** (01 emits raw_points w/o trick bonus; 02 sums from trick_ids).
3. **Foul naming**: 01 says `scratch`, 02 `StreamManager.record_shot_result(is_foul)`. Only one foul exists (cue ball potted) — **Fixed**.
4. **04 `turn_ended()` RPC duplicates 01 `shot_ended`** — 04 should relay `shot_ended` payload, **Fixed** → `shot_resolved(...)`.
5. **Physics model consistent**: 01 picks `RigidBody3D` single-plane; 04 picks snapshot sync (20 Hz [tune]) for exactly that reason. OK.
6. **Renderer**: 04 recommends switching `project.godot` from `mobile` to `Forward+` (PC/Steam target). Needs Cleanse decision.
7. **Effects on physics**: 03 `requires_host_apply` ↔ 04 host-only note ↔ 01 exposes tunable offsets. Consistent; 01 must expose `PhysicsSim.apply_modifier(field, delta, duration)` — **Fixed** — added in 01 §5.
8. **Cash ownership**: 04 open question (host campaign vs per-client cut) affects 02 save schema. Decide before netcode work.

## Open questions rolled up (need Cleanse)
- 01: ghost_ball passthrough scope; bomb_ball fragments; massé gated by upgrade?; asymmetric "house" pocket?; split_multi score once vs per carom
- 02: scratch = flat Cash penalty or viewer drop + lost turn only?; idle players in 4p — camera switching / hype emotes?
- 03: Drink effects persist across Rounds?; cancel a drink early (ice_water)?; telegraph event queue vs surprise?; endless-mode tier >3
- 04: cross-play beyond Steam?; Cash host-only vs per-client

## Review checklist (for Cleanse) — post-rewrite
- [ ] 06 P1–P5 rulings reflected in every doc (grep: roles, Forward+, Steam-only should be gone)
- [ ] 02 income sheet ratios acceptable (1.70→1.43 before drinks)
- [ ] 03 world-interaction catalog matches the free-roam fantasy you want
- [ ] 07 M0 budget numbers realistic for your test phone
- [ ] Physics model choice (01 §4) matches sync plan preference (04 §4)
- [ ] Points→Cash formula (02 §3.2) consumes exactly what 01 emits and 03 multiplies
- [ ] Effect schema (03 §2) is the ONLY modifier path used by 01/02
- [ ] Vocabulary from 00 used consistently (grep for drift)
- [ ] Every `[tune]` number acceptable as placeholder
- [ ] MVP cut sections agree on the same vertical slice

## Deferred (next pass)
- Player: movement, cue-holding, animation, bar interaction UX, cosmetics
- Audio, VFX, UI/HUD layout

---

## Alpha review (claude, full read 2026-08-29) — HISTORICAL: adjudicated in 06, docs since rewritten

Verdict: docs are usable as a review baseline, **not** build-ready. Two decisions change everything downstream (R1, R2); the economy numbers do not close (R3). Everything else is polish.

### R1 — Physics engine choice (01 §2, 04 §2) — DECIDE FIRST
01 picked `RigidBody3D` because "Godot already solves it". Wrong trade for this game:
- Godot rigid bodies do not model cloth rolling/sliding friction, throw, or english transfer — the "real pool physics" pitch is not achievable by tuning restitution.
- Half the BallTypes (ghost, magnet, bomb, split) and Events (tilt, moving pockets, oscillation) need custom per-ball rules anyway.
- Non-deterministic → 04 is forced into 20 Hz snapshot streaming + interpolation.
**Recommendation:** custom 2D analytic sim on the table plane (positions `Vector2`, ball-ball impulse w/ spin, cushion segments, rolling/sliding/spin decay, pocket geometry), rendered by 3D meshes. Deterministic given (seed, Shot intent) → 04 becomes lockstep: host validates, broadcasts `Shot` + seed, every client replays locally. No snapshots, no interpolation, free replays for the stream/trick-cam feature. Cost: ~1–2 weeks physics work up front instead of fighting the engine for the whole project.

### R2 — Turn structure is anti-friendslop (02 §3.1)
Round-robin means 3 of 4 friends idle 75% of the time on a 120 s round (~8 shots each). Genre lives on simultaneous chaos.
**Recommendation:** each player has their own cue ball (colour-coded), everyone shoots whenever their cue ball is at rest — no turns. Table becomes shared chaos; collisions between friends' cue balls = fun + TrickShot fodder. Keep round-robin as an optional "classy" mode. Requires 01 `Shot` to carry `player_id` and 04 to accept concurrent intents (trivial under lockstep). Resolves 02 open question 2.

### R3 — Economy numbers do not close (02 §3.2–3.3)
Night 1: 0.1 $/pt × ~120 pt ball × viewer scalar ~1.15 ≈ $14/pot; 3 rounds × ~12 balls ≈ 36 pots ≈ $500 + tricks < $600 quota **before** buying any $50–300 drink. Night 5: ≈$70/pot × 36 ≈ $2.5k vs $8.5k quota. Also `Viewer_Scalar` is defined twice, differently (StreamState field vs §3.2). Camera "captured by this camera" is undefined (which camera's multiplier applies to a shot?).
**Recommendation:** one formula, one sheet. Fix `Point_To_Cash_Rate = 1.0`, size quotas to ~60% of expected income so drinks/upgrades are affordable, define camera capture = nearest camera to potted pocket (or best-angle tag). I can generate the sheet once R2 is decided (shots/round changes 4×).

### 01 — physics/balls
- Double reward: §3 "bank 1.20x / kick 1.25x / carom 1.35x" multipliers AND flat TrickShot bonus points for the same events. Keep flat bonuses only; delete the multipliers.
- `pocket_capture_speed 0.28 m/s` — balls are potted at speed in real pool; capture should be geometric (centre inside pocket circle) with rattle/rejection for near-misses, not a speed ceiling.
- Scratch: where does the cue ball respawn? (kitchen? ball-in-hand? random?) — undefined.
- Round end "table cleared": must `black_penalty` be potted to clear? Define cleared = all `base_value > 0` balls potted; penalty balls just vanish.
- `wild` "inherits best active multiplier" — undefined once multipliers are removed; make it `x2 of highest-value ball potted this shot`.
- `Signals.gd` global bus + `PhysicsSim.gd` autoload vs 04 placing `PhysicsSim` under `gameplay/` — pick one (I'd make PhysicsSim a Table-scene node, no global bus).

### 02 — economy
- Game over at `Cash < 0.7×Quota` with no recovery is fine for co-op, brutal for singleplayer — consider singleplayer quota scale 0.6 [tune].
- Campaign = 5 Nights × 3 Rounds × 2 min ≈ 30–45 min. Fine for a session game; say so explicitly or add Endless as default post-win.
- "$15,000 buyout" vs Night 5 quota $8,500 — ambiguous whether additive. Define.
- Save schema (04) lacks `unlocked_ball_types`, camera tiers, table mods listed in §3.4.

### 03 — drinks/events (best doc of the four)
- `energy_drink` "round timer +15s" is not a stat key → add `round_time_add_sec`.
- `fog_of_war`/`lights_out` hit `camera_visibility` — stream cameras (income) or the player's view (difficulty)? Say which; probably both, separate keys.
- `trigger_rule` as free text is not evaluable → `min_night: int` + optional `scripted_first: bool`.
- Missing friendslop gold: **buy a drink FOR a friend** (sabotage). One flag `target_player_id` on purchase. Recommend adding.
- Reward multipliers (0.15–0.55) never approach the 6.0 global cap — fine, but caps could be 2/2/3.

### 04 — architecture
- Autoload names disagree across docs: 04 `Game/Net/Save`, 02 `GameLoop/EconomyManager/StreamManager`, 03 `EffectManager/EventScheduler`, 01 `Signals/RandomSource/PhysicsSim`. Canonical (my pick): `GameLoop`, `EconomyManager`, `StreamManager`, `EffectManager`, `NetManager`, `SaveManager`; `EventScheduler`, `PhysicsSim`, `RoundDirector` are scene nodes.
- GodotSteam needs a Steamworks app (uses SpaceWar 480 for dev; invites only work with real app id). Milestone order (ENet LAN first) is right — keep it.
- Lobby flow is one line; needs: create → Steam overlay invite → join → ready → host starts; singleplayer = host with 0 peers, same path.
- Host-drop = Night failed: acceptable, but save at Round end so the crew can resume the Night.
- If R1 → custom sim: replace §2 snapshot model with lockstep (Shot intent + seed), drop tick rates/interp, keep heartbeat.

### Fixed during review (small, alpha)
- 01 §5 `ball_potted` signature now matches §4.
- 03 §3.1 stale bullet claiming trick multipliers fold into base points — replaced.
