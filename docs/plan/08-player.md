# 08 — Player v1 (touch-first)

*Ruling R1 (Cleanse, 2026-09-30): Player is built now, touch first, desktop parity. Supersedes the "Player = black box" line in 00/05 for everything below; gamepad stays deferred.*

*Update (06 P15 / P18, 2026-10-02): **cosmetics and avatar animation are no longer deferred.** Every player is a jointed `Humanoid` in a `CharacterSkin` (§2.6, §2.7) that walks, leans over the cue, and goes limp on a hit; the "no animation rig in v1" and "Cosmetics" lines below are superseded. The Skins screen itself is a later slice; until it lands a player wears the skin of their seat.*

## 1. Purpose
Turns a person into two things the systems already consume: a `ShotIntent` for 01 when it is their Shot, and a position + `Interactable` use for 03/02 while someone else shoots.
Phones first: every control is reachable with two thumbs, every hot path fits 07's `_process` budget.

## 2. Concepts & data model

### 2.1 Body and camera
`Player` (`CharacterBody3D`, capsule `r 0.3 m`, `h 1.75 m`, eye `1.6 m [tune]`) — first person, yaw on the body, pitch on `Head` only (the split already in `player.gd`). Collision **layer 4 `world`**, mask `2 | 4` (table rails + world): players walk around the table, never through it, and balls (mask `1|2|3`, 07 §1) never test against a player. Table bumping is a `WorldInteraction`, not a collision.

### 2.2 Modes
| mode | when | camera | input |
|---|---|---|---|
| `WALK` | default | first person | move + look + interact |
| `CUE` | you are `current_shooter_id`, balls at rest, you tapped **Shoot** within `cue_reach_m` of the cue ball | pinned behind the cue ball at eye height, looking along the aim line; orbits the ball as the aim turns | aim, power, spin, elevation, call-pocket |
| `CARRY` | you picked up a `CameraRig` (`camera_grab`) | first person, rig held in front | walk + look; **Place** drops it (`camera_place`) |
| `RAGDOLL` | knocked (§2.7) for `2 s`, then `0.4 s` of get-up blend | rides the ragdoll's head bone | none: move, look, interact and cue input are ignored |

`RAGDOLL` is entered from any other mode: `CUE` is left exactly like **Back** (position, yaw and pitch restored), `CARRY` asks the host to put the rig down at your feet (`place_camera(true)`, the usual path and cooldown; if the host refuses, you are still the holder and `CARRY` resumes when you stand). It ends in `WALK`.

`CUE` exits on strike, on **Back** (position, yaw and pitch restored), or when `current_shooter_id` changes. Entry is refused with a toast when it is not your turn, balls are moving, or the camera is farther than `cue_reach_m` (3.5 m at table scale 2) from the cue ball. In `CUE` the body is pinned `BACK_M = 1.2 m [tune]` behind the cue ball on the aim line (yaw = aim, pitch fixed to look at the ball); no collision runs. Only the local slot ever builds a camera, HUD or `TouchControls`; remote slots render an avatar.

### 2.3 Touch layout (`TouchControls`, a `CanvasLayer` child of `UILayer`)
Shown when `DisplayServer.is_touchscreen_available()`; hidden on desktop. All targets `≥ 48 dp`, sized through the project's `canvas_items` stretch (base `1280×720`, aspect `expand`). A **mirror** setting swaps left/right for left-handed players.

