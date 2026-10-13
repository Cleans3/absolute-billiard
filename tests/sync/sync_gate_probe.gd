extends SceneTree

## Table-sync gate (06 P49): the client model (SimDiff: decode, sort, dead-reckon, rest frame, blend, every Shot started from
## the client's OWN state) against the host over N random shots on the real RoundDirector: breaks, pots, scratches, kitchen
## respawns, splitters. At the end of every shot, once the link and the 100 ms blend have played out, no ball the host has in
## play may be drawn more than 1 mm (3D, height included) from where the host has it.
##   godot --path . --headless -s tests/sync/sync_gate_probe.gd -- [--shots=60] [--seed=7] [--scale=20] [--legacy]
## `--legacy` throws the host's rest frames away: the client of before 06 P49 (the numbers in 06 P49's "before").
## Prints `SYNCGATE OK`.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")
const GATE_M := 0.001
const SETTLE_FRAMES := 90  # link (6) + delay (12) + blend (12), with room, at the 60 Hz rest tick

var table: Table
var director: RoundDirector
var diff: SimDiff
var shots := 60  # the contract number is 200 (`--shots=200`, ~6 min); 60 fits the suite's 300 s per probe
var seed_base := 7
var legacy := false
var verbose := false
var scale := 20.0
var rng := RandomNumberGenerator.new()


class FakeFx extends Node:
	signal effect_applied(id: StringName, target: int, owner: int, duration: float)
	signal effect_expired(id: StringName, target: int, owner: int)

	func get_stat(_stat: StringName, _peer: int, base: float, _crew := true) -> float:
		return base


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots = int(a.substr(8))
		elif a.begins_with("--seed="):
			seed_base = int(a.substr(7))
		elif a.begins_with("--scale="):
			scale = float(a.substr(8))
		elif a == "--legacy":
			legacy = true
		elif a == "--verbose":
			verbose = true
	table = TABLE.instantiate()
	root.add_child(table)
	var fx := FakeFx.new()
	fx.name = "EffectManager"
	root.add_child(fx)
	director = RoundDirector.new()
	director.table = table
	root.add_child(director)
	call_deferred("_run")


func _new_round(index: int) -> void:
	director.start_round(NIGHT_1, index, seed_base * 1000 + index)
	diff.reset()


func _run() -> void:
	Engine.time_scale = scale
	Engine.max_fps = 0  # the project caps frames at 60; a fast-forward wants them as fast as they come
	Engine.max_physics_steps_per_frame = maxi(8, int(scale * 4.0))  # the 8-step default is what caps a fast-forward
	rng.seed = seed_base
	await physics_frame
	diff = SimDiff.new()
	diff.use_rest = not legacy
	root.add_child(diff)
	diff.attach(table.sim)
	var round_index := 1
	_new_round(round_index)
	await _settle()
	var errs: Array[float] = []
	var breaks := 0
	var round_shots := 0
	var stream_b := 0
	var rest_b := 0
	var hb_b := 0
	var wrong := 0
	for k in shots:
		var fresh := round_shots == 0
		var b0 := diff.bytes
		var r0 := diff.rest_bytes
		var h0 := diff.heartbeat_bytes
		await _shoot(fresh)
		round_shots += 1
		breaks += 1 if fresh else 0
		await _settle()
		var e := diff.rest_error()
		errs.append(e)
		if verbose:
			var wb := table.sim._by_id[diff.rest_err_ball] as Ball if diff.rest_err_ball >= 0 else null
			print("  shot %d%s: end error %.3f mm (ball %d %s, y %.4f)" % [k, " BREAK" if fresh else "", e * 1000.0, diff.rest_err_ball, wb.ball_type.id if wb else "", wb.global_position.y if wb else 0.0])
		stream_b += diff.bytes - b0
		rest_b += diff.rest_bytes - r0
		hb_b += diff.heartbeat_bytes - h0
		if e > GATE_M:
			wrong += 1
		var live := 0
		for b in director.get_balls():
			if b.ball_type.counts_for_clear and b.ball_type.base_value > 0 and not b.is_pocketed and not b.retired:
				live += 1
		if live <= 1 or round_shots >= 12:  # the rack is (nearly) gone, or a Round's worth: next Round
			round_index += 1
			round_shots = 0
			_new_round(round_index)
			await _settle()
	var sorted := errs.duplicate()
	sorted.sort()
	var worst: float = sorted[sorted.size() - 1]
	var mean := 0.0
	for e in errs:
		mean += (0.0 if is_inf(e) else e) / errs.size()
	print("syncgate[%s]: %d shots (%d breaks, %d Rounds) | end-of-shot error: max %s mm, p95 %.3f mm, mean %.3f mm, %d shots over %.1f mm | in-flight max %.2f mm (ball %d, tick +%d)" % [
		"legacy" if legacy else "rest frames", shots, breaks, round_index, "inf" if is_inf(worst) else "%.3f" % (worst * 1000.0),
		sorted[int(sorted.size() * 0.95)] * 1000.0, mean * 1000.0, wrong, GATE_M * 1000.0, diff.max_err_m * 1000.0, diff.max_err_ball, diff.max_err_tick])
	print("syncgate: bytes/shot  stream %.0f  live heartbeat %.0f  rest %.0f" % [float(stream_b) / shots, float(hb_b) / shots, float(rest_b) / shots])
	if not legacy:
		if worst > GATE_M:
			printerr("SYNCGATE FAIL: client off by %.3f mm at the end of a shot" % (worst * 1000.0))
			quit(1)
			return
		print("SYNCGATE OK")
	else:
		print("SYNCGATE OK (legacy: numbers only)")
	quit()


func _settle() -> void:
	for i in 600:
		await physics_frame
		if i > SETTLE_FRAMES and table.sim.awake == 0 and not director.shot_in_progress:
			return


## One random shot: the break from the head spot on a fresh rack, else a random aim (half at an object ball), power, English.
func _shoot(fresh: bool) -> void:
	var cue: Ball = null
	var objs: Array[Ball] = []
	for b in director.get_balls():
		if b.retired or b.is_pocketed:
			continue
		if b.is_cue_ball:
			cue = b
		else:
			objs.append(b)
	var intent := ShotIntent.new()
	intent.shooter_id = 1
	if fresh and not objs.is_empty():
		var t := objs[rng.randi() % objs.size()]
		var d := t.global_position - cue.global_position
		intent.aim_dir = Vector2(d.x, d.z).normalized()
		intent.power = 1.0
	else:
		if rng.randf() < 0.6 and not objs.is_empty():
			var t2 := objs[rng.randi() % objs.size()]
			var d2 := t2.global_position - cue.global_position
			intent.aim_dir = Vector2(d2.x, d2.z).normalized().rotated(rng.randf_range(-0.15, 0.15))
		else:
			intent.aim_dir = Vector2.RIGHT.rotated(rng.randf() * TAU)
		intent.power = rng.randf_range(0.1, 1.0)
		intent.spin_offset = Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5))
		intent.elevation_deg = 0.0 if rng.randf() < 0.8 else rng.randf_range(0.0, 20.0)
	table.sim.request_shot(intent)
	var t0 := Time.get_ticks_msec()
	while director.shot_in_progress or table.sim.awake > 0 or Time.get_ticks_msec() - t0 < 50:
		await physics_frame
		if Time.get_ticks_msec() - t0 > 120000:
			printerr("shot never ended")
			quit(1)
			return
