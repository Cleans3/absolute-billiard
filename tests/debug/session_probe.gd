extends SceneTree

## DebugSession on a bare Table + RoundDirector (no scene, no UI): live physics numbers reach the bodies, the balls, the
## BallMotion model and the client wire; every shot is recorded with its start; rewind puts the table back exactly; replay
## re-fires the intent and reports how far the balls ended from the first run; the table tools.
##   godot --path . --headless -s tests/debug/session_probe.gd      prints SESSION OK

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const SEED := 20261012
const REPLAY_TOLERANCE_M := 0.001  # a re-simulation of a shot with few collisions: millimetres (a break into a packed rack is chaotic, see DebugSession)

var table: Table
var director: RoundDirector
var session: DebugSession
var _fail := 0
var _ended := 0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	director = RoundDirector.new()
	director.table = table
	root.add_child(director)
	session = DebugSession.new()
	session.table = table
	session.director = director
	session.tuning_path = "user://debug_probe_%d.cfg" % OS.get_process_id()
	root.add_child(session)
	_run.call_deferred()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("SESSION: " + msg)


func _run() -> void:
	await physics_frame
	director.start_round(NightConfig.new(), 1, SEED)
	session.start()
	director.shot_ended.connect(func(_a: String, _b: int, _c: int, _d: Array[StringName], _e: bool) -> void: _ended += 1)
	for i in 120:
		await physics_frame
	await _tuning()
	await _shots()
	await _tools()
	DirAccess.remove_absolute(session.tuning_path)
	print("SESSION OK" if _fail == 0 else "SESSION FAILED: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _rail() -> StaticBody3D:
	for c in table.get_children():
		if c is StaticBody3D and c.has_meta(&"rail_normal"):
			return c
	return null


func _tuning() -> void:
	var spec := table.spec
	var ball := director.get_balls()[1]
	session.set_field(&"rolling_resistance", 0.05)
	session.set_field(&"ball_linear_damp", 0.2)
	session.set_field(&"cushion_friction", 0.31)
	session.set_field(&"cloth_friction", 0.33)
	session.set_field(&"ball_cascade_enabled", 0.0)
	await physics_frame
	_check(is_equal_approx(spec.rolling_resistance, 0.05), "the spec took the slider value")
	_check(is_equal_approx(ball.motion.roll_mu, 0.05), "BallMotion's model follows the spec")
	_check(is_equal_approx(ball.linear_damp, 0.2) and ball.linear_damp_mode == RigidBody3D.DAMP_MODE_REPLACE, "the live balls carry the damping")
	_check(is_equal_approx(_rail().physics_material_override.friction, 0.31), "the cushion bodies carry the new friction, no rebuild")
	_check(is_equal_approx((table.get_node("Bed") as StaticBody3D).physics_material_override.friction, 0.33), "so does the bed")
	_check(not spec.ball_cascade_enabled, "a flag field is a 0/1 slider")
	_check(session.tuning_text().contains("rolling_resistance = 0.05"), "the changed numbers are listed for pasting")
	_check(not session.is_default(&"rolling_resistance"), "and flagged as changed")

	var wire := table.sim.motion_stats()
	var client := TableSpec.new()
	client.apply_live_values(wire.slice(4))
	_check(client.rolling_resistance == spec.rolling_resistance and client.ball_linear_damp == spec.ball_linear_damp and not client.ball_cascade_enabled, "the shot-start stats carry every live number: a client models from the host's")

	session.save_tuning()
	session.set_defaults()
	await physics_frame
	_check(session.is_default(&"rolling_resistance") and ball.linear_damp == 0.0 and spec.ball_cascade_enabled, "defaults put everything back, live")
	_check(session.load_tuning() and is_equal_approx(spec.rolling_resistance, 0.05), "a saved tuning loads again")
	session.set_defaults()
	await physics_frame


## Fires the Round's break, rewinds, replays.
func _shots() -> void:
	var cue := _cue()
	var angle := session.aim_at_nearest()
	_check(not is_nan(angle), "there is a ball to aim at")
	_check(session.shots.is_empty(), "nothing recorded before the first shot")
	var start := _positions()
	var before := _ended
	_check(session.fire(angle, 0.8), "the Round's own shot path takes the shot")
	_check(director.shot_in_progress, "and it is a live Shot")
	await director.shot_ended
	await physics_frame
	_check(session.shots.size() == 1 and session.shots[0].done, "the shot was recorded and finished")
	var rec: DebugSession.ShotRecord = session.shots[0]
	_check(rec.shot_id == "n0-r1-s1" or rec.shot_id.begins_with("n"), "with the director's own shot id (%s)" % rec.shot_id)
	_check(is_equal_approx(rec.intent.power, 0.8) and rec.balls.size() == director.get_balls().size(), "its intent and the balls it started from")
	var moved := _distance(start, _positions())
	_check(moved > 0.3, "the break moved the balls (%.2f m)" % moved)

	_check(session.rewind(rec), "rewind works between shots")
	await _rested()
	var back := _distance(start, _positions())
	print("rewind: balls %.3f mm from where the shot started" % (back * 1000.0))
	_check(back < 0.004, "rewind puts every ball back (%.3f mm off)" % (back * 1000.0))
	_check(cue.global_position.distance_to(rec.balls[0].pos) < 0.004, "the cue ball too")

	var ok: bool = await session.replay(rec)
	await physics_frame
	_check(ok and _ended == before + 2, "replay ran the shot again through the normal path (shots ended: %d)" % (_ended - before))
	_check(session.shots.size() == 1, "and did not add a record of its own")
	print("replay: balls ended %.2f mm from the first run, %d replay" % [rec.error_m * 1000.0, rec.replays])
	_check(rec.replays == 1 and rec.error_m >= 0.0, "replay reports how close it ended (%.1f mm; a break into a packed rack is chaotic: 10 mm to 2.2 m, so it is not gated)" % (rec.error_m * 1000.0))
	_check(rec.label().contains("replay"), "the list shows it")

	_check(not session.fire(0.0, 0.5) or director.shot_in_progress, "a shot is only fired from a still table")
	await director.shot_ended
	await _rested()
	_check(session.shots.size() == 2, "a second shot, a second record")
	await session.replay_from(session.shots[0])
	await physics_frame
	_check(session.shots[0].replays == 2 and session.shots[1].replays == 1, "replay from here runs it and every later shot in order")
	session.clear_shots()
	_check(session.shots.is_empty() and session.last() == null, "clear empties the list")


func _tools() -> void:
	await _rested()
	session.apply_preset("stun")
	await _rested()
	var live := director.get_balls().filter(func(b: Ball) -> bool: return not b.retired)
	_check(live.size() == 2, "the stun preset leaves the cue ball and one object ball (%d)" % live.size())
	var obj: Ball = live.filter(func(b: Ball) -> bool: return not b.is_cue_ball)[0]
	var want := table.to_global(Vector3(table.spec.length_m * 0.15, obj.global_position.y - table.global_position.y, 0.0))
	_check(absf(obj.global_position.x - want.x) < 0.002 and absf(obj.global_position.z - want.z) < 0.002, "on the preset's spot")
	_check(is_equal_approx(session.aim_at_nearest(), 0.0), "aimed straight down the table")
	# a shot with few collisions: its replays end where the original did, every time
	_check(session.fire(0.0, 0.3), "a stun shot")
	await director.shot_ended
	await _rested()
	var stun: DebugSession.ShotRecord = session.last()
	for k in 3:
		var stun_ok: bool = await session.replay(stun)
		await physics_frame
		print("replay: the stun shot, replay %d, ended %.4f mm from its first run" % [k + 1, stun.error_m * 1000.0])
		_check(stun_ok and stun.error_m >= 0.0 and stun.error_m < REPLAY_TOLERANCE_M, "a stun shot replays to within %.1f mm every time (%.4f mm)" % [REPLAY_TOLERANCE_M * 1000.0, stun.error_m * 1000.0])
	session.clear_table()
	await _rested()
	_check(director.get_balls().filter(func(b: Ball) -> bool: return not b.retired).size() == 1, "clear table leaves the cue ball")
	session.reset_cue_ball()
	await _rested()
	var head: Vector3 = table.layout.spots.head
	_check(absf(table.to_local(_cue().global_position).x - head.x) < 0.002, "cue ball on the head spot")
	session.apply_preset("break")
	await _rested()
	_check(director.get_balls().filter(func(b: Ball) -> bool: return not b.retired).size() == 11, "the break preset deals the full rack")
	_check(not session.rerack(true), "re-rack needs a live GameLoop Round")


func _cue() -> Ball:
	return director.get_balls()[0]


func _positions() -> Dictionary:
	var out := {}
	for b in director.get_balls():
		out[b.net_id] = b.global_position
	return out


func _distance(a: Dictionary, b: Dictionary) -> float:
	var worst := 0.0
	for id in a:
		var p: Vector3 = a[id]
		var q: Vector3 = b[id]
		worst = maxf(worst, Vector2(p.x - q.x, p.z - q.z).length())  # the settle drop is vertical
	return worst


func _rested() -> void:
	for i in 3:
		await physics_frame
	var left := 400
	while table.sim.awake > 0 and left > 0:
		await physics_frame
		left -= 1
