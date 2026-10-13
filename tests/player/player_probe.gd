extends SceneTree
## Player v1 probe (docs/plan/08): mode transitions, touch widgets → values, touch intent == desktop intent,
## call-pocket lock, wobble, pose round trip, interact prompt, shop, camera CARRY.
##   godot --path . --headless -s tests/player/player_probe.gd
## Prints PLAYER OK, or the failing checks and PLAYER FAIL (exit 1).

const RADIUS := VirtualStick.RADIUS

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var sim: PhysicsSim
var table: Table
var player: Player
var controls: TouchControls
var cue: CueController
var captured: Array[ShotIntent] = []
var _fake_ms := 0


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("PLAYER FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, eps := 0.0005) -> bool:
	return absf(a - b) <= eps


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _physics(n: int) -> void:
	for i in n:
		await physics_frame


func _touch(node: Control, index: int, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	node._gui_input(e)


func _drag(node: Control, index: int, from: Vector2, to: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = to
	e.relative = to - from
	node._gui_input(e)


## The one place a probe waits for the level to be playable after pressing Solo: MainLevel loads on a thread
## behind the loading screen.
func _until_playable() -> void:
	await SoloSupport.until_playable(self)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_player"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	level = current_scene
	rd = level.get_node("RoundDirector")
	table = level.get_node("Table")
	sim = table.sim
	controls = level.get_node("UILayer/TouchControls")
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	_check(player != null, "local Player spawned")
	cue = player.cue
	controls.touch = true
	var loop: GameLoop = level.get_node("GameLoop")
	loop.advance()
	await _frames(30)
	await _physics(120)
	_check(sim.awake == 0, "rack at rest before the tests")
	await _widgets()
	await _modes()
	await _parity()
	await _pocket_and_wobble()
	await _pose()
	await _interact()
	await _background()
	finished = true
	print("PLAYER OK" if fails == 0 else "PLAYER FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


func _stand_by_cue_ball() -> void:
	var b := _cue_ball()
	player.global_position = Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


# --- widgets: synthetic touches → values -------------------------------------------------------------

func _widgets() -> void:
	await _frames(2)
	var st := controls.stick
	_check(st.size.x > 0.0, "stick has a layout size")
	_touch(st, 0, Vector2(200, 300), true)
	_drag(st, 0, Vector2(200, 300), Vector2(200 + RADIUS * 0.5, 300))
	var want := (0.5 - VirtualStick.DEAD_ZONE) / (1.0 - VirtualStick.DEAD_ZONE)
	_check(_near(st.value.x, want) and _near(st.value.y, 0.0), "stick right half: %s" % st.value)
	_drag(st, 0, Vector2.ZERO, Vector2(200, 300 - RADIUS * 3.0))
	_check(_near(st.value.y, -1.0), "stick up past the radius clamps to -1: %s" % st.value)
	_drag(st, 0, Vector2.ZERO, Vector2(200 + 4, 300))
	_check(st.value == Vector2.ZERO, "inside the dead zone reads zero")
	_touch(st, 0, Vector2(200, 300), false)
	_check(st.value == Vector2.ZERO, "stick released")
	# second finger does not steal the stick
	_touch(st, 0, Vector2(100, 300), true)
	_touch(st, 1, Vector2(400, 300), true)
	_drag(st, 1, Vector2.ZERO, Vector2(400, 200))
	_check(st.value == Vector2.ZERO, "a second finger's drag does not move the stick")
	_touch(st, 0, Vector2(100, 300), false)
	_touch(st, 1, Vector2(400, 300), false)
	# look pad: first finger drives, second flips fine
	var lp := controls.look
	lp.release()
	_touch(lp, 0, Vector2(600, 300), true)
	_drag(lp, 0, Vector2(600, 300), Vector2(700, 320))
	_check(lp.consume() == Vector2(100, 20) and lp.consume() == Vector2.ZERO, "look pad accumulates then clears")
	_check(not lp.fine, "one finger is not fine aim")
	_touch(lp, 1, Vector2(900, 300), true)
	_check(lp.fine, "second finger = fine aim")
	_touch(lp, 1, Vector2(900, 300), false)
	_touch(lp, 0, Vector2(700, 320), false)
	# spin pad: a tap opens the enlarged ball (tests/ui/shot_controls_probe.gd has the full overlay drive), a tap on it sets the point
	var sp := controls.spin_pad
	var got: Array[Vector2] = []
	var on_spin := func(v: Vector2) -> void: got.append(v)
	sp.changed.connect(on_spin)
	_touch(sp, 0, Vector2(60, 60), true)
	_touch(sp, 0, Vector2(60, 60), false)
	var face := controls.spin_overlay.face
	_check(controls.spin_overlay.visible and face.size.y > 0.0, "spin pad tap opens the enlarged ball")
	var r := minf(face.size.x, face.size.y) * 0.5 - 2.0
	_touch(face, 0, face.size * 0.5 + Vector2(0.5 * r, -0.25 * r), true)
	_check(got.size() == 1 and _near(got[0].x, 0.5) and _near(got[0].y, 0.25), "enlarged ball tap: %s" % [got])
	_touch(face, 0, Vector2.ZERO, false)
	controls.spin_overlay._reset.pressed.emit()
	_check(got.back() == Vector2.ZERO, "Reset centres the hit point")
	controls.spin_overlay.close()
	sp.changed.disconnect(on_spin)
	# power slider: only from the top, release strikes, under 3% cancels
	var pw := controls.power
	pw.size = Vector2(72, 500)
	var out: Array[float] = []
	var cancels := [0]
	pw.released.connect(func(v: float) -> void: out.append(v))
	pw.cancelled.connect(func() -> void: cancels[0] += 1)
	_touch(pw, 0, Vector2(30, 300), true)
	_check(pw.value == 0.0, "power slider ignores a press away from the top")
	_touch(pw, 0, Vector2(30, 20), true)
	_drag(pw, 0, Vector2.ZERO, Vector2(30, 350))
	_check(_near(pw.value, 0.7), "power follows travel: %f" % pw.value)
	_touch(pw, 0, Vector2(30, 350), false)
	_check(out.size() == 1 and _near(out[0], 0.7), "release strikes at the travelled value")
	_touch(pw, 0, Vector2(30, 20), true)
	_drag(pw, 0, Vector2.ZERO, Vector2(30, 200))
	_drag(pw, 0, Vector2.ZERO, Vector2(30, 5))
	_touch(pw, 0, Vector2(30, 5), false)
	_check(out.size() == 1 and cancels[0] == 1, "dragging back under 3% cancels")
	# elevation: the small control opens the enlarged cue angle, a tap on its protractor sets it
	var el := controls.elevation
	_touch(el, 0, Vector2(60, 36), true)
	_touch(el, 0, Vector2(60, 36), false)
	var eo := controls.elevation_overlay
	_check(eo.visible, "elevation tap opens the enlarged cue angle")
	var tap := eo._pivot + Vector2(-cos(deg_to_rad(20.0)), -sin(deg_to_rad(20.0))) * eo._radius * 0.8
	_touch(eo, 0, tap, true)
	_check(_near(el.value, 20.0), "elevation protractor tap: %f" % el.value)
	_touch(eo, 0, tap, false)
	_check(_near(el.value, 20.0), "elevation holds after release")
	eo.close()
	el.set_value(0.0)


# --- mode state machine ------------------------------------------------------------------------------

func _modes() -> void:
	var real_sink := cue.shot_sink
	var fired_intents: Array[ShotIntent] = []
	sim.shot_started.connect(func(_b: Ball, i: ShotIntent) -> void: fired_intents.append(i))
	_check(player.mode == Player.Mode.WALK, "starts in WALK")
	player.global_position = Vector3.ZERO
	rd.current_shooter_id = 99
	_check(not player.enter_cue(), "not the shooter: no CUE")
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	_check(not player.enter_cue(), "out of reach (%.2f m): no CUE" % player.cam.global_position.distance_to(_cue_ball().global_position))
	_stand_by_cue_ball()
	sim.awake = 1
	_check(not player.enter_cue(), "balls awake: no CUE")
	sim.awake = 0
	_check(player.enter_cue() and player.mode == Player.Mode.CUE and cue.active, "shooter + resting + in reach: CUE")
	var b := _cue_ball()
	await _frames(2)
	var behind := Vector2(player.global_position.x - b.global_position.x, player.global_position.z - b.global_position.z)
	_check(_near(behind.length(), CueController.BACK_M, 0.01), "camera %.3f m behind the cue ball" % behind.length())
	var fwd := -player.global_basis.z
	_check(_near(fwd.x * behind.y - fwd.z * behind.x, 0.0, 0.01) and behind.dot(Vector2(fwd.x, fwd.z)) < 0.0, "camera sits on the aim line, looking at the ball")
	_check(player.cam.global_position.y > b.global_position.y and player.head.rotation.x < 0.0, "eye above the ball, pitched down")
	var home := Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	controls.back_pressed.emit()
	_check(player.mode == Player.Mode.WALK and not cue.active, "Back leaves CUE")
	_check(player.global_position.distance_to(home) < 0.01, "Back restores where the player stood")
	_check(player.enter_cue(), "re-enter CUE")
	rd.current_shooter_id = 99
	rd.shooter_changed.emit(99)
	_check(player.mode == Player.Mode.WALK, "shooter change leaves CUE")
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	# stay where you shot (C16): aim west so the pinned spot is east of the ball, 3 m from where the player stood
	_check(player.enter_cue(), "CUE for the stay-put shot")
	cue.shot_sink = func(_i: ShotIntent) -> void: pass
	cue.aim_yaw = PI * 0.5
	await _frames(2)
	var pinned := player.global_position
	cue.fire(0.5)
	var stayed := player.global_position
	_check(player.mode == Player.Mode.WALK and stayed.distance_to(home) > 1.5, "fired: the player stays by the shot, not back at %s (now %s)" % [home, stayed])
	_check(stayed.distance_to(pinned) <= Player.SNAP_MAX_M and player._clear_of_table(stayed), "fired: snapped clear of the table outline within %.1f m of the aim spot (%.2f m)" % [Player.SNAP_MAX_M, stayed.distance_to(pinned)])
	_check(_near(player.rotation.y, PI * 0.5, 0.01), "fired: yaw kept")
	_check(_near(stayed.y, 0.0, 0.05), "fired: standing on the floor")
	sim.shot_rejected.emit(&"balls_moving")  # the host's refusal arrives over the wire: walk back
	_check(player.global_position.distance_to(home) < 0.01, "a late refusal restores the spot before aiming")
	player.global_position = stayed
	sim.shot_rejected.emit(&"balls_moving")
	_check(player.global_position.distance_to(stayed) < 0.01, "a second refusal moves nobody (nothing pending)")
	# the host refusing while fire() is still on the stack (host's own shot)
	player.global_position = home
	_check(player.enter_cue(), "CUE for the refused shot")
	cue.shot_sink = func(_i: ShotIntent) -> void: sim.shot_rejected.emit(&"balls_moving")
	cue.fire(0.5)
	_check(player.mode == Player.Mode.WALK and player.global_position.distance_to(home) < 0.01, "an inline refusal restores the spot before aiming")
	cue.shot_sink = real_sink
	# strike through the real path: touch power slider → request_shot → the host strikes
	_check(player.enter_cue(), "CUE again for the strike")
	await _frames(2)
	var strike_spot := player.global_position
	controls.power.size = Vector2(72, 500)
	_touch(controls.power, 0, Vector2(30, 10), true)
	_drag(controls.power, 0, Vector2.ZERO, Vector2(30, 250))
	_touch(controls.power, 0, Vector2(30, 250), false)
	_check(player.mode == Player.Mode.WALK and not cue.active, "strike leaves CUE")
	_check(player.global_position.distance_to(strike_spot) <= Player.SNAP_MAX_M and player._clear_of_table(player.global_position), "strike: the player stands by the shot")
	var by_strike := player.global_position
	_check(not player._verdict_pending, "the host's own accepted strike leaves no verdict pending")
	sim.shot_rejected.emit(&"balls_moving")  # an unrelated refusal later moves nobody
	_check(player.global_position.distance_to(by_strike) < 0.001, "...so a later refusal does not walk the player back")
	_check(fired_intents.size() == 1, "the host struck once (%d)" % fired_intents.size())
	if fired_intents.size() == 1:
		_check(_near(fired_intents[0].power, 0.5) and fired_intents[0].shooter_id == root.multiplayer.get_unique_id(), "strike carried the slider power")
	await sim.all_resting
	await _frames(5)
	cue.shot_sink = real_sink


# --- touch intent == desktop intent -------------------------------------------------------------------

func _drive_cue(dt: float, steps: int) -> void:
	for i in steps:
		cue._process(dt)


func _parity() -> void:
	await _physics(30)
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	captured.clear()
	cue.shot_sink = func(i: ShotIntent) -> void: captured.append(i)
	var yaw0 := 0.3
	# touch
	_stand_by_cue_ball()
	player.rotation.y = yaw0
	_check(player.enter_cue(), "parity: CUE (touch)")
	cue.set_process(false)
	cue.set_spin(Vector2.ZERO)
	cue.set_elevation(0.0)
	controls.set_mode(TouchControls.MODE_CUE)
	_touch(controls.look, 0, Vector2(600, 300), true)
	_drag(controls.look, 0, Vector2(600, 300), Vector2(700, 300))
	_touch(controls.look, 0, Vector2(700, 300), false)
	_drive_cue(1.0 / 60.0, 1)
	_touch(controls.spin_pad, 0, Vector2(60, 60), true)
	_touch(controls.spin_pad, 0, Vector2(60, 60), false)
	var face := controls.spin_overlay.face
	var r := minf(face.size.x, face.size.y) * 0.5 - 2.0
	_touch(face, 0, face.size * 0.5 + Vector2(0.3 * r, -0.5 * r), true)
	_touch(face, 0, Vector2.ZERO, false)
	controls.spin_overlay.close()
	_touch(controls.elevation, 0, Vector2(60, 36), true)
	_touch(controls.elevation, 0, Vector2(60, 36), false)
	var eo := controls.elevation_overlay
	var tap := eo._pivot + Vector2(-cos(deg_to_rad(20.0)), -sin(deg_to_rad(20.0))) * eo._radius * 0.8
	_touch(eo, 0, tap, true)
	_touch(eo, 0, tap, false)
	eo.close()
	controls.power.size = Vector2(72, 500)
	_touch(controls.power, 0, Vector2(30, 10), true)
	_drag(controls.power, 0, Vector2.ZERO, Vector2(30, 400))
	_touch(controls.power, 0, Vector2(30, 400), false)
	_check(captured.size() == 1, "parity: touch strike captured")
	# desktop
	controls.touch = false
	_stand_by_cue_ball()
	player.rotation.y = yaw0
	_check(player.enter_cue(), "parity: CUE (desktop)")
	cue.set_process(false)
	cue.set_spin(Vector2.ZERO)
	cue.set_elevation(0.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var mouse_live := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if mouse_live:
		var mm := InputEventMouseMotion.new()
		mm.relative = Vector2(deg_to_rad(cue.touch_aim_deg_per_px) * 100.0 / cue.mouse_aim_rad_per_px, 0.0)
		cue._unhandled_input(mm)
	else:
		print("note: headless mouse capture unavailable, desktop aim driven through cue.turn")
		cue.turn(-deg_to_rad(cue.touch_aim_deg_per_px) * 100.0)
	Input.action_press(&"spin_right")
	_drive_cue(1.0 / 60.0, 12)
	Input.action_release(&"spin_right")
	Input.action_press(&"spin_up")
	_drive_cue(1.0 / 60.0, 20)
	Input.action_release(&"spin_up")
	Input.action_press(&"elevate_up")
	_drive_cue(1.0 / 60.0, 20)
	Input.action_release(&"elevate_up")
	var press := InputEventAction.new()
	press.action = &"shoot"
	press.pressed = true
	cue._unhandled_input(press)
	_drive_cue(0.01, 64)
	_check(cue.charging and _near(cue.power, 0.8, 0.01), "desktop hold charges 0.8 in 0.64 s: %f" % cue.power)
	var rel := InputEventAction.new()
	rel.action = &"shoot"
	rel.pressed = false
	cue._unhandled_input(rel)
	_check(captured.size() == 2, "parity: desktop strike captured")
	if captured.size() == 2:
		var a := captured[0]
		var d := captured[1]
		_check(a.aim_dir.distance_to(d.aim_dir) < 0.001, "parity aim: %s vs %s" % [a.aim_dir, d.aim_dir])
		_check(_near(a.power, d.power, 0.02), "parity power: %f vs %f" % [a.power, d.power])
		_check(a.spin_offset.distance_to(d.spin_offset) < 0.01, "parity spin: %s vs %s" % [a.spin_offset, d.spin_offset])
		_check(_near(a.elevation_deg, d.elevation_deg, 0.1), "parity elevation: %f vs %f" % [a.elevation_deg, d.elevation_deg])
		_check(a.aim_dir.distance_to(Vector2(-sin(yaw0 - deg_to_rad(12.0)), -cos(yaw0 - deg_to_rad(12.0)))) < 0.001, "aim = yaw0 − 12° (100 px × 0.12°/px)")
	controls.touch = true
	cue.set_process(true)
	cue.set_spin(Vector2.ZERO)
	cue.set_elevation(0.0)


# --- call-pocket lock and wobble ------------------------------------------------------------------------

class FakeEffects:
	extends Node
	var stats := {}
	func get_stat(stat: StringName, _peer: int, base: float) -> float:
		return stats.get(stat, base)


func _pocket_and_wobble() -> void:
	var fx := FakeEffects.new()
	fx.stats = {&"rule_call_pocket": 1.0, &"cue_aim_wobble_deg": 4.0}
	level.add_child(fx)
	cue.effects = fx
	cue.cue_spec = cue.cue_spec.duplicate()
	captured.clear()
	_stand_by_cue_ball()
	_check(player.enter_cue(), "call-pocket: CUE")
	cue.set_process(false)
	_check(cue.call_required and controls.power.locked, "rule_call_pocket locks the power slider until a pocket is called")
	cue.release_power(0.5)
	_check(captured.is_empty() and cue.active, "release without a call fires nothing")
	controls.pocket_tapped.emit(2)
	_check(cue.called_pocket == table.layout.pockets[2].id and not controls.power.locked, "tapping marker 3 calls pocket 3 and unlocks power")
	cue._t = 1.0 / (4.0 * CueController.WOBBLE_HZ)  # sin = 1
	var base := cue.aim_yaw
	var i := cue.build_intent(0.5)
	var ang := atan2(-i.aim_dir.x, -i.aim_dir.y)
	_check(_near(ang - base, deg_to_rad(4.0), 0.0005), "intent carries the swayed yaw (+4°): %f" % rad_to_deg(ang - base))
	cue.cue_spec.wobble_reduction = 1.0
	cue.refresh_stats()
	i = cue.build_intent(0.5)
	ang = atan2(-i.aim_dir.x, -i.aim_dir.y)
	_check(_near(ang - base, deg_to_rad(3.0), 0.0005), "wobble_reduction is degrees, floored at 0: %f" % rad_to_deg(ang - base))
	cue.cue_spec.wobble_reduction = 9.0
	cue.refresh_stats()
	_check(_near(cue.swayed_yaw(), cue.aim_yaw), "reduction past the wobble floors at 0")
	cue.release_power(0.5)
	_check(captured.size() == 1 and captured[0].called_pocket == table.layout.pockets[2].id, "intent carries called_pocket")
	_check(player.mode == Player.Mode.WALK, "fired: back to WALK")
	# shot clock: RoundDirector's once-per-Turn seconds, counted down locally, mine only
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	rd.shot_clock_started.emit(5.0)
	_check(player.shot_clock_text() == "Shot clock 5", "shot clock text: '%s'" % player.shot_clock_text())
	rd.current_shooter_id = 99
	_check(player.shot_clock_text() == "", "no clock text when it is not my turn")
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	player._clock_end_msec = 0
	fx.stats = {}
	cue.effects = null
	fx.queue_free()
	cue.shot_sink = sim.request_shot


# --- pose round trip -----------------------------------------------------------------------------------

func _pose() -> void:
	player.global_position = Vector3(1.25, 0.5, -2.5)
	player.rotation.y = 1.0
	player.head.rotation.x = -0.3
	player._set_mode(Player.Mode.CUE)
	var blob := player.pack_pose()
	_check(blob.size() == Player.POSE_BYTES, "pose is %d B" % blob.size())
	player._set_mode(Player.Mode.WALK)
	var puppet: Player = load("res://src/gameplay/player/Player.tscn").instantiate()
	level.add_child(puppet)
	puppet.make_puppet("Tester", Player.skin_for_seat(0))
	puppet.apply_pose(blob.duplicate())
	_check(puppet.global_position.distance_to(Vector3(1.25, 0.5, -2.5)) < 0.001, "pose position round trip")
	_check(_near(puppet.rotation.y, 1.0, TAU / 65536.0 * 1.5), "pose yaw round trip: %f" % puppet.rotation.y)
	_check(_near(puppet.head.rotation.x, -0.3, 0.001), "pose pitch round trip: %f" % puppet.head.rotation.x)
	_check(puppet._avatar_cue.visible, "mode bits round trip: remote shooter shows the cue")
	# interpolation: a new pose is reached, not jumped to
	player.global_position = Vector3(3.25, 0.5, -2.5)
	player._set_mode(Player.Mode.WALK)
	puppet.apply_pose(player.pack_pose().duplicate())
	await create_timer(0.03).timeout
	_check(puppet.global_position.x < 3.24, "puppet renders behind the newest sample")
	await create_timer(0.35).timeout
	_check(puppet.global_position.distance_to(Vector3(3.25, 0.5, -2.5)) < 0.01, "puppet catches up within the 100 ms delay")
	_check(not puppet._avatar_cue.visible, "cue hides when the mode bits say WALK")
	puppet.queue_free()


# --- interact prompt, shop, camera carry --------------------------------------------------------------

func _stand_at(pos: Vector3, yaw := 0.0) -> void:
	player.collision_mask |= 1  # the level floor is still on layer 1 (PERF moves it to 4)
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = yaw  # a prompt needs the player facing the prop unless it is within 0.6 m (06 P33 U8)


## Every Label / Button text under `node`, joined: what a player can read on the cards.
func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for c in node.get_children():
		out += _all_text(c)
	return out


func _interact() -> void:
	await _physics(2)
	_stand_at(Vector3(6.0, 0.05, 5.5))
	await _physics(6)
	_check(player.prompt == "Jukebox", "prompt near the jukebox: '%s'" % player.prompt)
	_check(controls._prompt == "Jukebox", "prompt reaches the touch button")
	_stand_at(Vector3(-1.0, 0.05, 3.0))
	await _physics(6)
	_check(player.prompt == "", "no prompt out of reach: '%s'" % player.prompt)
	_stand_at(Vector3(3.5, 0.05, 2.5), -PI / 2.0)  # customer side of the counter (bar props at (4.2, 0, 2.5)), facing it (+X)
	await _physics(6)
	_check(player.prompt == "Bartender", "the three counter props share one prompt: '%s'" % player.prompt)
	var menu: BartenderMenu = level.get_node("UILayer/BartenderMenu")
	var econ: EconomyManager = level.get_node("EconomyManager")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	_check(menu.is_in_group(&"ui_modal") and not menu.is_open(), "the Bartender menu is a closed ui_modal")
	player.interact()
	_check(menu.is_open() and menu.visible and menu.kind == &"bar_serve", "Interact at the counter opens the Bartender")
	var shelf: Array[StringName] = [&"beer", &"energy_drink", &"static_shot", &"moonshine", &"bar_nuts"]
	econ.set_stock(econ.stock_key, shelf, [3, 2, 1, 1, 3] as Array[int])
	_check(menu._cards.get_child_count() == shelf.size(), "one card per offer")
	for id in shelf:
		_check(menu.drink_button(id).custom_minimum_size.y >= 48.0, "card %s is touch-sized" % id)
	menu.set_mode(&"throw_drink")
	_check(menu.kind == &"bar_serve" and not menu._throw.visible, "Solo: the menu offers no Throw (shop_ui_probe covers a crew)")
	econ.add_cash(1000, &"test")
	menu.set_mode(&"bar_serve")
	_check(not menu.drink_button(&"beer").disabled, "serve card beer is enabled with Cash: %s" % menu.drink_button(&"beer").text)
	_check(menu.drink_button(&"energy_drink").disabled, "intermission-only drink greyed while a Round is live")
	var bought: Array[StringName] = []
	econ.item_purchased.connect(func(id: StringName, _b: int) -> void: bought.append(id))
	var cash0 := econ.cash
	menu.drink_button(&"beer").pressed.emit()
	await _frames(2)
	_check(menu.is_open(), "a serve keeps the Bartender open so the stock can be watched")
	_check(bought == [&"beer"] and econ.cash == cash0 - ShopCatalog.item(&"beer").cost_cash, "serve went to the host: drink bought (%s)" % [bought])
	_check(econ.stock_left(0) == 2 and "2 left" in _all_text(menu._cards), "the card shows one unit fewer")
	var sold: Array[StringName] = [&"beer"]
	econ.set_stock(econ.stock_key, sold, [0] as Array[int])
	_check(menu.drink_button(&"beer").disabled and menu.drink_button(&"beer").text == "Sold out" and "SOLD OUT" in _all_text(menu._cards), "a sold-out offer stays visible, greyed")
	econ.set_stock(econ.stock_key, shelf, [3, 2, 1, 1, 3] as Array[int])
	var rejected: Array[StringName] = []
	world.interaction_rejected.connect(func(_k: StringName, r: StringName) -> void: rejected.append(r))
	menu.picked.emit(&"throw_drink", &"beer", root.multiplayer.get_unique_id())  # the menu never offers it to the shooter: the host still refuses
	await _frames(2)
	_check(rejected == [&"shooter_cant_grief"], "throw reached the host's hostile rules: %s" % [rejected])
	menu.close()
	_check(econ.stock_left(0) == 3, "a refused throw takes nothing off the shelf")
	player.interact()
	menu.set_mode(&"bar_serve")
	_check(menu.upgrade_button(&"heavy_shaft") != null and menu.upgrade_button(&"heavy_shaft").disabled, "the Upgrades tab lists the fixed rows, closed mid-Round")
	_check(menu.upgrade_button(&"heavy_shaft").custom_minimum_size.y >= 48.0, "upgrade buttons are touch-sized")
	_stand_at(Vector3(-1.0, 0.05, 3.0))
	await _physics(6)
	_check(not menu.is_open(), "walking away closes the Bartender")
	# no two Interactables closer than 1 m (except the counter's own three, and seats: the facing rule tells those apart)
	var props := get_nodes_in_group(&"interactable")
	for i in props.size():
		for j in range(i + 1, props.size()):
			var pa := props[i] as Interactable
			var pb := props[j] as Interactable
			if pa.effective_kind() in Player.BAR_KINDS and pb.effective_kind() in Player.BAR_KINDS:
				continue
			if pa.effective_kind() == Interactable.SIT or pb.effective_kind() == Interactable.SIT:
				continue
			_check(pa.global_position.distance_to(pb.global_position) >= 1.0, "%s and %s are %.2f m apart" % [pa.effective_kind(), pb.effective_kind(), pa.global_position.distance_to(pb.global_position)])
	# camera carry
	world.clock = func() -> int: return _fake_ms
	var cams: CameraRigs = level.get_node("Cameras")
	var rig := cams.rigs[0]
	_stand_at(rig.global_position + Vector3(-0.1, 0.05, 0.4))  # the base tripod stands at the north wall: stand in front of it, in the room
	await _physics(6)
	_check(player.prompt == "Grab camera", "camera rig prompts a grab: '%s'" % player.prompt)
	player.interact()
	await _frames(2)
	_check(player.mode == Player.Mode.CARRY, "grab → CARRY")
	_check(rig.held_by == root.multiplayer.get_unique_id(), "host marked the rig held")
	# host says someone else holds it: CARRY ends, and the rig is no longer offered
	rig.held_by = 999
	cams.holders_changed.emit()
	_check(player.mode == Player.Mode.WALK, "held_by mismatch ends CARRY")
	rig.held_by = root.multiplayer.get_unique_id()
	cams.holders_changed.emit()
	_check(player.mode == Player.Mode.CARRY, "held_by == me (re)enters CARRY")
	_fake_ms += 6000
	_stand_at(Vector3(-2.0, 0.05, 3.0))
	await _physics(4)
	player.place_camera(false)
	await _frames(3)
	_check(player.mode == Player.Mode.WALK, "place → WALK")
	_check(rig.held_by == 0 and rig.global_position.distance_to(Vector3(-2.0, 0.0, 3.0 - Player.PLACE_AHEAD_M)) < 0.05, "rig stands where it was placed: %s" % rig.global_position)


# --- backgrounding (04 §6) ------------------------------------------------------------------------------

func _background() -> void:
	var nm := root.get_node("NetManager")
	var slot := player.get_parent()
	_stand_by_cue_ball()
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	await _physics(30)
	# pose gate: a backgrounded peer sends nothing, so the send timer stands still
	nm.set_backgrounded(true)
	await _frames(2)
	var frozen: float = slot._accum
	await _frames(20)
	_check(slot._accum == frozen, "pose timer frozen while backgrounded")
	nm.set_backgrounded(false)
	await _frames(2)
	_check(slot._accum != frozen or slot._accum == 0.0, "pose timer runs again after resume")
	# banner: the host's app away → banner up, CUE refused / left; back → banner down
	_check(not controls._away.visible, "banner hidden at start")
	_check(player.enter_cue(), "CUE before the host leaves")
	nm.host_away_changed.emit(true)
	_check(controls._away.visible and player.mode == Player.Mode.WALK, "host away: banner up and CUE left")
	_check(not player.enter_cue(), "CUE refused while the host is away")
	nm.host_away_changed.emit(false)
	_check(not controls._away.visible and player.enter_cue(), "host back: banner down, CUE allowed")
	player.exit_cue()
	# shot clock cleared at Round end
	rd.shot_clock_started.emit(5.0)
	_check(player.shot_clock_text() == "Shot clock 5", "clock running before the Round ends")
	level.get_node("GameLoop").round_ended.emit(&"timer", 0)
	_check(player.shot_clock_text() == "", "clock cleared at round_ended")
