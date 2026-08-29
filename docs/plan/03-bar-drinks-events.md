# 03 — Bar, drinks & events

## 1. Purpose
Owns the `Effect` schema shared by `Drink`, `Event` and world interaction, plus the Drink content, the Event catalog and the world-interaction catalog that non-shooters use while someone else is on the table.
Feeds one number to 02 (`Reward_Multiplier`); it does not define ball physics, scoring, shop purchase flow or money storage.

## 2. Concepts & data model

### 2.1 `StatMod` (`Resource`) — the only way an Effect touches anything
| field | type | notes |
|---|---|---|
| `stat` | `StringName` | must be one of `Stats.ALL` (§2.2). Anything else is a load-time assert, not a silent no-op. |
| `op` | `enum {ADD, MUL}` | `ADD` sums into the base, `MUL` multiplies it. No third op. |
| `value` | `float` | for `MUL`, the factor itself (`0.0` = disabled, `1.5` = +50%), not `1.0 + x`. |

Resolution order per stat: base → all `ADD` summed → all `MUL` multiplied. Order-independent, so two Effects landing in the same frame can never disagree about the result.

### 2.2 `Stats` — const stat list (`src/gameplay/effects/stats.gd`)
| group | stats | applied by |
|---|---|---|
| cue | `cue_power_mult`, `cue_spin_radius_mult`, `cue_aim_wobble_deg`, `shot_clock_sec` | host → 01 cue API |
| ball / table | `cue_ball_mass_mult`, `cloth_friction_mult`, `cushion_restitution_mult`, `table_tilt_deg`, `pocket_radius_mult`, `pocket_oscillation_m`, `ball_type_shuffle_count` | host → `PhysicsSim` (01) |
| rule gates (`> 0` = on) | `rule_call_pocket` | host → 01 shot validation |
| player view (difficulty) | `player_view_light_level`, `player_view_fog_density`, `player_view_shake_amp` | **client-local, owner's screen only** |
| stream (income) | `stream_camera_bonus_mult`, `stream_viewer_gain_mult`, `stream_hype_gain_mult` | host → `StreamManager` (02) |
| round | `round_time_add_sec` | host → `GameLoop` (02) |

`cue_aim_wobble_deg` **floors at 0** after resolution — a stacked pile of "steadier" effects can never produce negative wobble, and 01 never reads a negative angle. `player_view_*` is deliberately split from `stream_camera_*`: darkening the shooter's screen is difficulty, dimming the broadcast is income, and the old single `camera_visibility` conflated them.
`cue_aim_wobble_deg` depends on the deferred Player module (how a wobbling aim is even presented on touch) — **flagged**; every catalog entry below works without it.

### 2.3 `Effect` (`Resource`)
| field | type | notes |
|---|---|---|
| `id` | `StringName` | unique |
| `source_kind` | `enum {DRINK, EVENT, WORLD}` | provenance, for UI grouping and the griefing guard (§3.4) |
| `target` | `enum {PLAYER, CUE, TABLE, BALL, POCKET, VIEW, STREAM}` | who the modifiers land on |
| `stat_modifiers` | `Array[StatMod]` | §2.1 |
| `duration_sec` | `float` | `0` = instant, `-1` = until `Round` end, `-2` = until the live `Shot` resolves |
| `stacking_rule` | `enum {REFRESH, IGNORE}` | `REFRESH` restarts the timer, `IGNORE` no-ops while an instance is live. Nothing accumulates. |
| `exclusive_group` | `StringName` | at most one live Effect per group per owner; a new one replaces the old (`ice_water` vs alcohol, `heckle` vs `heckle`). Empty = ungrouped. |
| `owner_peer_id` | `int` | who caused it, and — for `PLAYER`/`VIEW`/`CUE` targets — whose it is. `0` = the whole crew/table. |
| `visual_hook` | `StringName` | one tag, budgeted per §3.6 |

There is no `reward_multiplier_contribution`: reward lives on `Drink` and `Event`, which compose differently (§3.1). There is no `requires_host_apply`: it is derived, `target != VIEW`. One line, one source of truth, and a `VIEW` effect never needs a round trip.

### 2.4 `Drink` (`Resource`) — content only
02 owns the `ShopItem` schema, the price, the unlock gating and the purchase call. A `Drink` is what a `ShopItem` of category `drink` points at:

