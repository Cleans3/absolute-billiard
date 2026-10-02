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
| `WALK` | floating stick: origin where the finger lands in the left half, radius `80 dp`, dead zone `0.15` | drag-look anywhere in the right half (the LookPad covers exactly that half, under the buttons), `0.20 °/px [tune]` | **Interact** (label = the nearest `Interactable`'s prompt, hidden if none in reach) · **Shoot** (only when you are the shooter) · **Jump** |
| `CUE` | spin disc (`120 dp`, bottom corner, drag inside the unit disc, double-tap resets) · elevation slider above it (`0–80°`, holds its value) | drag anywhere else = aim yaw `0.12 °/px`, a second finger down = fine aim `×0.25` · power slider on the right edge: drag down from its top to set power, release to strike, drag back under `3%` to cancel | **Back** (top corner) · pocket markers (top row) (only when `rule_call_pocket > 0`: tap one of the 6 before the power slider unlocks) |
| `CARRY` | stick | look | **Place** · **Drop** (Interact hides: Place is the same action) |

Every mode also shows a **Pause** button (`64 dp`, top corner opposite Back, i.e. top-right unless mirrored). In `CUE` the LookPad covers the whole screen under the widgets. Sensitivity, FOV, invert-Y and the mirror come from `Settings` (§2.7).

### 2.4 Desktop parity
Mouse captured in `WALK`/`CARRY`: `WASD` move, mouse look (`0.0025 rad/px`), `F` interact (`interact`), `Tab` shoot / back (`cue_mode`), `Space` jump. In `CUE`: mouse X aims, hold the existing `shoot` action (right mouse button) charges power (the existing rise-then-bleed curve), release strikes, `I/J/K/L` spin, `Q/E` elevation, `C` resets spin, number keys `1–6` call a pocket. Same `ShotIntent` either way — 01 never learns the device (P1).

### 2.5 `ShotIntent` (01 §2) — one field added
`called_pocket: StringName` (`&""` = none). Required by 03's `rule_call_pocket`; the host scores a pot into any other pocket as `0`, not a foul (03 §5).

### 2.6 Remote avatars
One capsule mesh + head sphere tinted by seat colour (`Player.SEAT_COLOURS`, one shared material), a `Label3D` name tag (billboard, `fixed_size`), and the cue stick mesh while that peer is in `CUE` — 3 draw calls plus the tag. The stick lies on the aim line with its tip `BACK_M` in front of the body. Poses come from `PlayerSlot` at `10 Hz` (04 `push_player_pose`) and are interpolated `100 ms` behind, like balls. A pose is 16 B: `pos 3×f32 | yaw u16 | u16 = mode << 14 | pitch (14 bit, ±π/2)`; the mode bits let remote shooters show their cue. The puppet renders the sample bracket at `now − 100 ms` (a newer sample is reached, never jumped to). No animation rig in v1.

**Backgrounding (04 §6):** `PlayerSlot` sends no pose while `NetManager.backgrounded`; on `host_away_changed(true)` `TouchControls` shows *Host away, waiting…*, the Player leaves `CUE` and refuses to enter it until the host is back. The shot-clock text also clears at `round_ended`.

### 2.7 Screens, regions and settings (06 P11, P12)
**One Theme.** `src/ui/theme/game_theme.tres` (project setting `gui/theme/custom`) styles every Control from the SVG sprites in `assets/ui/`; scenes carry no font-size or colour overrides, they pick a type variation (`HudLabel`, `Title`, `Heading`, `Caption`, `Payout`, `ToastInfo|Good|Bad`, `PrimaryButton`, `FlatButton`, `PanelInset`, `PanelPlate`, `ChipBox`). Custom-drawn widgets read the palette from the theme's `Game` type (`get_theme_color(&"brass", &"Game")`). Regenerate: `python3 src/tools/ui_art.py`, `--import`, `godot -s src/tools/build_ui_theme.gd`.

**Modal screens (`UIRouter`, `UIModal`).** `UILayer/UIRouter` watches every Control in group `ui_modal` (`open() / close() / is_open()`, `visible` is the state). At most one is open: a higher `priority` displaces the open one, which returns when the newcomer closes; an equal one replaces it; a lower one is held back. A `GameLoop.phase_changed` closes every modal without `keep_on_phase`. The router owns `Input.mouse_mode` (free while a modal is open; captured in-game on desktop), the single toast line (`toast(text, kind)`) and Esc (closes the top dismissable screen, else opens Pause). `Player` / `CueController` ignore input while `UIRouter.blocking()`. The simulation is never paused. Priorities: PhaseScreen -10 · BartenderMenu 0 · EventVote 20 · Pause 50 · Settings / Controls / Skins 60. The Lobby scene has its own router for Settings / Controls / Skins.
- `PhaseScreen` = Intermission, Reckoning, Game over, Campaign won (opens and closes itself from the phase; the lowest priority: every other screen hides it and it returns when that screen closes while the phase holds, so the host can always press Start Round; Esc opens Pause over it). The Intermission screen can be set aside ("Visit the bar" to walk to the counter); the next screen that opens and closes brings it back, and so does Pause, Resume. Game over and Campaign won offer **Back to menu** (`NetManager.leave()`) and, to the host, **New campaign** (`NetManager.start_game()`: every peer reloads `MainLevel` with a new seed). `EventVote` opens over the Intermission screen and closes on a pick, its 20 s clock, the Event applying or the phase moving on.
- `PauseMenu`: Resume · Settings · Controls (not on phones) · Leave to menu (a host with peers asks twice). It says the match keeps running. The HUD and the touch widgets stay under the dim; a toast hides while a screen is open.

**Region map** (canvas units, height 720, width ≥ 1280: a 2400×1080 phone is 1600×720; fixed, probe-checked in `tests/ui/ui_probe.gd`): stat bar `x[140, W-140] y[8, 64]` · shot clock `x[W/2±160] y[64, 104]` · toast `x[W/2±300] y[108, 152]` · call-pocket row `x[W/2±240] y[156, 228]` · host-away banner `y[232, 272]` · payout `x[240, W-240] y[576, 636]` · desktop prompt `x[W/2±200] y[H-76, H-36]` · touch: Pause `64` top corner, Back `96` top corner opposite, Jump / Shoot / Use or Place / Drop bottom right (`x ≥ W-216`), spin disc + elevation bottom left, power slider right edge `x[W-96, W-24] y[108, 612]`. Mirror swaps the sides. The seed lives on the F1 debug panel.

**Settings** (`Settings`, static, `user://settings.cfg`, loaded at boot by `NetManager._ready`): master volume · quality Auto / High / Medium / Low (`QualityManager`: Auto = `QualityLadder`, else tier 0 / 1 / 2 pinned) · FOV 60-110 · mouse / touch-look / cue-aim sensitivity (multipliers on the Player / CueController rates, 0.25-3x) · invert Y · touch mirror · show FPS. **Controls**: every gameplay key / mouse action (not `debug_*`, not the dormant `reset`), click-to-rebind (physical keys and mouse buttons), a clash swaps the two actions' bindings, reset to defaults; only changes from the defaults are written.

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
- `src/gameplay/player/Player.tscn` + `player.gd` — body, `Head/Camera3D`, mode state machine, interaction probe (`ShapeCast3D` sphere `2.0 m`, mask = `Interactable.LAYER`, read once per `_physics_process`). The sphere is only the broad phase: the prompt goes to the nearest `Interactable` whose feet-to-origin distance is `≤ 2.0 m`, the host's own test. The counter's three props (`bar_buy`, `bar_serve`, `throw_drink`) share one prompt, *Bartender*; **Interact** opens `BartenderMenu` (06 P17, 02 §3.6), a `ui_modal` with two tabs. **Drinks**: the host's random shelf of 5 tier-framed cards (name, description, buff lines green and debuff lines red, price, units left; Mystery cards red with glitching text; sold-out cards stay, greyed), a Serve / Throw mode switch and a crew-target row for Serve; every Buy / Throw button is ≥ 48 px and greys out from mirrored Cash, stock, Round phase and night limits. **Upgrades**: the fixed ball / cue / camera / table rows (Intermission only). A Drink pick sends `WorldInteractions.request(kind, 0, {drink_id, target_peer})` and the host validates (a Serve keeps the menu open so the stock can be watched, a Throw closes it); an Upgrade asks `EconomyManager.request_purchase`. Walking out of reach closes the menu; the `UIRouter` (06 P12) owns the mouse and blocks look / move / interact while it is open, so the menu itself never touches `Input.mouse_mode`. A rig someone carries is not offered. No two other `Interactable`s sit within 1 m of each other (probe-checked).
- `src/gameplay/cue/cue_controller.gd` — owns `CUE`: aim line, cue mesh, pullback, reads input from `TouchControls` or mouse/keys, builds the `ShotIntent`, calls `table.sim.request_shot(intent)`. The `gate` export is gone (host validates via `PhysicsSim.shot_validator`).
- `src/ui/TouchControls.tscn` + `virtual_stick.gd`, `look_pad.gd`, `power_slider.gd`, `spin_pad.gd` — each a `Control` handling `InputEventScreenTouch/Drag` by finger index in `_gui_input`; they expose values, they never call gameplay.
- Input actions added to `project.godot`: `interact`, `cue_mode`, `call_pocket_1..6` (existing `move_*`, `jump`, `shoot`, `spin_*`, `elevate_*`, `spin_reset` stay).
- Performance (07): no `get_node` in `_physics_process`, UI redraws only on value change, avatars are 3 draw calls each, `Label3D` not a `SubViewport`.

## 5. Interfaces to other modules
- **NET (04)**: `PlayerSlot.peer_id`, `is_local()`, pose blob in/out (`Player.pack_pose() -> PackedByteArray`, `apply_pose(blob)`); `PlayerSpawner.get_player_position(peer_id)`.
- **01/SYNC**: `RoundDirector.current_shooter_id` + `shooter_changed(peer_id)`; `PhysicsSim.request_shot(intent)`; `shot_rejected(reason)` shows a toast.
- **03/FX**: `Interactable.try_use(payload)`, `Interactable.prompt: String`; `EffectManager.get_stat(stat, peer_id, base)` for `cue_aim_wobble_deg`, `shot_clock_sec`, `rule_call_pocket`, `cue_power_mult` (display only — the host applies it).
- **02/ECON**: the counter's props open `BartenderMenu` locally (the host prices and stocks every purchase; the shelf is mirrored by `update_stock`, 04 §5). Camera grab and place are one toggle, the `move_camera` interaction (04 §5's `camera_grab`/`camera_place` rows are that): each `CameraRig` carries an `Interactable` (`Cameras._grab_prop`, `target_id` = rig number, prompt *Grab camera*); `CARRY` is derived from the holders `Cameras` mirrors in `push_rig_poses(poses, holders)` (`holders_changed`): held by me → `CARRY`, not mine any more → `WALK` with a *camera taken* toast, so a grab the host ignored can never desync. **Place**/**Drop** send it again with `place_at` (ahead of you / at your feet), subject to the 5 s cooldown.

## 6. Open questions
- Gamepad layout (PC/Steam Deck) — later.
- Camera comfort: should `CUE` fade in over `0.2 s` instead of snapping? Playtest.
- Cosmetics (seat colours are the whole v1 identity).

## 7. MVP cut vs later
**v1:** everything above. **Later:** gamepad, avatar animation rig, emotes, per-peer shooter mute (03 §3.4), aim assist line length as an upgrade.
