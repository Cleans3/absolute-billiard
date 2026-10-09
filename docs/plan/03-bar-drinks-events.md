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

Resolution order per stat: base → all `ADD` summed → all `MUL` multiplied. Order-independent, so two Effects landing in the same frame can never disagree about the result. The `stat` setter asserts against `Stats.ALL` when the `.tres` loads.

### 2.2 `Stats` — const stat list (`src/gameplay/effects/stats.gd`)
| group | stats | applied by |
|---|---|---|
| cue | `cue_power_mult`, `cue_spin_radius_mult`, `cue_aim_wobble_deg`, `shot_clock_sec` | host → 01 cue API |
| ball / table | `cue_ball_mass_mult`, `cloth_friction_mult`, `cushion_restitution_mult`, `table_tilt_deg`, `pocket_radius_mult`, `pocket_oscillation_m`, `ball_type_shuffle_count` | host → `PhysicsSim` (01) |
| rule gates (`> 0` = on) | `rule_call_pocket` | host → 01 shot validation |

**Consumers (built, `RoundDirector`, REQ#rules-1).** `rule_call_pocket`: `shot_validator` rejects a request whose `ShotIntent.called_pocket` is not a real pocket (`call_pocket`); a pot elsewhere scores 0, never a foul. `shot_clock_sec`: armed at each Turn for the shooter (`> 0`); at 0 the host records a whiff foul (no strike, the Shot costs its budget slot and 02's foul viewer drop). `pocket_radius_mult`: `Table` rebuilds its jaws and chutes from `TableGeometry.layout(spec, mult)` at Round setup / effect change (deferred past a live Shot). `pocket_oscillation_m`: each chute slides ±m along its rail, `sin(2π·t/6 s + phase(round_seed, pocket_id))` — a pure function, so clients need no packets: chute (capture) and liner (picture) share the clock `PhysicsSim.pocket_time()`, clients drawn at playback time (04 §2.4). `ball_type_shuffle_count`: `EventScheduler.ball_shuffle_requested` re-rolls that many object balls' types in place (seeded from the Round; waits out a live Shot; clients get `_reroll_rpc`). `pocket_jackpot` / `crowd_roar` stay `EffectManager.pot_bonus()` (02 reads it), nothing more in 01.
| player view (difficulty) | `player_view_light_level`, `player_view_fog_density`, `player_view_shake_amp` | **client-local, owner's screen only** |
| stream (income) | `stream_camera_bonus_mult`, `stream_viewer_gain_mult`, `stream_hype_gain_mult` | host → `StreamManager` (02) |
| round | `round_time_add_sec` | host → `GameLoop` (02) |
| player | `player_stumble_per_min` (base `0`, target `PLAYER`) | host → `PlayerSpawner.knock` (06 P15): the drinker is knocked down this many times a minute, then gets up after ~2 s. Mystery Drinks' debuff (§3.5) |

`cue_aim_wobble_deg` **floors at 0** and `shot_clock_sec` at `4.0 [tune]` after resolution — but only when at least one modifier touched the stat, so an untouched stat returns its base (`shot_clock_sec` base `0` = no clock, `ADD 8` = an 8 s clock). A stacked pile of "steadier" effects can never produce negative wobble, and 01 never reads a negative angle. `player_view_*` is deliberately split from `stream_camera_*`: darkening the shooter's screen is difficulty, dimming the broadcast is income, and the old single `camera_visibility` conflated them.
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
| `tag` | `StringName` | classification only (`booze`); never exclusive. |
| `clears_tag` | `StringName` | instant Effects: ends every live Effect carrying this tag on the subject (`ice_water` → `booze`). |
| `visual_hook` | `StringName` | one tag, budgeted per §3.6 |

`owner_peer_id` (who caused it) and `target_id` (who it lands on) are **per-instance**: they live on the live instance in `EffectManager` and in the `apply_effect` RPC, never on the shared resource. `target_id` is the subject peer for `PLAYER`/`CUE`/`VIEW` (`0` = crew-wide; a crew-wide `VIEW` Effect shows on the current shooter's screen only), the rail id for a `TABLE` Effect scoped to one rail (`lean_on_rail`), and `0` otherwise. Player-scoped table/ball stats (`cue_ball_mass_mult`, `cushion_restitution_mult` from a drink) use target `CUE`: `EffectManager` resolves them for the current shooter and pushes them to `PhysicsSim` whenever they change or the shooter rotates.

There is no `reward_multiplier_contribution`: reward lives on `Drink` and `Event`, which compose differently (§3.1). There is no `requires_host_apply`: it is derived, `target != VIEW`. One line, one source of truth, and a `VIEW` effect never needs a round trip.

### 2.4 `Drink` (`Resource`) — content only
02 owns the `ShopItem` schema, the price, the unlock gating and the purchase call. A `Drink` is what a `ShopItem` of category `drink` points at:

| field | type | notes |
|---|---|---|
| `id` | `StringName` | matches the `ShopItem` id |
| `display_name`, `description` | `String` | the card's title and its flavour line |
| `tier` | `DrinkTier.Tier` | `COMMON \| UNCOMMON \| RARE \| EPIC \| LEGENDARY \| MYSTERY` (02 §2): how often the Bartender stocks it and how it is framed (06 P17) |
| `effects` | `Array[Effect]` | upside and downside are separate entries in one array |
| `reward_mult` | `float` | this drink's factor in `Drink_Mult` (§3.1), default `1.0` |
| `serve_target` | `enum {SELF, NAMED_PLAYER}` | a non-shooter can buy at the bar and serve the shooter — that is the team play |
| `mid_round` | `bool` | buyable from the bar during a live Round (Drinks only; everything else is Intermission-only per P3) |
| `neighbour_reward_mult` | `float` | `!= 1.0`: the seat-left player (`NetManager.seat_order()`, wrapping) gets this factor for the Round. Takes no drink slot |
| `night_limit` | `int` | `0` = unlimited; per player per Night (the Legendary Drinks = 1) |
| `cost_cash` | `int` | catalog price `[tune]` — 02's `ShopItem` may override; `throw_drink` spends it |

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
| `warning_lead_time_sec` | `float` | telegraph before activation, default `3.0 [tune]`; emitted with `event_warning` for a forced `scripted_first` Event (a voted one is telegraphed by the vote itself) |
| `opportunity`, `opportunity_mult` | `enum {NONE, NEXT_POT, RANDOM_POCKET}`, `float` | the two opportunity Events' targeted payoff (§3.6), read through `EffectManager.pot_bonus()` |

### 2.6 `WorldInteraction` (`Resource`)
| field | type | notes |
|---|---|---|
| `id` | `StringName` | |
| `prop` | `StringName` | which bar `Interactable` exposes it: `table`, `camera`, `stool`, `jukebox`, `lights`, `rail`, `bar`, `crowd` |
| `hostile` | `bool` | true = it makes the live shot harder. Gates the guard in §3.4. |
| `cost` | `PoolDelta {kind: enum {HYPE, VIEWERS, CASH}, amount}` | paid on use, from the crew's shared pool; `amount` is a positive magnitude. `throw_drink` pays the drink's `cost_cash` instead |
| `payoffs` | `Array[PoolDelta]` (`kind`, `amount`, `condition`) | paid back on `condition` (`always` at use, `shot_potted`, `shot_missed` when the Shot resolves); an array because `heckle` pays hype *and* viewers |
| `effect` | `Effect` | usually `duration_sec = -2` (dies with the shot) |
| `cooldown_sec` | `float` | per interactor |
| `once_per_round` | `bool` | crew-wide, per Round (`jukebox`) |
| `requires_live_shot` | `bool` | true = only during a live Round (balls moving or the shooter aiming) |

## 3. Rules & formulas

### 3.1 Composition — one rule, one on-screen number
```
Drink_Mult = clamp(product(d.reward_mult for d in active Drinks), 1.0, 2.0 [tune])
Event_Mult = clamp(product(e.reward_mult for e in active Events), 1.0, 3.0 [tune])

Reward_Multiplier = Drink_Mult * Event_Mult          # max 6.0, no separate global cap
```
That product is the whole contract with 02, consumed at Shot resolution as the `Event_Hazard_Multiplier` slot (02 renames the slot to `Reward_Multiplier`). World interactions contribute **nothing** here: they pay in hype, viewers and cash (§3.4), which 02 already routes into the income formula. There is no trick-sync term — 5% of noise on a product that already swings 6× is not a mechanic. The two opportunity Events' payoff is **not** in this product: `EffectManager.pot_bonus()` (`crowd_roar` ×2 on the first paying Shot, `pocket_jackpot` ×3 on a Shot that potted in the chosen pocket) is a separate factor `award_shot_reward` multiplies in at Shot level, until ECON prices each pot on its own.

### 3.2 Events are chosen before the Round, not rolled
- Round 1: no Event. Round 2: one tier-1 Event. Round 3: one tier-2 Event. Rounds must differ (D4) and this is how.
- At Intermission the crew is offered **3 eligible Events** of that tier (`min_night <= night_number`, not already used this Night), each showing its `reward_mult` and its `round_time_add_sec`. Everyone votes; ties and no-shows resolve to the host's pick after `20 s [tune]`. Singleplayer: the host picks straight off the list.
- `scripted_first` Events skip the vote the first time they are eligible — the crew meets `lights_out` before they can price it.
- A timed hazard nobody chose is beaten by not shooting; a hazard the crew *bought* for a stated multiplier is a bet. That is the whole reason the scheduler roll table is gone.

### 3.3 Drinks
- Bought as `ShopItem`s (02) from the Bartender NPC's random shelf (06 P17, 02 §3.6): during Intermission, or mid-Round for `mid_round` drinks, by walking to the counter — no menu teleport. A Drink that is not on the current shelf, or is sold out, cannot be bought.
- Max `3 [tune]` live Drinks per player; a 4th is refused with the reason named (`serve_drink` returns `drink_cap` and emits `drink_refused`; also `intermission_only`, `night_limit`), not silently dropped. Re-buying a live drink refreshes it and needs no slot: nothing accumulates. A drink whose Effects have all ended (`ice_water`, timers) stops counting for its slot and its `reward_mult`.
- `mid_round` drinks (the `mid` column of §3.5 `[tune]`) may be bought during a live Round; the rest are Intermission-only.
- Drink effects hard-reset at Round end. Persisting them across the Intermission would make the shop screen the place you play the game.
- Every downside must change **how you play**, never just how accurate you are: call-your-pocket, no english, a heavy cue ball, a shot clock, or a buff handed to the player on your left. A wobble slider is a difficulty setting wearing a drink's name.

### 3.4 World interaction & the griefing guard
Non-shooters are free-roaming (P2). Everything they do to the table, the shooter or the stream goes through a `WorldInteraction` that spawns an `Effect` with their `owner_peer_id` stamped on it, so the shooter always sees *who*.

Guard, four layers, all cheap. Gate order on the host: toggle → live Round → prop + reach (`2.0 m [tune]`) → cooldown → per-Turn cap → cost (last, so a rejection never charges) → Effect + payoffs. A Turn ends with its Shot; the shooter cannot use a hostile interaction:
1. **Cost first.** Every `hostile` interaction spends shared hype/viewers/cash before it resolves. Griefing is self-taxing — you are spending the crew's quota to do it.
2. **Cooldown per interactor** (`cooldown_sec`), plus **max 2 hostile interactions per Turn across the whole crew**. The third is refused.
3. **`exclusive_group` on every hostile Effect** (`heckle`, `bump`, `blind`) — three players cannot stack the same harassment, and `shot_clock_sec` never resolves below `4.0 [tune]`.
4. **Host toggle** `hostile_world_interactions: {on, friends_only, off}` (default `on`; `off` leaves every non-hostile interaction working; `friends_only` lets the host and a host-managed peer list act). Shooter-side mute of a named peer is a Player-module concern — deferred, noted.

Payoff is the other half: a bumped shot that still drops is drama, and the stream pays for drama. That is why the costs are refundable-with-interest on `shot_potted` rather than flat.

### 3.5 Drink catalog (content for 02's `ShopItem`s)
26 Drinks on six tiers (06 P17). Every tier holds at least 3 Drinks, Mystery 5. Price scales with tier; `reward` is the Drink's `reward_mult`; `mid` = `mid_round`. Upside and downside read exactly as the card prints them (`StatText`: buffs green, debuffs red). Round-length Drinks (`round_time_add_sec`) are Intermission-only because the timer arms at Round start.

| id | tier | cost `[tune]` | reward | mid | upside | downside — changes how you play |
|---|---|---:|---:|---|---|---|
| `beer` | Common | $50 | 1.05 | yes | Cue power +10% | English: none |
| `bar_nuts` | Common | $20 | 1.00 | yes | Hype gains +15% | — |
| `ice_water` | Common | $40 | 1.00 | yes | Ends booze effects | — |
| `soda_pop` | Common | $35 | 1.00 | no | Round time +10 s | — |
| `pretzels` | Common | $25 | 1.00 | yes | Viewer gains +10% | — |
| `pickle_juice` | Common | $35 | 1.00 | yes | Cue power +6% | English -20% |
| `whiskey_shot` | Uncommon | $90 | 1.20 | yes | — | Call your pocket |
| `energy_drink` | Uncommon | $120 | 1.00 | no | Round time +20 s | Shot clock: 8 s |
| `neighbours_round` | Uncommon | $70 | 1.00 | yes | Hype gains +20%, Left neighbour earns x1.25 | — |
| `pale_ale` | Uncommon | $75 | 1.10 | yes | Cue power +8% | Rail bounce +10% |
| `rum_and_cola` | Uncommon | $100 | 1.15 | yes | Viewer gains +20% | Cue power -10% |
| `tequila_line` | Rare | $150 | 1.30 | no | — | Call your pocket, Shot clock: 10 s |
| `flaming_shot` | Rare | $180 | 1.25 | no | Cue power +35% | Rail bounce +25% |
| `vodka_tonic` | Rare | $130 | 1.20 | no | Cue power +20% | Shot clock: 10 s |
| `green_fairy` | Rare | $160 | 1.30 | no | Hype gains +35% | Screen fog +0.25 |
| `house_special` | Epic | $200 | 1.40 | no | Cue power +15% | Cue ball weight +60% |
| `tiki_torch` | Epic | $240 | 1.45 | no | Pocket size +20% | Rail bounce +30% |
| `blue_lagoon` | Epic | $220 | 1.40 | no | Viewer gains +40%, Hype gains +25% | English -50% |
| `moonshine` | Legendary | $300 | 1.60 | no | Cue power +25%; 1 per Night | Cue ball weight +50%, Call your pocket |
| `dragons_breath` | Legendary | $400 | 1.80 | no | Cue power +50%, Viewer gains +50%; 1 per Night | Cue ball weight +60% |
| `gold_flake_champagne` | Legendary | $500 | 2.00 | no | Round time +30 s, Pocket size +20%; 1 per Night | — |
| `static_shot` | Mystery | $80 | 1.50 | yes | Cue power +10% | Stumbles +2/min |
| `back_alley_brew` | Mystery | $110 | 1.60 | no | Viewer gains +50% | Screen light -50%, Stumbles +1/min |
| `void_juice` | Mystery | $120 | 1.80 | no | Cue power +25% | Call your pocket, English: none |
| `cursed_cola` | Mystery | $70 | 1.50 | no | Round time +25 s | Cue ball weight +50% |
| `quantum_ale` | Mystery | $100 | 1.30 | no | Pocket size +30%, Hype gains +60% | Pocket drift +0.06 m, Shot clock: 10 s |

**Mystery (06 P17).** The Mystery tier is the old `mystery_shot` made honest: a red card with glitching text that shows **at least one buff and one debuff** (a `reward_mult` above 1 counts as a buff; the debuff is always a real stat Effect; a probe fails any Mystery Drink that shows only one side). The buyer decides whether the buff is worth the cost; there is no roll. `player_stumble_per_min` (§2.2) is the signature debuff: `static_shot` knocks the drinker down twice a minute and `back_alley_brew` once.

**`mystery_shot` is retired.** Its roll-on-use design hid the effects until the drink was drunk, which P17's "shows one buff and one debuff" forbids, so the Drink, its four outcome Drinks and the `roll_on_use` / `roll_table` / `roll_weights` fields and `EffectManager._roll` are gone. Its outcomes live on as explicit Mystery Drinks: `cursed_cola` (heavy cue ball, long Round), `void_juice` (call-pocket and no english for the biggest reward), `static_shot` and `quantum_ale` (a shot clock with a wide, drifting pocket).

**Targets.** Cue and rule stats ride a `CUE` Effect (per drinker, resolved for the current shooter); `stream_*` ride a `STREAM` Effect; `player_view_*` a `VIEW` Effect (the drinker's own screen); `round_time_add_sec` and `player_stumble_per_min` a `PLAYER` Effect. A `TABLE` target must not be used on a Drink: the Drink's Effects carry the drinker as `target_id`, which `TABLE` reads as a rail id. `pocket_radius_mult` / `pocket_oscillation_m` are read crew-wide (`ALL_PEERS`), so a `CUE` Effect with them reshapes the pockets for everyone this Round.

### 3.6 Event catalog — hazards that change the task, plus two opportunities
| id | tier | `reward_mult` | `min_night` | `scripted_first` | `round_time_add_sec` | effect |
|---|---:|---:|---:|---|---:|---|
| `tilted_table` | 1 | 1.25 | 1 | no | 0 | `table_tilt_deg ADD 4` — constant drift to one rail; every roll must be re-read |
| `glass_cushions` | 1 | 1.30 | 1 | no | 0 | `cushion_restitution_mult MUL 1.35` — banks become the whole game |
| `bouncer` | 1 | 1.20 | 2 | yes | 0 | one Turn per Round: `shot_clock_sec ADD 6` with duration `-2`, applied at Round start so it dies with the first Shot |
| `crowd_roar` | 1 | 1.00 | 1 | no | `-15` | **opportunity** — next pot this Round scores ×2; short Round is the price |
| `moving_pockets` | 2 | 1.70 | 2 | yes | 0 | `pocket_radius_mult MUL 0.85`, `pocket_oscillation_m ADD 0.05` — aim at a moving hole |
| `ball_swap_chaos` | 2 | 1.60 | 3 | no | 0 | `ball_type_shuffle_count ADD 2` at Round start and once at half-time — value memory is worthless |
| `lights_out` | 2 | 1.80 | 3 | yes | `+20` | `player_view_light_level MUL 0.25`, `player_view_fog_density ADD 0.3` — **shooter's screen only** (crew-wide `VIEW` Effect, shown only on the current shooter's overlay), the stream sees fine |
| `pocket_jackpot` | 2 | 1.00 | 2 | no | 0 | **opportunity** — one randomly chosen pocket pays ×3 all Round; every shot is now a routing problem |

The two opportunity Events carry `reward_mult 1.0` on purpose: the crew trades a smaller global multiplier for a targeted payoff, which is a real decision rather than a strictly-worse option. `power_flicker` is gone (a hazard that *lowers* payout is a punishment with extra steps); fog merged into `lights_out`, sticky/sway merged into `glass_cushions`, gangster-stare merged into `bouncer`.

### 3.7 World interaction catalog
| id | prop | hostile | cost | payoff | effect (`duration_sec`) | cooldown |
|---|---|---|---|---|---|---:|
| `bump_table` | table | yes | hype `-0.10` | viewers `+80` on `shot_potted` | `table_tilt_deg ADD 1.5` (`-2`, dies with the shot) | 20 s |
| `throw_drink` | bar | yes | the drink's `cost_cash` and one unit off the Bartender's shelf (`EconomyManager.try_throw`; `sold_out` / `not_stocked` refuse) | viewers `+60` always | `player_view_shake_amp ADD 0.4` on the shooter (`-2`) | 15 s |
| `move_camera` | camera | no | — | `stream_camera_bonus_mult` re-scored on the pot (P2: best view of the potted pocket wins) | none — it moves a `Camera` node | 5 s |
| `kick_stool` | stool | yes | hype `-0.05` | viewers `+40` always | `shot_clock_sec ADD 6` on the shooter (`-2`) — stance is blocked, re-address the ball | 30 s |
| `jukebox` | jukebox | no | cash `-$40` | — | `stream_hype_gain_mult MUL 1.25` (`-1`, whole Round) | 1 per Round |
| `flick_lights` | lights | yes | viewers `-30` | viewers `+90` on `shot_potted` | `player_view_light_level MUL 0.4` on the shooter (`-2`) — client-local, no host round trip | 25 s |
| `lean_on_rail` | rail | no | — | — | `cushion_restitution_mult MUL 0.85` on that rail only (`-2`) — a deliberately dead cushion for a bank | 15 s |
| `heckle` | crowd | yes | hype `-0.08` | hype `+0.20`, viewers `+40` on `shot_missed` | `shot_clock_sec ADD 8` on the shooter (`-2`) | 25 s |
| `chalk_the_cue` | table | no | cash `-$10` | — | `cue_spin_radius_mult MUL 1.10` on the shooter's next shot (`-2`) | 20 s |

**Lean feedback (06 P25, C13).** `LeanFeedback` (a `MainLevel` child, `src/gameplay/player/lean_feedback.gd`) listens to `WorldInteractions.interaction_applied`, which every peer gets: for `lean_on_rail` it starts a `2 s` lean on the presser's `Humanoid` (local and puppet; 08 §2.7) toward the middle of that rail's wood and shows a toast on every peer naming who, which rail (`west rail`, `north-west rail`, …, the long rails being two segments split by the side pockets) and the strength read from the Effect (`"<name> leaned on the west rail: cushion 15% dead"`). A glowing marker lies along each rail whose `EffectManager.rail_restitution_mult` is not 1, recomputed on `effect_applied` / `effect_expired` — derived from the live Effect state, not from the press, so a client that resumed (`_resync_effects_rpc` → `apply_local`) rebuilds it, and it goes with the Effect when the Shot resolves (`SHOT` expiry). No RPC is added. `tests/player/lean_probe.gd`.

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
- `src/gameplay/effects/stats.gd` — the const stat list (§2.2), base values, floors, sim-pushed and full-screen-hook lists; `catalog.gd` (`FxCatalog`) — explicit preloads of every `.tres` and the Effect registry (`apply_effect` resolves ids through it).
- `src/gameplay/bar/world_interactions.gd` (`WorldInteractions`) — the RPCs, host validation and the guard; `bar.gd` (`Bar`) places the `Interactable`s.
- `src/ui/ViewOverlay.tscn` + `src/shaders/player_view.gdshader` — one `ColorRect`, one shader, three uniforms; hidden (no pass) while nothing is active.
- `src/gameplay/bar/interactable.gd` — `Area3D` + prompt on every prop; holds a `WorldInteraction`, enforces cooldown and the §3.4 guard client-side for responsiveness, host-side for truth.
- `src/resources/effect/effect.gd`, `stat_mod.gd`, `drink.gd`, `event.gd`, `world_interaction.gd` — `.tres` instances under `src/resources/{drink,event,world}/`.
- `src/ui/EventVote.tscn` — the three-card Intermission vote; each card carries the hazard's icon (`IconCatalog.hazard`). The bar purchase UI is 02's `BartenderMenu` (it prints `src/gameplay/effects/stat_text.gd`'s `StatText` lines for every Drink).
- `src/ui/icons/icon_catalog.gd` (`IconCatalog`) + `src/tools/ui_art_icons.py` — **icons (polish 2 C12, C15).** `IconCatalog.drink(Drink)`, `.hazard(Event)` and `.upgrade(ShopItem)` return a 128 px texture and are never null: `assets/ui/{drink,hazard,upgrade}/<id>.svg`, generated by `python3 src/tools/ui_art.py` (then `godot --headless --import`). A Drink's icon is composed, not drawn one by one: a glass silhouette picked for the kind of drink (shot, tall shot, rocks, highball, collins, pint, mug, pilsner, flute, coupe, martini, snifter, goblet, hurricane, pitcher, tiki mug, jar, jug, bottle, can, flask, snack bowl, pretzel) + a liquid colour + decor (foam, ice, lime, umbrella, flame, bubbles, gold flakes …); Mystery Drinks carry a glitch mark. The **tier rim** is not in the file: `BartenderMenu` draws it from `Drink.tier`. A new Drink, Event or Upgrade needs one row in `ui_art_icons.py`; `tests/ui/shop_ui_probe.gd` fails on a missing file and on two catalog rows sharing a picture (an id without a file would show the `unknown` icon).
- `src/gameplay/effects/stat_text.gd` — `StatText`: a `StatMod` / `Drink` → text lines tagged buff / debuff / neutral; every `Stats.ALL` entry needs a row.

## 5. Interfaces to other modules

### Signals (`EffectManager`)
- `effect_applied(effect_id: StringName, target: int, owner_peer_id: int, duration_sec: float)`
- `effect_expired(effect_id: StringName, target: int, owner_peer_id: int)`
- `reward_multiplier_changed(new_value: float)`
- `live_changed()` — any Effect, Drink or Event came or went; read side `live_drinks() -> [{drink, peer_id, gift}]`, `live_events() -> [Event]` (the wall Blackboard, 08 §2.8)
- `drink_refused(drink_id, peer_id, reason)`, `shooter_changed(peer_id)`, `visual_hook_started/stopped(tag)`

Timers live here, not in `PhysicsSim`: `-2` expires on `RoundDirector.shot_ended`, `-1` on `GameLoop.round_ended`, seconds on a local countdown — every peer expires from its own signals, so there is no expiry RPC. `PhysicsSim` is only a sink (`stat_source`, `set_stat`, `set_rail_restitution_mult`, `set_tilt_direction`).

### Signals (`EventScheduler`)
- `event_offer_ready(round_index: int, tier: int, event_ids: Array[StringName])`
- `event_applied(event_id: StringName, tier: int, reward_mult: float)`
- `event_ended(event_id: StringName)`
- `event_warning(event_id, lead_time_sec)`, `ball_shuffle_requested(count)` (Round start and half-time; RoundDirector re-rolls that many `BallType`s)

### To 01 (physics/table/balls)
- Host-side `StatMod`s write into `PhysicsSim` scalars owned by 01 (`cloth_friction_mult`, `cushion_restitution_mult`, `table_tilt_deg`, `pocket_radius_mult`, `pocket_oscillation_m`, `cue_ball_mass_mult`). 03 offsets constants, never redefines them.
- `rule_call_pocket > 0` makes 01's shot validation require a declared pocket; a pot into any other pocket scores `0` and is not a foul.
- `shot_clock_sec` and `cue_power_mult` / `cue_spin_radius_mult` are read by 01's cue API, which must stay touch-agnostic (P1).
- `ball_type_shuffle_count` asks 01 to re-roll that many non-cue `BallType`s in place.

### To 02 (economy/loop)
- `EffectManager.get_reward_multiplier() -> float` at Shot resolution — call it, never cache it.
- 02 owns `ShopItem`: price, unlock, `try_spend_cash`. 03 owns what a Drink *does* (§3.5).
- World-interaction costs and payoffs go through `StreamManager.add_viewers/add_hype` and `EconomyManager.try_spend_cash`; 03 never writes those fields directly.
- `round_time_add_sec` is handed to `GameLoop` at Round start, before the timer is armed: `_start_round` calls `EventScheduler.begin_round(round_index)`, which applies the chosen Event and returns its `round_time_add_sec` plus live Effects' (`energy_drink`).
- `EconomyManager.award_shot_reward` reads `EffectManager.get_reward_multiplier() × pot_bonus()` for the `Event_Mult` slot (duck-typed sibling lookup, `1.0` when absent). `stream_*` stats are resolved by `EffectManager.get_stat` and **consumed by ECON** in wave 2 (`StreamManager` gains are not scaled yet).
- `stream_camera_bonus_mult` modifies the camera score 02 computes; 03 does not pick the live camera.

### To 04 (architecture/netcode)
- On `MainLevel/WorldInteractions`: `request_world_interaction(kind, target_id, payload)` (any_peer, call_remote) — client to host; host validates §3.4, then `world_interaction_applied` (authority, call_local) or `world_interaction_rejected` (to the requester). `kind` is a `WorldInteraction` id, or `bar_buy` / `bar_serve` (validated, signalled as `bar_purchase_requested`, nothing charged — the Shop buys), or `go_live` (the GO LIVE pedestal, 02 §3.1: validated for phase Intermission and reach, then `GameLoop.toggle_ready`; no resource, so the 9 interactions the effects probe counts are unchanged). A rejection also carries `wait_sec` for `cooldown`, and `WaitText` words every reason ("Chalk the cue is cooling down: 14 s left").
- `apply_effect(effect_id, owner_peer_id, target_id, duration_ms)` (authority, call_local, ch3): `duration_ms` `0` instant, `-1` Round, `-2` Shot. `apply_event(event_id, round_index, pocket_id)` (authority, call_local): every peer applies the Event's Effects itself, so Events need no `apply_effect` fan-out.
- `submit_event_vote(event_id)` (any_peer, call_local) and `event_offer(round_index, tier, event_ids)` (authority, call_local). A single-id offer is a forced `scripted_first` Event: an announcement, not a vote.
- `VIEW`-target Effects are broadcast for presentation but applied locally by the owner — they never enter the physics path, so they need no host tick.

## 6. Open questions — ruled 2026-09-30 (Cleanse via alpha, R3)
1. Hostile viewer payoff stays **flat**, not scaled by shot difficulty.
2. The hostile cap stays **2 per Turn**, no per-Round cap; revisit after a 4-player playtest.
3. `ice_water` refunds **nothing**: it ends the downsides and takes the cleared drinks' `reward_mult` with them.

Still open: `aim_wobble` presentation (needs Player); who prices each pot for `pot_bonus` (ECON). `lean_on_rail`'s `target_id` is 1 + the index in `Stats.RAILS` (the six `PhysicsSim` rail ids).

## 7. MVP cut vs later
| Feature | In MVP (Phase 1) | Post-MVP / Later |
|---|---|---|
| Effect / StatMod schema | Full, with the const stat list asserted at load | Conditional effects, effect chaining |
| Drinks | 26 above on six tiers, `visual_hook` tags only | Mixing/crafting, per-drink shaders inside the §3.8 budget |
| Events | 8 above, pre-Round vote | Narrative Event chains, tier 3 for Endless |
| World interaction | 9 above, guard §3.4 | Physical prop throwing, per-peer shooter mute (needs Player module) |
| Composition | `Drink_Mult × Event_Mult`, caps 2.0 / 3.0 | Per-Night dynamic caps |