| field | type | notes |
|---|---|---|
| `id` | `StringName` | matches the `ShopItem` id |
| `effects` | `Array[Effect]` | upside and downside are separate entries in one array |
| `reward_mult` | `float` | this drink's factor in `Drink_Mult` (§3.1), default `1.0` |
| `serve_target` | `enum {SELF, NAMED_PLAYER}` | a non-shooter can buy at the bar and serve the shooter — that is the team play |
| `mid_round` | `bool` | buyable from the bar during a live Round (Drinks only; everything else is Intermission-only per P3) |
| `roll_on_use` | `bool` | `mystery_shot` only — see §3.5 |

### 2.5 `Event` (`Resource`)
| field | type | notes |
|---|---|---|
| `id`, `display_name` | `StringName`, `String` | |
| `tier` | `int` | `1` or `2`. Round 2 offers tier 1, Round 3 offers tier 2 (§3.2). |
| `effects` | `Array[Effect]` | |
| `reward_mult` | `float` | factor in `Event_Mult` (§3.1) |
| `min_night` | `int` | earliest `Night` this can be offered |
| `scripted_first` | `bool` | first occurrence is forced (not offered) at `min_night`, so the crew meets it once before it becomes a choice |
| `round_time_add_sec` | `float` | Round length delta, positive or negative — the honest knob the old `energy_drink` faked |
| `warning_lead_time_sec` | `float` | telegraph before activation, default `3.0 [tune]` |

### 2.6 `WorldInteraction` (`Resource`)
| field | type | notes |
|---|---|---|
| `id` | `StringName` | |
| `prop` | `StringName` | which bar `Interactable` exposes it: `table`, `camera`, `stool`, `jukebox`, `lights`, `rail`, `bar`, `crowd` |
| `hostile` | `bool` | true = it makes the live shot harder. Gates the guard in §3.4. |
| `cost` | `{kind: enum {HYPE, VIEWERS, CASH}, amount: float}` | paid on use, from the crew's shared pool |
| `payoff` | `{kind, amount, condition: StringName}` | paid back on `condition` (`always`, `shot_potted`, `shot_missed`) |
| `effect` | `Effect` | usually `duration_sec = -2` (dies with the shot) |
| `cooldown_sec` | `float` | per interactor |
| `requires_live_shot` | `bool` | true = only while balls are moving or the shooter is aiming |

## 3. Rules & formulas

### 3.1 Composition — one rule, one on-screen number
```
Drink_Mult = clamp(product(d.reward_mult for d in active Drinks), 1.0, 2.0 [tune])
Event_Mult = clamp(product(e.reward_mult for e in active Events), 1.0, 3.0 [tune])

Reward_Multiplier = Drink_Mult * Event_Mult          # max 6.0, no separate global cap
```
That product is the whole contract with 02, consumed at Shot resolution as the `Event_Hazard_Multiplier` slot (02 renames the slot to `Reward_Multiplier`). World interactions contribute **nothing** here: they pay in hype, viewers and cash (§3.4), which 02 already routes into the income formula. There is no trick-sync term — 5% of noise on a product that already swings 6× is not a mechanic.

### 3.2 Events are chosen before the Round, not rolled
- Round 1: no Event. Round 2: one tier-1 Event. Round 3: one tier-2 Event. Rounds must differ (D4) and this is how.
- At Intermission the crew is offered **3 eligible Events** of that tier (`min_night <= night_number`, not already used this Night), each showing its `reward_mult` and its `round_time_add_sec`. Everyone votes; ties and no-shows resolve to the host's pick after `20 s [tune]`. Singleplayer: the host picks straight off the list.
- `scripted_first` Events skip the vote the first time they are eligible — the crew meets `lights_out` before they can price it.
- A timed hazard nobody chose is beaten by not shooting; a hazard the crew *bought* for a stated multiplier is a bet. That is the whole reason the scheduler roll table is gone.

### 3.3 Drinks
- Bought as `ShopItem`s (02) at the bar: during Intermission, or mid-Round for `mid_round` drinks, by walking to the bar NPC (P3) — no menu teleport.
- Max `3 [tune]` live Drink effects per player; a 4th is refused with the reason named, not silently dropped.
- Drink effects hard-reset at Round end. Persisting them across the Intermission would make the shop screen the place you play the game.
- Every downside must change **how you play**, never just how accurate you are: call-your-pocket, no english, a heavy cue ball, a shot clock, or a buff handed to the player on your left. A wobble slider is a difficulty setting wearing a drink's name.