| mode | left thumb | right thumb | buttons |
|---|---|---|---|
| `WALK` | floating stick: origin where the finger lands in the left half, radius `80 dp`, dead zone `0.15` | drag-look anywhere in the right half, `0.20 °/px [tune]` | **Interact** (label = the nearest `Interactable`'s prompt, hidden if none in reach) · **Shoot** (only when you are the shooter) · **Jump** |
| `CUE` | spin disc (`120 dp`, bottom corner, drag inside the unit disc, double-tap resets) · elevation slider above it (`0–80°`, holds its value) | drag anywhere else = aim yaw `0.12 °/px`, a second finger down = fine aim `×0.25` · power slider on the right edge: drag down from its top to set power, release to strike, drag back under `3%` to cancel | **Back** (top corner) · pocket markers (top row) (only when `rule_call_pocket > 0`: tap one of the 6 before the power slider unlocks) |
| `CARRY` | stick | look | **Place** · **Drop** |

### 2.4 Desktop parity
Mouse captured in `WALK`/`CARRY`: `WASD` move, mouse look (`0.0025 rad/px`), `F` interact (`interact`), `Tab` shoot / back (`cue_mode`), `Space` jump. In `CUE`: mouse X aims, hold the existing `shoot` action (right mouse button) charges power (the existing rise-then-bleed curve), release strikes, `I/J/K/L` spin, `Q/E` elevation, `C` resets spin, number keys `1–6` call a pocket. Same `ShotIntent` either way — 01 never learns the device (P1).

### 2.5 `ShotIntent` (01 §2) — one field added
`called_pocket: StringName` (`&""` = none). Required by 03's `rule_call_pocket`; the host scores a pot into any other pocket as `0`, not a foul (03 §5).

### 2.6 Remote avatars
A remote slot renders the same `Humanoid` the local player wears (§2.7), in its seat's `CharacterSkin` (`Player.SEAT_SKINS`: `seat_red|seat_blue|seat_yellow|seat_green`, `src/resources/skins/characters/`), a `Label3D` name tag (billboard, `fixed_size`), and the cue stick mesh while that peer is in `CUE` — 2 draw calls for the body, 1 for the tag, the stick extra. In `CUE` the avatar stands `0.2 m` left of the aim line leaning over the stick, both hands on it; in `CARRY` both hands hold the rig in front of it. The stick lies on the aim line with its tip `BACK_M` in front of the body. Poses come from `PlayerSlot` at `10 Hz` (04 `push_player_pose`) and are interpolated `100 ms` behind, like balls. A pose is 16 B: `pos 3×f32 | yaw u16 | u16 = mode << 14 | pitch (14 bit, ±π/2)`; the mode is `0 WALK · 1 CUE · 2 CARRY · 3 RAGDOLL`. The puppet renders the sample bracket at `now − 100 ms` (a newer sample is reached, never jumped to). While `RAGDOLL` the owner sends its **pelvis** XZ as the position and the puppet ignores the stream's position (it is limp on its own local physics); see §2.7 for how it stands again.

**Backgrounding (04 §6):** `PlayerSlot` sends no pose while `NetManager.backgrounded`; on `host_away_changed(true)` `TouchControls` shows *Host away, waiting…*, the Player leaves `CUE` and refuses to enter it until the host is back. The shot-clock text also clears at `round_ended`.

### 2.7 Humanoid, ragdoll and knocks (06 P15)
**Body.** `Humanoid` (`src/gameplay/player/humanoid.gd`, a `Node3D` that rests facing −Z with its feet on the origin) is built in code: 11 bones — pelvis, torso, head, upper/lower arm ×2, thigh/shin ×2 (hands and feet are skinned to the forearm and shin) — and **two skinned meshes with one shared vertex-coloured material**: the body, and the head surface (head, face, hat, plus the torso's shoulder cap and neck). `apply_skin(CharacterSkin)` bakes `body_color` (torso, upper arms), `accent_color` (legs, shoes darker, cap), `skin_color` (head, hands, forearms) and the hat (`none|cap|tophat|beanie|crown`) into the vertices; it rebuilds ~550 triangles and leaves the skeleton alone. The local player calls `set_first_person(true)`: the head surface moves to render layer 20, which the local `headCam` culls, so you see yourself from the neck down while the head and hat still cast shadows; the torso is open at the top, so looking down shows arms, thighs and floor rather than a lid. In `CUE` the local body is hidden from its own camera (shadow only): the leaned trunk would fill the aiming view. The material is darkened (`albedo × 0.5`) because the room's key lights are tuned for dark wood.

**Animation** (all procedural, `_process`, ~19 µs per body): breathing; a gait driven by the node's own measured horizontal speed (`stride 4.5 rad/m`, thigh swing `±0.45 rad`, knee flex up to `0.85 rad`; the pelvis rides the straighter leg so a foot is always on the floor; a teleport above `9 m/s` counts as zero speed); the head follows `Head` pitch for players and `look_at_point` for the bartender; `set_hand(side, point)` reaches a hand to a point with two-bone IK. Stances: `STAND`, `CUE` (torso leaned `0.65 rad`, legs split, hands at the stick: rear grip `(0, 0.957, −0.28)`, bridge `(0, 0.957, −0.78)`) and `CARRY` (hands at `(±0.14, 1.10, −0.40)`), selected by `Player.mode`.

**Ragdoll.** A `PhysicalBoneSimulator3D` holds 11 `PhysicalBone3D`s (box/capsule/sphere per segment, total `≈ 56 kg`) joined by cone joints (torso `25°`, head `45°`, shoulders `100°`, hips `70°`) and hinges (elbows fold forward, knees fold back, `~135°`). Bodies sit on collision layer 5 `ragdoll` with mask `2|4` (07 §1): they touch the table rails and the room, never each other and never balls. **Idle they are not simulating and are on no layer** (`animate_physical_bones = false`), so a standing player costs no physics. `ragdoll(impulse)` starts the simulation from the current pose; `impulse` is a velocity change in m/s of the whole body, split unevenly (head `1.6`, trunk and arms `1.3`, thighs `0.6`, shins `0.3`) so a shove topples instead of sliding, plus the speed the body was walking at and a random spin. A second `ragdoll()` while limp only adds a shove. `get_up()` snapshots the lying pose, stops the simulation, emits `got_up` and blends every bone from the lying pose to the animated one over `0.4 s` (smoothstep). `is_ragdoll()`, `pelvis_position()`, `eye_transform()` (head centre, a little forward) are the read side.

**`Player.knock(impulse, seconds)`** leaves `CUE`/`CARRY` cleanly (§2.2), disables the capsule and input, hands the body to physics and sets mode `RAGDOLL`; the local camera detaches (`top_level`) and rides `eye_transform()` (smoothed `25 /s`). After `seconds` the Player stands: the `CharacterBody3D` moves to the pelvis XZ (Y unchanged), input returns, the camera eases back onto `Head` over `0.4 s`, `got_up` is emitted, and a rig the host never took off us puts us back in `CARRY`. A knock while limp extends the time. Remote puppets ragdoll when the knock RPC arrives **or** the pose stream says mode 3 (whichever is first; the other is then a no-op or just adds the shove), ignore pose interpolation while limp, and stand when their own timer is out **and** the owner's latest pose is no longer mode 3 (or `3 s` after the timer, so a silent owner cannot pin them); they then resync to that pose and drop the stale ones. Each peer simulates its own ragdoll: purely cosmetic, the bodies are not synchronised.

**Triggers.**
| trigger | where | knock |
|---|---|---|
| thrown drink (`throw_drink`) | `WorldInteractions._soak_shooter`, host | the **shooter**, pushed away from the thrower (`3.5 m/s` + `1.5 m/s` hop); nobody soaks themselves |
| bomb ball blast | `RoundDirector._detonate`, host | every player within `2.5 m` (flat) of the blast, `4.5 m/s` + hop |
| stumble (Mystery debuff) | `PlayerSpawner._process`, host, 1 Hz tick | stat `player_stumble_per_min` per peer from `EffectManager` (Poisson, rate `/60` per second; Mystery drinks' `static_stumble` is 2 a minute), random direction `2.5 m/s` |
| hard landing | owner's `_physics_process` | falling faster than `7 m/s` when landing; the owner knocks itself and tells everyone (`PlayerSlot.push_player_knock`) |

The host entry point is `PlayerSpawner.knock(peer_id, impulse, seconds := 2.0)` → `apply_knock` RPC on every peer (04 §5); `knock_away(peer, from, speed)` and `knock_blast(origin)` are its helpers. The bar is `3.6 m` high, so nothing a player can reach on foot comes near `7 m/s` (a `1.8 m` drop is `5.9 m/s`): the hard-landing trigger exists for launches and effects, and the probes launch the body at the floor to exercise it.

**Bartender.** `src/gameplay/bar/Bartender.tscn` (`Bar/Bartender` in `MainLevel`, at the stand point behind the counter, facing −X) is a `Humanoid` in the `bartender` skin on a static capsule (layer 4, so players bump into him). Idle life: breathing, head eased toward the nearest player within `4 m`, and every `6–12 s` the right hand wipes the counter for `3 s`. It is not an `Interactable`; the counter props are (02 / P17).

## 3. Rules & numbers
| knob | value |
|---|---|
| walk speed | `3.5 m/s` (settled), no sprint |
| touch look / aim | `0.20 °/px` walk · `0.12 °/px` aim, `×0.25` with a second finger (settled) |
| power slider | start zone = top `15%`, cancel under `3%` (settled) |
| jump | `4.5 m/s` (existing) |
| knock | `2.0 s` limp (default), `0.4 s` get-up blend, throw shove `3.5 m/s`, blast `2.5 m` / `4.5 m/s`, hard landing `7 m/s` (§2.7) |
| interact reach | `2.0 m` (same number the host validates in `WorldInteractions`) |
| enter `CUE` | shooter + all balls resting + within `cue_reach_m` of the cue ball |
| aim wobble | aim yaw sways `± max(0, cue_aim_wobble_deg − CueSpec.wobble_reduction)` degrees (`wobble_reduction` is degrees, 02 D6) at `0.8 Hz [tune]`; the intent carries the swayed yaw at release (03 §2.2 flag resolved). Stats are re-read at `4 Hz`, not per frame |
| shot clock | the host arms it each Turn (`RoundDirector.shot_clock_started(seconds)`); every peer counts down locally and the shooter sees it in `WALK` and `CUE`; at 0 the **host** records a whiff foul (no strike, shot costs 1, 02's foul viewer drop) |
| power curve (desktop hold) | existing `charge_time 0.8 s`, `decay_time 1.6 s` |
| touch power | linear in slider travel, `0..1` |

## 4. Godot implementation sketch
- `src/gameplay/player/Player.tscn` + `player.gd` — body, `Head/Camera3D`, mode state machine, interaction probe (`ShapeCast3D` sphere `2.0 m`, mask = `Interactable.LAYER`, read once per `_physics_process`). The sphere is only the broad phase: the prompt goes to the nearest `Interactable` whose feet-to-origin distance is `≤ 2.0 m`, the host's own test. The counter's three props (`bar_buy`, `bar_serve`, `throw_drink`) share one prompt, *Bartender*; **Interact** opens `BartenderMenu` (06 P17, 02 §3.6), a `ui_modal` with two tabs. **Drinks**: the host's random shelf of 5 tier-framed cards (name, description, buff lines green and debuff lines red, price, units left; Mystery cards red with glitching text; sold-out cards stay, greyed), a Serve / Throw mode switch and a crew-target row for Serve; every Buy / Throw button is ≥ 48 px and greys out from mirrored Cash, stock, Round phase and night limits. **Upgrades**: the fixed ball / cue / camera / table rows (Intermission only). A Drink pick sends `WorldInteractions.request(kind, 0, {drink_id, target_peer})` and the host validates (a Serve keeps the menu open so the stock can be watched, a Throw closes it); an Upgrade asks `EconomyManager.request_purchase`. Walking out of reach closes the menu; the `UIRouter` (06 P12) owns the mouse and blocks look / move / interact while it is open, so the menu itself never touches `Input.mouse_mode`. A rig someone carries is not offered. No two other `Interactable`s sit within 1 m of each other (probe-checked).
- `src/gameplay/cue/cue_controller.gd` — owns `CUE`: aim line, cue mesh, pullback, reads input from `TouchControls` or mouse/keys, builds the `ShotIntent`, calls `table.sim.request_shot(intent)`. The `gate` export is gone (host validates via `PhysicsSim.shot_validator`).
- `src/ui/TouchControls.tscn` + `virtual_stick.gd`, `look_pad.gd`, `power_slider.gd`, `spin_pad.gd` — each a `Control` handling `InputEventScreenTouch/Drag` by finger index in `_gui_input`; they expose values, they never call gameplay.
- Input actions added to `project.godot`: `interact`, `cue_mode`, `call_pocket_1..6` (existing `move_*`, `jump`, `shoot`, `spin_*`, `elevate_*`, `spin_reset` stay).
- `src/gameplay/player/humanoid.gd` (+ `src/resources/skins/characters/*.tres`, `character_skin.gd`) — the body, §2.7; `Player` owns one (`player.humanoid`), `PlayerSlot` skins it by seat; `PlayerSpawner` carries the host's knock entry points and the stumble tick; `src/gameplay/bar/Bartender.tscn` is the NPC.
- Performance (07): no `get_node` in `_physics_process`, UI redraws only on value change, avatars are 2 draw calls each (+ the tag), `Label3D` not a `SubViewport`, nothing simulates while a body is standing.

## 5. Interfaces to other modules
- **NET (04)**: `PlayerSlot.peer_id`, `is_local()`, pose blob in/out (`Player.pack_pose() -> PackedByteArray`, `apply_pose(blob)`); `PlayerSpawner.get_player_position(peer_id)`; `PlayerSpawner.knock(peer_id, impulse, seconds)` (`apply_knock` RPC) and `PlayerSlot.push_player_knock` (owner → all), 04 §5.
- **01/SYNC**: `RoundDirector.current_shooter_id` + `shooter_changed(peer_id)`; `PhysicsSim.request_shot(intent)`; `shot_rejected(reason)` shows a toast.
- **03/FX**: the stat `player_stumble_per_min` (`EffectManager.get_stat`, read by `PlayerSpawner`, 1 Hz); `WorldInteractions` knocks the shooter on `throw_drink`; `Interactable.try_use(payload)`, `Interactable.prompt: String`; `EffectManager.get_stat(stat, peer_id, base)` for `cue_aim_wobble_deg`, `shot_clock_sec`, `rule_call_pocket`, `cue_power_mult` (display only — the host applies it).
- **02/ECON**: the counter's props open `BartenderMenu` locally (the host prices and stocks every purchase; the shelf is mirrored by `update_stock`, 04 §5). Camera grab and place are one toggle, the `move_camera` interaction (04 §5's `camera_grab`/`camera_place` rows are that): each `CameraRig` carries an `Interactable` (`Cameras._grab_prop`, `target_id` = rig number, prompt *Grab camera*); `CARRY` is derived from the holders `Cameras` mirrors in `push_rig_poses(poses, holders)` (`holders_changed`): held by me → `CARRY`, not mine any more → `WALK` with a *camera taken* toast, so a grab the host ignored can never desync. **Place**/**Drop** send it again with `place_at` (ahead of you / at your feet), subject to the 5 s cooldown.

## 6. Open questions
- Gamepad layout (PC/Steam Deck) — later.
- Camera comfort: should `CUE` fade in over `0.2 s` instead of snapping? Playtest.
- ~~Cosmetics~~ — resolved by 06 P18: `CharacterSkin` resources, free and unlocked in test mode. Still open: the Skins screen, the profile field and roster sync that make the pick visible to other peers (a later slice), whether a skin may change the silhouette.
- Ragdoll feel (`2 s`, shove strengths, joint limits) is `[tune]` — nothing is measured on a phone; two limp players at once is the budget, not the proof (07).

## 7. MVP cut vs later
**v1:** everything above, including the humanoid, skins by seat and the triggered ragdoll. **Later:** gamepad, emotes, the Skins screen, per-peer shooter mute (03 §3.4), aim assist line length as an upgrade.
