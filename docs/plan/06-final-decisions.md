# 06 — Final decisions (alpha adjudication, 2026-08-29)

Inputs: docs 01–04 (copilot / gemini / sonnet / omp), alpha review (05 §Alpha review), four opus red-team reports (one per doc, each also attacking alpha's R1–R3).
Format per decision: **verdict** — who won — why — what changes in which doc. Everything marked `→ edit` is a concrete rewrite task for the next pass. Player design still deferred.

## Scorecard of the big three

| | Alpha proposed | Red-team said | Final |
|---|---|---|---|
| R1 physics | custom 2D analytic sim, lockstep netcode | Jolt already does contact friction; 2D can't do jump/tilt/bomb; libm breaks cross-platform determinism; effort 3× under-estimated | **Alpha loses.** Keep `RigidBody3D` on Jolt, with 5 mandatory settings (D1). Lockstep dead (D2). |
| R2 turns | one cue ball per player, simultaneous | kills shot boundary, trick attribution, camera focus; realistic idle is 4× worse than alpha said | **Alpha loses on fix, wins on problem.** Roles model (D3). |
| R3 economy | "doesn't close", fix rate to 1.0 | Night 1 closes (ratio 1.67) once viewer growth is modelled; curve breaks Night 3+ because quota is superlinear and income affine; rate change can't fix shape | **Alpha half-right.** Fix the quota curve, not the rate (D4). |

---

## D1 — Physics: `RigidBody3D` on Jolt, hardened
**Verdict:** keep 01's engine choice. Red-team 01 + 04 win.
- Jolt (Godot default since 4.6) applies Coulomb friction at contacts → throw/english emerge. What's missing is rolling resistance only: ~20 lines in `_integrate_forces` applying velocity-opposing torque.
- Custom 2D sim cannot do jump shots, `table_tilt`, bomb scatter — features 01 and 03 already spec.
- Cross-platform determinism is unreachable in GDScript/C# (libm trig, float32 `Vector3` vs double scalars). Replays only need *same-machine* determinism → record `Shot` intents + seed, replay on host (D2).

`→ edit 01`: add a **Physics settings** section, non-negotiable:
| setting | value |
|---|---|
| `physics/3d/physics_engine` | Jolt (explicit) |
| `physics/common/physics_ticks_per_second` | `240 [tune]` |
| `Ball.continuous_cd` | `true` |
| `Ball.contact_monitor` / `max_contacts_reported` | `true` / `8` |
| `Ball.mass` | `0.17 kg` (was never specified) |
| cue impulse range | re-derive: `0..~1.7 N·s` gives 0–10 m/s on 0.17 kg (current `18 N·s` = 105 m/s, dimensionally broken) |
| rolling resistance | custom torque in `_integrate_forces`, `[tune]` |
| pockets | two jaw cylinders + drop plane per pocket (rattle/reject-at-speed emerge); delete `pocket_capture_speed_mps` |
| rail shapes | per-shape metadata (`rail_id`) so contact log distinguishes rails from balls |

`→ edit 01 §7 MVP`: add **physics test fixtures** (straight-in pot 100/100, stun stops dead, 30° cut lands within X mm, break has zero tunneling at max power). Cheapest insurance in the plan.

## D2 — Netcode: host-authoritative, event-based sync
**Verdict:** 04's host-auth stands; its snapshot *transport* loses; alpha's lockstep loses. Red-team 04 wins.
- 20 Hz snapshots reconstruct every cushion/ball contact as a straight line — wrong exactly at the interesting frames. Balls move piecewise-linearly, so **send contact events** `(ball_id, tick, pos, new_velocity)` and dead-reckon between them. Exact reconstruction, fewer bytes, no determinism needed. Keep a low-rate (`2 Hz`) full-state heartbeat for drift correction.
- Interpolate only; never extrapolate near cushions.
- Gate client presentation (`+500!` popup) on the client's playback clock, not on `shot_resolved` arrival.

`→ edit 04`:
- §2 sync model: replace Option A/B with event sync + heartbeat.
- All streamed state RPCs: `@rpc("authority", "call_remote", "unreliable_ordered", 1)`; `shot_resolved`, `update_cash`, `apply_event` stay reliable (4.7 default). Current doc streams snapshots reliably — bug.
- `update_cash` sends absolute balance (diagram says delta — contradiction).
- Sequence diagram: add reject path (`shot_rejected(reason)`), drink/event path, and show idle clients.
- `NetManager` owns a `MultiplayerPeer`; transport is an enum `{steam, enet}`. **ENet + lobby code is a permanent second path** (itch/demo builds, single-machine dev — Steam allows one client per PC).
- **Broadcast `SaveProfile` (<1 KB) to every peer at each Round end.** Any friend re-hosts from the last checkpoint. Not host migration; closes the "host crash = campaign lost" hole.
- Add `save_version`. Boot scene → `Lobby.tscn` (currently `MainLevel.tscn`). Singleplayer = host with 0 peers.
- Milestones: insert **M0 = 1-day GodotSteam spike** (4.7 extension builds, app id 480, 2-account invite test) — the only externally-failable milestone should not be last. Rest of order stands.
- Renderer: Forward+ **because dim bar needs fog/SSR/emissive**, not "physics-heavy" (non sequitur). Add Mobile export override for Steam Deck; fix `config/features` too.
- Say explicitly: hand-packed ball events (not `MultiplayerSynchronizer`); `MultiplayerSpawner` for `PlayerSlot`s.
- Close open question "Cash per-client?" — 00 already says crew-shared.

## D3 — Turn structure: one shooter, three live roles
**Verdict:** round-robin loses (2.4 shots/player/round, ~25 s of agency per 6-minute Night). Alpha's simultaneous-cue-balls loses (no shot boundary, no trick attribution, no camera focus, forces input ordering). **Red-team 02's roles model wins.**

One `Shot` at a time (all of 01/04's boundaries survive). While one player shoots, the other three hold jobs, rotated every Round:
| role | does | touches |
|---|---|---|
| **Shooter** | the shot | 01 |
| **Director** | cuts the live `Camera`, picks the angle → sets `Camera_Multiplier` for this shot; bad cut = missed trick footage | 02 camera system becomes a *decision*, not a passive multiplier |
| **Bartender** | buys/serves the Drink that lands mid-shot (on shooter or on table), picks next Round's hazard (D6) | 03 |
| **Hype** | spends hype meter on chat events/tips, taunts; the "viewers" fiction | 02 stream |

Singleplayer: shooter + auto-director (nearest-pocket camera), no bartender/hype roles. 2–3 players: merge roles (Director+Hype, Bartender).

`→ edit 02 §3.1`: replace turn order with the roles table; delete "winner stays" variant; retire open question 2.
`→ edit 01`: `Shot` carries `shooter_id`; combo window etc. unchanged.
`→ edit 03`: Effects carry `owner_peer_id` (whose wobble?). Bartender-served drinks target a named player.

## D4 — Economy: fix the curve, not the rate
**Verdict:** red-team 02's arithmetic supersedes alpha's. Night 1 closes (~$1,000 vs $600). Nights 3–5 fail (0.91 / 0.78 / 0.66 ratio — Night 5 below the 0.7 game-over floor with zero drinks). Root cause: `Viewer_Scalar` is affine in viewers (12× viewers → 1.8× scalar); income grows ~5.6× over the campaign, quota 14×.

`→ edit 02`:
- **One** `Viewer_Scalar` definition (`/500` version); delete the `/1000` StreamState field.
- **Viewers reset per Night** to the table's base value (currently unspecified; 3× swing).
- Quota curve `×1.5/night`, sized to ~60% of modelled income: `600 / 900 / 1,350 / 2,000 / 3,000 [tune]`. Buyout expressed as `1.5 × Night 5 quota`, not a literal.
- Endless scaling must be ≥ campaign rate (currently 1.4× < 1.5×–2.3×: endless easier than tutorial).
- Debt extension: interest `≤ 10%` or delete the 70% band and fail at `Cash < Quota`. As written the band is a delayed loss (miss by 30% on Night 1 → need 143% on Night 2).
- **Intermission untimed** (host advances). Negotiating a shared purse is the social peak; 15 s means the host buys alone.
- Rounds must differ or merge: Round 1 = no hazard, Round 2 = tier-1 hazard, Round 3 = tier-2 hazard (uses D6). Identical rounds are a UI boundary pretending to be pacing.
- **State balls per Round (`10 object balls [tune]`) and expected shots per Round (`~9–10` at a 12 s cycle)** — both were assumed by everyone, written by nobody. Rounds end on timer, not clear; "table cleared" = all `base_value > 0` balls potted.
- Decay `-5/s after 10 s idle` is dead code under roles too — replace with hype decay only.
- Multiplier stack applying to `black_penalty` (−250 × ~4 on Night 5) — **make it deliberate**: penalty balls scale with the same stack. It's the best risk mechanic in the doc.
- Campaign length: keep 5 Nights but add persistent unlocks across runs (BallTypes, drinks, cameras) so a wipe at 45 min isn't zero-progress.
- Cameras: with the Director role they are a decision. Tier upgrades stay; placement stays cosmetic until Director exists.

## D5 — Scoring & balls: fewer, readable, value-scaled
**Verdict:** red-team 01 wins across the board.
`→ edit 01`:
- **Delete flat trick bonuses; keep multipliers** (alpha had it backwards: +50 flat is +50% on a red, +10% on gold → tricks only worth doing on cheap balls).
- Trick **disjointness**: one shot pays the single highest trick multiplier, not a sum.
- Ship **5 tricks**: Bank, Kick, Carom, Combo, RailRunner (all counters over the ordered contact log). Cut MasséCurve (noise), DoubleCushionExit (fires on every rail), ScratchEscape (undefined), SplitChain/BombCascade (depend on unbuilt balls).
- Value tiers **100 / 250 / 500** (20% spreads are invisible mid-aim).
- Taxonomy: **3 value tiers + `black_penalty` + one gimmick ball unlocked per Night** (bomb N2, split N3, joker N4, …). Cut `ghost_ball` and `magnet_ball` (anti-skill: outcome not deducible at aim). `stone_ball` → 0-pt obstacle, not a dominated target.
- **Scratch = shot must contact an object ball, else foul**; foul = lost shot from the Round budget + viewer drop; cue ball respawns in the kitchen (behind head string). Without this the dominant play is spamming the nearest ball.
- Random drop → Poisson-disk sampling (~15 lines, never fails); keep seed, **show the seed**; hand-author Night 1 and Night 5 racks.
- Stuck-state rule: only penalty balls left, or cue ball frozen → Round ends early, no penalty.
- `wild` (joker) = `×2` on the highest-value ball potted this shot.

## D6 — Effects: typed, fewer, chosen not rolled
**Verdict:** red-team 03 wins on schema and catalog; alpha's "gift a drink" loses as specified.
`→ edit 03`:
- `stat_modifiers: Dictionary` → `Array[StatMod]` with `StatMod { stat: StringName (const-listed), op: enum {ADD, MUL}, value: float }`. Two catalog entries already reference keys that don't exist / mean two things — untyped will rot.
- Delete `reward_multiplier_contribution` from `Effect`; it lives on `Drink` / `Event` (different composition math).
- Stacking: `refresh | ignore` + `exclusive_group: StringName` (makes `ice_water` vs alcohol expressible). Drop `stack`/`highest_wins`/`max_stacks`.
- `requires_host_apply` is derived from `target` — delete the field, one line of code.
- Add `owner_peer_id` (D3).
- Composition: **one rule, one on-screen number** — `Reward = Drink_Mult × Event_Mult`, caps `2.0 / 3.0 [tune]`. Delete `Trick_Sync_Bonus` (5% noise on a 4× product) and the global cap.
- **Events are crew-chosen pre-Round** by the Bartender role for a stated multiplier (retires the scheduler roll table and open question 3). Timed hazards are otherwise beaten by "don't shoot".
- Catalog cut to hazards that change the **task**, not a scalar: `moving_pockets`, `ball_swap_chaos`, `glass_cushions`, `tilted_table`, `lights_out` (player view), `bouncer` (single-turn) + 2 new *opportunity* events (`crowd_roar`: next pot ×2; `pocket_jackpot`: one pocket pays ×3). Delete `power_flicker` (a hazard that lowers payout). Merge fog/lights, sticky/sway, stare/bouncer.
- Split `camera_visibility` into `stream_camera_*` (income) and `player_view_*` (difficulty).
- `trigger_rule: String` → `min_night: int`, `scripted_first: bool`. `energy_drink` → `round_time_add_sec`.
- Drinks: downside must change **how you play**, not accuracy (call-your-pocket, no english, heavier cue ball, shot clock, buffs player to your left). Wobble-only tradeoffs are a skill slider. `aim_wobble` also depends on the deferred Player module — flag.
- `mystery_shot`: roll on use, show odds.
- Gift-a-drink: dropped from shared Cash (negative-sum against a shared quota). Bartender role serves drinks *to* the shooter as a team play instead.
- Wobble floors at 0 — say so.

## D7 — Architecture: one autoload, session nodes
`→ edit 04 + 02 + 01 + 03` (naming unification):
- Autoloads: **`NetManager` only** (must outlive scene changes). `SaveManager` = static class, no node. `GameLoop`, `EconomyManager`, `StreamManager`, `EffectManager`, `EventScheduler`, `RoundDirector`, `PhysicsSim` = children of `MainLevel`; "new campaign" = scene reload. Delete `Game`/`Net`/`Save` short names and 01's `Signals.gd` global bus (direct signals on session nodes).
- `PhysicsSim` lives in the `Table` scene (01 §4 and 04 §4 disagreed).

---

## Rejected red-team counters (kept original)
- Data-driven `.tres` resources (03) — inspector tuning + hot reload worth it; the bug was the untyped dict, not the Resource.
- Noray / WebRTC / EOS as primary transport — Noray gets a footnote as itch fallback; others lose.
- Skip host migration — stands (checkpoint broadcast covers the real hole).
- Hand-authored racks only — seeded random stays, with two authored racks.
- Mobile renderer — Forward+ stands, for the lighting reason.
- Shorten campaign to 3 Nights — 5 stands with persistent unlocks.

---

# Cleanse's rulings (2026-08-29) — these override anything above

**P1 — Mobile first.** The game targets phones/tablets first, PC (Steam + itch) second, open-source welcome. Consequences:
- D2 renderer: **Mobile renderer stays** (Forward+ ruling reversed). Bar mood via baked lighting, emissive materials, cheap fog plane — not SSR/volumetrics.
- D2 transport: **ENet + Noray relay (self-hosted, open-source) is the primary transport**; GodotSteam is a PC-only optional peer (Steam invites/overlay). Friend invite on mobile = lobby code / share link. Cross-play mobile↔PC required.
- D1 physics budget: 240 Hz tick must be validated on a mid-range phone; fallback `120 Hz + CCD`. Ball count per Round capped by the phone budget (`≤ 12 [tune]`).
- Touch-first cue control (aim/power/spin gestures) — Player module, still deferred, but 01's cue API must not assume mouse.
- 04 milestones: M0 = mobile perf spike (16 balls, Jolt, 240 Hz, 60 fps on a 2022 mid-range Android), before any netcode.

**P2 — No roles model (D3 reversed).** Friends are **free-roaming** in the bar while one player shoots — physically moving around the table, doing random things. Restricting them to jobs kills the friendslop. Design implication (systems side, Player still black box):
- One `Shot` at a time keeps all boundaries (01/04 unchanged).
- Non-shooters interact with the *world*: bar (buy/serve/throw drinks), cameras (grab and move a `Camera` — Director emerges from play, not a menu), props (stools, jukebox, lights), and the table itself (bump it → `table_tilt`/nudge Effect on the live shot, at a viewer/hype cost or bonus). These are 03 Effects with `owner_peer_id`, triggered by world interaction instead of a shop UI.
- Camera multiplier = whichever camera currently has the best view of the potted pocket (auto-scored: distance + occlusion), so moving cameras matters without a role.
- 02 retires open question 2 this way; idle-decay rule stays deleted.

**P3 — Bartender is the shop.** NPC at the bar sells: Drinks (03), **ball upgrades** (unlock BallTypes, raise tier values, gimmick balls per Night — answers D5's unlock order: player buys the order), **cue/rod upgrades** (power cap, spin offset radius, jump/massé unlock, wobble reduction), camera tiers, table mods. 02 §3.4 sinks move under a single `Shop` catalog owned by 02; items are Resources like Drinks. Shop is open during untimed Intermission and, for Drinks only, mid-Round via the bar.

**P4 — Optimization chapter.** New doc `07-optimization.md`: per-aspect optimization plan (physics, rendering, netcode, memory/GC, load times, battery/thermal, asset pipeline, GDScript hot paths), each with budget numbers for the mobile target, measurement method, and the specific technique. Mobile-first makes this a design constraint, not a later phase.

**P5 — Income sheet**: alpha produces it inside 02's rewrite (no user input needed).

## Next pass
Rewrite 01/02/03/04 against D1–D7 **as amended by P1–P5**, add 07. Then Player design pass (touch cue control, free-roam interactions).

## Rewrite pass outcome (2026-08-29, opus ×5)
- 01 200 lines, 02 225 (+ income sheet 1.70/1.65/1.54/1.50/1.43; `Point_To_Cash_Rate 0.1→0.3`; buyout **replaces** Night 5 quota; hard fail at `Cash < demand`, no interest band), 03 222, 04 258, 07 301.
- 04 deviates from D2 wording on purpose: **contact events reliable (ch1)**, heartbeat unreliable_ordered (ch2) — a lost event corrupts dead reckoning permanently. Accepted.
- 04/07 aligned by alpha: event flush `30 Hz`, `shot_resolved` carries 01's exact `shot_ended` payload + `end_tick`.
- 07 flags: Jolt ignores `physics/3d/solver/*` sleep params (use `physics/jolt_physics_3d/simulation/*`); Mobile renderer has no SSAO; measure `linear_damp`/`angular_damp` REPLACE mode before writing D1's rolling-resistance torque; CCD speed-gated above `3.0 m/s` at 240 Hz.
- Web export: **no** (no UDP, wasm single-thread Jolt, itch COOP/COEP headers).

# Cleanse's rulings (2026-09-30) — M0–M7 campaign

**P6 — Player v1 now.** The Player module is no longer deferred: touch-first first-person player, cue control and bar interaction per `08-player.md`. Cosmetics and gamepad stay later.

**P7 — Noray relay host.** The self-hosted relay runs on a dedicated GenCloud VPS (`160.191.243.191`, Ubuntu 24.04, 1 vCPU / 1 GB; moved 2026-10-12 from the cancelled `160.191.243.188`). `net_config.tres` points there by default; a fork edits one field.

**P8 — Open questions closed with alpha's defaults.** bomb scatters and removes only itself · split = one spawn per pot · no house pocket · stone counts toward the ≤12 cap · fouls cost no Cash · hostile cap 2/Turn, no per-Round cap · `ice_water` refunds nothing · **netcode is silent at rest**: heartbeat 2 Hz only while a Shot is live (07 §3 over 04 §3), one full-state on join/resume.

**P10 — Noray first, own tunnel relay as fallback (2026-09-30, after the first real relay run).** Noray stays for the lobby code and the direct punch. Its built-in relay is not used: it cannot reach a host behind a symmetric NAT (Cleanse's own network, many mobile carriers). The fallback is `deploy/noray/tunnel.py` on the same VPS: one UDP port per joiner, both addresses learned from token packets on that port, so it works behind any NAT (04 §2.3).

**P9 — M0 is measured later, not waited on.** The mobile perf spike ships as a one-command device run (`src/tools/m0_device_run.sh`); M2+ proceed meanwhile. `PhysicsSim.LIVE_TICK` is the single tick constant, so the 240/120 Hz outcome is a one-line change.

# Cleanse's rulings (2026-10-02) — polish pass (override P3, P6 "cosmetics later", P8 "fouls cost no Cash")

**P11 — Settings and controls.** A Settings screen reachable from the main menu and an in-game pause menu (Esc / touch pause button): master volume, graphics quality `Auto | High | Medium | Low` (Auto = `QualityLadder`), FOV, mouse / touch-look / cue-aim sensitivity, invert Y, touch layout mirror, show FPS. A Controls screen rebinds every keyboard/mouse gameplay action, with reset to defaults. Persisted in `user://settings.cfg` by a static `Settings` class. The pause menu never pauses the simulation (multiplayer); it blocks local input only.

**P12 — Drawn UI, isolated screens.** One project-wide `Theme` built from hand-drawn SVG sprites (panels, buttons, icons). One `UIRouter` under `UILayer` owns modal screens: at most one modal is open, a phase change closes every modal that does not belong to the new phase, Esc closes the top modal or opens Pause. HUD regions are fixed and never overlap; one toast channel. GAME_OVER gets a way back to the menu.

**P13 — No fog planes.** The three additive haze quads over the table are removed (they sat at eye height). The Environment's depth fog stays.

**P14 — Camera rigs look like cameras.** Real tripod + body + lens model with authored materials; they rendered with the engine default material.

**P15 — Triggered ragdoll player.** Every player is a jointed humanoid. It walks normally and goes limp on a hit — thrown drink, bomb-ball blast nearby, a mystery-drink stumble, a fall — then gets up after ~2 s; the first-person camera rides the ragdoll head. The host broadcasts the knock; each peer simulates the ragdoll locally (cosmetic); pose mode `3 = RAGDOLL`. The bartender NPC uses the same humanoid body.

**P16 — Scratch costs Cash.** Cue ball pocketed or off the table = fine of 10% of the Night's Quota, rounded to the nearest $5, minimum $25; Cash may go negative. A whiff or shot-clock foul still costs no Cash.

**P17 — Bartender NPC replaces the Shop menu (refines P3).** The counter moves off the back wall; an NPC bartender stands behind it. No Shop button. One bartender menu: **Drinks** = a random stock of 5 offers, rerolled by the host at every Intermission, each offer's tier drawn by relative weight Common 50 · Uncommon 26 · Rare 13 · Epic 6 · Legendary 2 · Mystery 3, then a drink of that tier; stock per offer Common 3 · Uncommon 2 · others 1, shared by the crew. **Mystery** drinks are red with glitching text and show one buff and one debuff, so the buyer weighs it. **Upgrades** = the fixed ball/cue/camera/table rows.

**P18 — Skins (test mode).** A Skins screen in the main menu with character skins and bar skins, all free and unlocked for now (economy later). Each Round the host picks one bar skin at random from the crew's equipped bar skins.

# Cleanse's rulings (2026-10-09) — testing on the phone

**P19 — The phone is the testing ground.** Cleanse plays every change on an Android phone, not on the desktop. When a change is finished and ready to test (merged to `main`, probes green), run `src/tools/publish_apk.sh` in the same session: it builds the debug APK and replaces the download on the relay box's share page. Then hand Cleanse the link `http://160.191.243.191:8892/`. A change that isn't on that page hasn't reached testing yet. Desktop runs and probes are for development only. iOS stays out of scope until there is a Mac.

# Cleanse's rulings (2026-10-10) — polish pass 2, from the first phone test (override P3's Intermission screen, P12's top stat bar, 08 §2.4 "arms hidden in first person")

**P20 — GO LIVE starts the Round from the room.** Intermission has no modal: players stay free in the bar. A GO LIVE pedestal next to the table starts the next Round. Solo: one press. Online: every connected player presses it (a ready toggle). Players whose app is backgrounded don't count toward that, and a disconnect drops out of the count. The pedestal shows who is ready and who isn't. Reckoning, Campaign won and Game over keep their screens.

**P21 — Lean HUD plus a wall blackboard.** On screen: Cash against Quota with a fill bar, and the Round clock with shots left, as two separate groups. Everything else goes on a chalk blackboard on the bar wall: Night, Round i/n, viewers and hype, the active hazard and drink effects, the last Round's result, and the next Night's ask.

**P22 — Waits explain themselves.** Every wait message says what it is waiting for and shows a countdown, the elapsed time, or a count. Pressing Start shows a loading screen, and it stays up until the local player has spawned (online it shows "Waiting for players N/M"). A hosted lobby can be cancelled while it connects and left once it is open. A client whose host leaves goes back to the menu with a notice.

**P23 — Icons for everything you buy or face.** Every Drink shows a glass that suits it (shot, pint, cocktail, wine, mug, highball, tiki, flask…), with colour and decor that change per drink. Upgrades and hazards get icons too. Skin options show names only: no colour swatches, to keep the mystery. Bar skins get a pre-rendered turntable preview.

**P24 — Quirky bartender.** The bartender keeps the procedural body but exaggerated: mustache, tall hat, bowtie, odd proportions, big gestures. He talks on his own in speech bubbles with gibberish voice blips. His lines are pep talks, a special of the day (a drink that is really on the shelf), sales pitches, and reactions to play. The negative reactions cut deep, but never directly.

**P25 — Lean on rail stays and becomes visible.** The effect is unchanged (one cushion ×0.85 for the next shot, 03 §3). The presser leans for 2 s, the rail is marked until the shot resolves, and everyone gets a toast naming who leaned on which rail.

**P26 — Body and mirror.** In first person the player sees their own torso and arms. Only the head and hat are hidden: the Humanoid upper mesh is split into head and arms, at +1 draw call per avatar. A large real-time mirror on the west wall shows everyone, your own head included. It is a reflected camera with a cull mask, a capped resolution and a capped rate, and it renders only when it is in view. The 120 draw-call gate still holds with the mirror in view. *Amended 2026-10-12 (adhoc-1012a; Cleanse: the mirror jitters and costs too much):* the room in the glass is a cube captured once (re-captured on a table rebuild or bar skin change) and box-projected per pixel from the live eye; only the avatars and the table are a per-frame reflected-camera pass, from the interpolated eye, no rate cap. *Amended 2026-10-13 (adhoc-1013c, P33 U1/U2; Cleanse: "when shooting I can't see myself in the mirror", "too close it's blurry, too far it freezes me, the bartender and the table in the air"):* the local body stays in the mirror while shooting (it leaves the player's camera by `HEAD_LAYER`, not by shadow-only; 08 §2.7 "CUE body"), the 8 m range is gone (in front of the glass the pass always runs), its size follows the glass on screen (sharp at the glass, cheaper far), the room cube is 1024 / 768 / 512 px by tier with mipmaps, and `Mirror.set_blood(amount)` exists for the failure cutscene.

**P27 — Stay where you shot.** After firing, the player keeps the spot they shot from, snapped to free floor. Backing out of aiming still returns them to where they stood before.

**P28 — A richer bar from CC0 packs.** Stylized low-poly CC0 props (Kenney / Quaternius style) and generated poster art. Licenses are kept beside the assets under `assets/third_party/`. The decor is baked into the lightmap and atlased. The spin and elevation controls open enlarged pickers on tap. The table's inner-edge glare is removed.

# Cleanse's rulings (2026-10-11) — the story build and the second table pass (override 01's "pot = sensor at the nose line", the authored racks' black-ball spots, 09 §6's open questions)

**P29 — The story is presentation only; Moe is real.** Build 09 as written with its §6 decisions: Moe is a real loan shark who watches every Night from the stream chat as "velvet" (that is the twist, not "Gus was Moe"); no rule branch (the Night 4 favor drink stays Later); Moe speaks in P24's blips, lower and slower, with no recorded audio; intro cards are local per player, and GO LIVE's every-player press is what keeps a slow reader from missing the Round. Cleanse delegated these four calls.

**P30 — Real pockets, generously big.** A pocket is a hole: the bed and the cloth are cut open at every pocket, a ball that rolls over the hole falls into it under gravity, drops into a pocket cup below the cloth, and only then counts as potted. No ball is potted or hidden while it is still on or above the cloth. Pocket mouths are widened well past regulation (corner ≥ 2.5 ball diameters, side ≥ 2.7) so a slightly off-line shot still drops. Pocket hazards and upgrades (radius ×, Moving Pockets) move and resize the real hole, not only a sensor.

**P31 — The black ball starts in the middle.** In every opening formation, authored or seeded, the black ball takes the spot nearest the formation's centre: the middle of the triangle's third row in a triangle rack, the most central slot in a scatter. If a rack has more than one black ball, the others keep their spots.

**P32 — No glare in the table's seams.** Where the cushions meet the rails and the cloth, nothing shines: no bright line, sparkle or light leak at any camera angle a player can reach. P28's matte materials stay; the seams themselves are closed.

# Cleanse's rulings (2026-10-13) — "a few problems I found" (override 08 §2.7 "CUE body shadow only", 07/08 "mirror only within 8 m", 02's two base camera rigs and five-Night campaign, 09 §2.1 "lost a bet", P29 "no cutscene system")

**P33 — You see yourself shoot.** In CUE the player still drives the cue and the camera, but their own body is a real body: the hands stay on the cue, the rest of the body leans and stands where a player would, and it all shows in the mirror. The mirror stays sharp up close and stays live from anywhere in the room.

**P34 — Two stream cameras: one tripod, one in the ceiling.** One tripod is removed; a fixed camera in the ceiling looks straight down at the table. The TV is wider and shows both feeds live, without noise. The ceiling feed is an overview, not a scoring rig.

**P35 — Controls show only what you can do.** Shoot appears only to the player whose turn it is, only when a shot is possible; sabotage (hostile interaction) prompts appear only when they would be accepted. A prompt appears only for what the player is facing. Stools and sofas can be sat on. Jump is an up-arrow icon. The Bartender's menu shows a target only when there is a choice.

**P36 — A break is chaos, and the shot is readable.** A full-power break sends most of the rack moving. The shooter sees a guide of where the cue ball will go (cushions, the first ball, curve for massé, arc for jump), and the cue's tip sits where the spin setting says.

**P37 — An easier start.** The first quota, the scratch penalty and the Round timer are set so a new crew can make Night 1: lower quota and fines early, much longer Rounds. Numbers are calibrated with the playtest bot.

**P38 — The table is staged.** At the end of a Round the table bed opens and the balls fall into a pit (no player can fall in). At the start of a Round a ceiling vent opens above the table's end nearest the blackboard, a UFO flies out, materialises the rack ball by ball for every formation and ball type, then dematerialises; nothing in either sequence collides. Shots and the Round clock wait for it.

**P39 — Campaign and Endless; the abduction.** The Lobby offers Campaign (3 Nights, then the win) and Endless (Nights forever). The story is reframed: the crew is abducted, driven hooded and gagged to a cabin in the woods that hides the bar, thrown in and locked up; Moe, Gus, the Rope and velvet stay. Cutscenes exist now (overrides P29's "presentation through what the game already has"): the intro (van → cabin → thrown in), the quota failure (red alert, black screens, a bloody mirror, the floor opens onto a fleshy mouth, then the main menu) and the campaign win (green light, Gus celebrates, green gas, then the crew riding a truck while the run's stats and a D–S+ grade show). Alpha decided the details Cleanse left open; they are in 09 and the card contract.