### 3.4 World interaction & the griefing guard
Non-shooters are free-roaming (P2). Everything they do to the table, the shooter or the stream goes through a `WorldInteraction` that spawns an `Effect` with their `owner_peer_id` stamped on it, so the shooter always sees *who*.

Guard, four layers, all cheap:
1. **Cost first.** Every `hostile` interaction spends shared hype/viewers/cash before it resolves. Griefing is self-taxing — you are spending the crew's quota to do it.
2. **Cooldown per interactor** (`cooldown_sec`), plus **max 2 hostile interactions per Turn across the whole crew**. The third is refused.
3. **`exclusive_group` on every hostile Effect** (`heckle`, `bump`, `blind`) — three players cannot stack the same harassment, and `shot_clock_sec` never resolves below `4.0 [tune]`.
4. **Host toggle** `hostile_world_interactions: {on, friends_only, off}` (default `on`; `off` leaves every non-hostile interaction working). Shooter-side mute of a named peer is a Player-module concern — deferred, noted.

Payoff is the other half: a bumped shot that still drops is drama, and the stream pays for drama. That is why the costs are refundable-with-interest on `shot_potted` rather than flat.

### 3.5 Drink catalog (content for 02's `ShopItem`s)
| id | cost `[tune]` | `reward_mult` | upside | downside — changes how you play |
|---|---:|---:|---|---|
| `beer` | $50 | 1.05 | `cue_power_mult MUL 1.10` | `cue_spin_radius_mult MUL 0.0` — no english at all |
| `whiskey_shot` | $90 | 1.20 | — | `rule_call_pocket ADD 1` — name the pocket or it does not score |
| `energy_drink` | $120 | 1.00 | `round_time_add_sec ADD 20` | `shot_clock_sec ADD 8` — every shot on a clock |
| `tequila_line` | $150 | 1.30 | — | `rule_call_pocket ADD 1`, `shot_clock_sec ADD 10` |
| `ice_water` | $40 | 1.00 | clears the `booze` `exclusive_group`, ends its downsides early | drops the cleared drinks' `reward_mult` with them |
| `house_special` | $200 | 1.40 | `cue_power_mult MUL 1.15` | `cue_ball_mass_mult MUL 1.6` — heavy rock, every position shot re-learned |
| `flaming_shot` | $180 | 1.25 | `cue_power_mult MUL 1.35` | `cushion_restitution_mult MUL 1.25` — rails come alive, safeties die |
| `neighbours_round` | $70 | 1.00 | gives the player on your left `reward_mult 1.25` for the Round | you get `stream_hype_gain_mult MUL 1.2` and nothing else |
| `bar_nuts` | $20 | 1.00 | `stream_hype_gain_mult MUL 1.15` | none — the cheap utility rung |
| `mystery_shot` | $60 | rolled | rolled on use (§below) | rolled on use |
| `moonshine` | $300 | 1.60 | `cue_power_mult MUL 1.25` | `cue_ball_mass_mult MUL 1.5` + `rule_call_pocket ADD 1`; `1 per Night [tune]` |

`mystery_shot` rolls **on use, not on purchase** — buying an unknown is a shop decision, drinking one is a table decision, and only the second is interesting. The shop shows the odds table before you buy: `40%` a `1.5` reward with a heavy cue ball, `35%` a `1.2` reward with a shot clock, `20%` a flat `1.0` with no downside, `5%` a `2.0` reward with call-pocket *and* no english `[tune]`. The roll is host-side and broadcast; the client never picks its own outcome.

### 3.6 Event catalog — hazards that change the task, plus two opportunities
| id | tier | `reward_mult` | `min_night` | `scripted_first` | `round_time_add_sec` | effect |
|---|---:|---:|---:|---|---:|---|
| `tilted_table` | 1 | 1.25 | 1 | no | 0 | `table_tilt_deg ADD 4` — constant drift to one rail; every roll must be re-read |
| `glass_cushions` | 1 | 1.30 | 1 | no | 0 | `cushion_restitution_mult MUL 1.35` — banks become the whole game |
| `bouncer` | 1 | 1.20 | 2 | yes | 0 | one Turn per Round: `shot_clock_sec ADD 6`, he is standing there |
| `crowd_roar` | 1 | 1.00 | 1 | no | `-15` | **opportunity** — next pot this Round scores ×2; short Round is the price |
| `moving_pockets` | 2 | 1.70 | 2 | yes | 0 | `pocket_radius_mult MUL 0.85`, `pocket_oscillation_m ADD 0.05` — aim at a moving hole |
| `ball_swap_chaos` | 2 | 1.60 | 3 | no | 0 | `ball_type_shuffle_count ADD 2` at Round start and once at half-time — value memory is worthless |
| `lights_out` | 2 | 1.80 | 3 | yes | `+20` | `player_view_light_level MUL 0.25`, `player_view_fog_density ADD 0.3` — **shooter's screen only**, the stream sees fine |
| `pocket_jackpot` | 2 | 1.00 | 2 | no | 0 | **opportunity** — one randomly chosen pocket pays ×3 all Round; every shot is now a routing problem |

