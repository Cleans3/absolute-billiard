# 08 — Player v1 (touch-first)

*Ruling R1 (Cleanse, 2026-09-30): Player is built now, touch first, desktop parity. Supersedes the "Player = black box" line in 00/05 for everything below; cosmetics and gamepad stay deferred.*

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
One capsule mesh + head sphere tinted by seat colour (`Player.SEAT_COLOURS`, one shared material), a `Label3D` name tag (billboard, `fixed_size`), and the cue stick mesh while that peer is in `CUE` — 3 draw calls plus the tag. The stick lies on the aim line with its tip `BACK_M` in front of the body. Poses come from `PlayerSlot` at `10 Hz` (04 `push_player_pose`) and are interpolated `100 ms` behind, like balls. A pose is 16 B: `pos 3×f32 | yaw u16 | u16 = mode << 14 | pitch (14 bit, ±π/2)`; the mode bits let remote shooters show their cue. The puppet renders the sample bracket at `now − 100 ms` (a newer sample is reached, never jumped to). No animation rig in v1.

**Backgrounding (04 §6):** `PlayerSlot` sends no pose while `NetManager.backgrounded`; on `host_away_changed(true)` `TouchControls` shows *Host away, waiting…*, the Player leaves `CUE` and refuses to enter it until the host is back. The shot-clock text also clears at `round_ended`.

## 3. Rules & numbers
| knob | value |
|---|---|
| walk speed | `3.5 m/s` (settled), no sprint |
| touch look / aim | `0.20 °/px` walk · `0.12 °/px` aim, `×0.25` with a second finger (settled) |
| power slider | start zone = top `15%`, cancel under `3%` (settled) |
| jump | `4.5 m/s` (existing) |
| interact reach | `2.0 m` (same number the host validates in `WorldInteractions`) |
| enter `CUE` | shooter + all balls resting + within `cue_reach_m` of the cue ball |
| aim wobble | aim yaw sways `± max(0, cue_aim_wobble_deg − CueSpec.wobble_reduction)` degrees (`wobble_reduction` is degrees, 02 D6) at `0.8 Hz [tune]`; the intent carries the swayed yaw at release (03 §2.2 flag resolved). Stats are re-read at `4 Hz`, not per frame |
| shot clock | the host arms it each Turn (`RoundDirector.shot_clock_started(seconds)`); every peer counts down locally and the shooter sees it in `WALK` and `CUE`; at 0 the **host** records a whiff foul (no strike, shot costs 1, 02's foul viewer drop) |
| power curve (desktop hold) | existing `charge_time 0.8 s`, `decay_time 1.6 s` |
| touch power | linear in slider travel, `0..1` |

## 4. Godot implementation sketch
- `src/gameplay/player/Player.tscn` + `player.gd` — body, `Head/Camera3D`, mode state machine, interaction probe (`ShapeCast3D` sphere `2.0 m`, mask = `Interactable.LAYER`, read once per `_physics_process`). The sphere is only the broad phase: the prompt goes to the nearest `Interactable` whose feet-to-origin distance is `≤ 2.0 m`, the host's own test. The counter's three props (`bar_buy`, `bar_serve`, `throw_drink`) share one prompt, *Bar counter*; **Interact** opens `DrinkPicker` (Serve / Throw / Shop, a crew-target row for Serve, ≥ 72 px drink rows greyed from mirrored Cash, Round phase and night limits). A pick sends `WorldInteractions.request(kind, 0, {drink_id, target_peer})` and the host validates; walking away closes it. A rig someone carries is not offered. No two other `Interactable`s sit within 1 m of each other (probe-checked).
- `src/gameplay/cue/cue_controller.gd` — owns `CUE`: aim line, cue mesh, pullback, reads input from `TouchControls` or mouse/keys, builds the `ShotIntent`, calls `table.sim.request_shot(intent)`. The `gate` export is gone (host validates via `PhysicsSim.shot_validator`).
- `src/ui/TouchControls.tscn` + `virtual_stick.gd`, `look_pad.gd`, `power_slider.gd`, `spin_pad.gd` — each a `Control` handling `InputEventScreenTouch/Drag` by finger index in `_gui_input`; they expose values, they never call gameplay.
- Input actions added to `project.godot`: `interact`, `cue_mode`, `call_pocket_1..6` (existing `move_*`, `jump`, `shoot`, `spin_*`, `elevate_*`, `spin_reset` stay).
- Performance (07): no `get_node` in `_physics_process`, UI redraws only on value change, avatars are 3 draw calls each, `Label3D` not a `SubViewport`.

## 5. Interfaces to other modules
- **NET (04)**: `PlayerSlot.peer_id`, `is_local()`, pose blob in/out (`Player.pack_pose() -> PackedByteArray`, `apply_pose(blob)`); `PlayerSpawner.get_player_position(peer_id)`.
- **01/SYNC**: `RoundDirector.current_shooter_id` + `shooter_changed(peer_id)`; `PhysicsSim.request_shot(intent)`; `shot_rejected(reason)` shows a toast.
- **03/FX**: `Interactable.try_use(payload)`, `Interactable.prompt: String`; `EffectManager.get_stat(stat, peer_id, base)` for `cue_aim_wobble_deg`, `shot_clock_sec`, `rule_call_pocket`, `cue_power_mult` (display only — the host applies it).
- **02/ECON**: `bar_buy` opens `ShopMenu` locally (the host prices every purchase). Camera grab and place are one toggle, the `move_camera` interaction (04 §5's `camera_grab`/`camera_place` rows are that): each `CameraRig` carries an `Interactable` (`Cameras._grab_prop`, `target_id` = rig number, prompt *Grab camera*); `CARRY` is derived from the holders `Cameras` mirrors in `push_rig_poses(poses, holders)` (`holders_changed`): held by me → `CARRY`, not mine any more → `WALK` with a *camera taken* toast, so a grab the host ignored can never desync. **Place**/**Drop** send it again with `place_at` (ahead of you / at your feet), subject to the 5 s cooldown.

## 6. Open questions
- Gamepad layout (PC/Steam Deck) — later.
- Camera comfort: should `CUE` fade in over `0.2 s` instead of snapping? Playtest.
- Cosmetics (seat colours are the whole v1 identity).

## 7. MVP cut vs later
**v1:** everything above. **Later:** gamepad, avatar animation rig, emotes, per-peer shooter mute (03 §3.4), aim assist line length as an upgrade.