The two opportunity Events carry `reward_mult 1.0` on purpose: the crew trades a smaller global multiplier for a targeted payoff, which is a real decision rather than a strictly-worse option. `power_flicker` is gone (a hazard that *lowers* payout is a punishment with extra steps); fog merged into `lights_out`, sticky/sway merged into `glass_cushions`, gangster-stare merged into `bouncer`.

### 3.7 World interaction catalog
| id | prop | hostile | cost | payoff | effect (`duration_sec`) | cooldown |
|---|---|---|---|---|---|---:|
| `bump_table` | table | yes | hype `-0.10` | viewers `+80` on `shot_potted` | `table_tilt_deg ADD 1.5` (`-2`, dies with the shot) | 20 s |
| `throw_drink` | bar | yes | the drink's `cost_cash` | viewers `+60` always | `player_view_shake_amp ADD 0.4` on the shooter (`-2`) | 15 s |
| `move_camera` | camera | no | — | `stream_camera_bonus_mult` re-scored on the pot (P2: best view of the potted pocket wins) | none — it moves a `Camera` node | 5 s |
| `kick_stool` | stool | yes | hype `-0.05` | viewers `+40` always | `shot_clock_sec ADD 6` on the shooter (`-2`) — stance is blocked, re-address the ball | 30 s |
| `jukebox` | jukebox | no | cash `-$40` | — | `stream_hype_gain_mult MUL 1.25` (`-1`, whole Round) | 1 per Round |
| `flick_lights` | lights | yes | viewers `-30` | viewers `+90` on `shot_potted` | `player_view_light_level MUL 0.4` on the shooter (`-2`) — client-local, no host round trip | 25 s |
| `lean_on_rail` | rail | no | — | — | `cushion_restitution_mult MUL 0.85` on that rail only (`-2`) — a deliberately dead cushion for a bank | 15 s |
| `heckle` | crowd | yes | hype `-0.08` | hype `+0.20`, viewers `+40` on `shot_missed` | `shot_clock_sec ADD 8` on the shooter (`-2`) | 25 s |
| `chalk_the_cue` | table | no | cash `-$10` | — | `cue_spin_radius_mult MUL 1.10` on the shooter's next shot (`-2`) | 20 s |

Nine entries, three of them pro-social, so the bar is not only a heckling machine. Every hostile row is `exclusive_group`-tagged and counts against the per-Turn cap of 2 (§3.4).

### 3.8 Mobile budget (P1)
Effects are the easiest place to lose a phone frame, so they are capped by design, not by profiling later:
- **No per-frame shader stacks.** `player_view_*` is one `CanvasLayer` with one pre-baked full-screen material whose uniforms are set by `EffectManager`; three simultaneous view effects write three uniforms, never three passes.
- **`visual_hook` budget: 2 concurrent hooks, at most 1 full-screen.** A third request replaces the oldest of the same kind. Hooks are pre-instanced at Round start and pooled — no runtime `load()`, no allocation on the shot path.
- Table/ball Effects mutate existing `PhysicsSim` scalars only. Nothing here adds a body, a light, or a particle emitter mid-shot; `jukebox` moves an audio-bus parameter, it does not spawn sources.
- `VIEW` effects never round-trip to the host, so a `flick_lights` on a 4G phone costs one RPC and zero physics work.

## 4. Godot implementation sketch
Per D7 there is no autoload here — these are children of `MainLevel`, so "new campaign" is a scene reload.

- `src/gameplay/effects/effect_manager.gd` (`EffectManager`) — live-effect lists keyed by `target` + `owner_peer_id`, stacking and `exclusive_group` resolution, stat resolution (§2.1), `Reward_Multiplier` (§3.1). Applies `target != VIEW` on host only; `VIEW` is applied by the owning client with no round trip.
- `src/gameplay/effects/event_scheduler.gd` (`EventScheduler`) — name kept from D7, but it no longer rolls: it builds the eligible offer list (§3.2), runs the vote, and applies the winner at Round start.
- `src/gameplay/effects/stats.gd` — the const stat list (§2.2), asserted against at resource load.
- `src/gameplay/bar/interactable.gd` — `Area3D` + prompt on every prop; holds a `WorldInteraction`, enforces cooldown and the §3.4 guard client-side for responsiveness, host-side for truth.
- `src/resources/effect/effect.gd`, `stat_mod.gd`, `drink.gd`, `event.gd`, `world_interaction.gd` — `.tres` instances under `src/resources/{drink,event,world}/`.
- `src/ui/EventVote.tscn` — the three-card Intermission vote. Bar purchase UI belongs to 02's `Shop`.

## 5. Interfaces to other modules

### Signals (`EffectManager`)
- `effect_applied(effect_id: StringName, target: int, owner_peer_id: int, duration_sec: float)`
- `effect_expired(effect_id: StringName, target: int, owner_peer_id: int)`
- `reward_multiplier_changed(new_value: float)`

### Signals (`EventScheduler`)
- `event_offer_ready(round_index: int, tier: int, event_ids: Array[StringName])`
- `event_applied(event_id: StringName, tier: int, reward_mult: float)`
- `event_ended(event_id: StringName)`

### To 01 (physics/table/balls)
- Host-side `StatMod`s write into `PhysicsSim` scalars owned by 01 (`cloth_friction_mult`, `cushion_restitution_mult`, `table_tilt_deg`, `pocket_radius_mult`, `pocket_oscillation_m`, `cue_ball_mass_mult`). 03 offsets constants, never redefines them.
- `rule_call_pocket > 0` makes 01's shot validation require a declared pocket; a pot into any other pocket scores `0` and is not a foul.
- `shot_clock_sec` and `cue_power_mult` / `cue_spin_radius_mult` are read by 01's cue API, which must stay touch-agnostic (P1).
- `ball_type_shuffle_count` asks 01 to re-roll that many non-cue `BallType`s in place.

### To 02 (economy/loop)
- `EffectManager.get_reward_multiplier() -> float` at Shot resolution — call it, never cache it.
- 02 owns `ShopItem`: price, unlock, `try_spend_cash`. 03 owns what a Drink *does* (§3.5).
- World-interaction costs and payoffs go through `StreamManager.add_viewers/add_hype` and `EconomyManager.try_spend_cash`; 03 never writes those fields directly.
- `round_time_add_sec` is handed to `GameLoop` at Round start, before the timer is armed.
- `stream_camera_bonus_mult` modifies the camera score 02 computes; 03 does not pick the live camera.

### To 04 (architecture/netcode)
- `@rpc("any_peer", "reliable") request_world_interaction(interaction_id: StringName)` — client to host; host validates cost, cooldown and the §3.4 guard, then broadcasts.
- `@rpc("authority", "reliable") apply_effect(effect_id: StringName, owner_peer_id: int)` and `apply_event(event_id: StringName)`.
- `@rpc("any_peer", "reliable") submit_event_vote(event_id: StringName)`.
- `VIEW`-target Effects are broadcast for presentation but applied locally by the owner — they never enter the physics path, so they need no host tick.

## 6. Open questions
1. Should a hostile interaction's viewer payoff scale with the shot's difficulty (bump on a long thin cut pays more), or stay flat? Flat is shipping.
2. Does the per-Turn hostile cap of 2 want to be per-Turn or per-Round at 4 players? Needs a playtest, not a decision.
3. Should `ice_water` refund part of the cleared drink's cost, or only its downside?

## 7. MVP cut vs later
| Feature | In MVP (Phase 1) | Post-MVP / Later |
|---|---|---|
| Effect / StatMod schema | Full, with the const stat list asserted at load | Conditional effects, effect chaining |
| Drinks | 11 above, `visual_hook` tags only | Mixing/crafting, per-drink shaders inside the §3.8 budget |
| Events | 8 above, pre-Round vote | Narrative Event chains, tier 3 for Endless |
| World interaction | 9 above, guard §3.4 | Physical prop throwing, per-peer shooter mute (needs Player module) |
| Composition | `Drink_Mult × Event_Mult`, caps 2.0 / 3.0 | Per-Night dynamic caps |
