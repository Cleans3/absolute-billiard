extends SceneTree

## The creep tail (adhoc-1012a REQ#creep): after the last ball slower than 0.3 m/s the shot used to run on for ~2.8 s with
## nothing on screen. Constant rolling drag takes 1.2 s to stop a 0.3 m/s ball and english decays only exponentially; the
## settle ramp and the constant spin loss fix both. Checks the BallMotion closed form against a fine numeric integration, a
## lone ball in the engine against the model, and 12-ball breaks (tail before/after, and under a 4° tilt).
##   godot --path . --headless -s tests/physics/creep_probe.gd      prints CREEP OK

const CUE := preload("res://src/resources/cues/demo_cue.tres")

const TAIL_FROM := 0.3  # m/s: below this nothing on screen is moving fast
const TAIL_MAX_MEDIAN := 0.8  # s from the last ball over TAIL_FROM to the table at rest
const SHOT_MAX_TILTED := 7.0  # s, the 4° tilt Event, median shot

var fx: PerfFixture
var _fail := 0


func _init() -> void:
	fx = PerfFixture.new()
	fx.params = {"x": 1}
	root.add_child(fx)
	_run.call_deferred()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("CREEP: " + msg)


func _med(a: Array) -> float:
	var s := a.duplicate()
	s.sort()
	return 0.0 if s.is_empty() else float(s[s.size() / 2])


## Reference: v' = -a·settle(v) - c·v integrated in 0.1 ms steps; returns [distance, seconds to stop].
func _numeric(v0: float, a: float, p: BallMotion.Params) -> Array:
	var v := v0
	var d := 0.0
	var t := 0.0
	var h := 0.0001
	while v > 0.0 and t < 60.0:
		var acc := a * BallMotion.settle_factor(v, p.settle_speed, p.settle_boost) + p.damp * v
		v -= acc * h
		d += maxf(v, 0.0) * h
		t += h
	return [d, t]


func _closed(v0: float, p: BallMotion.Params) -> Array:
	var s := BallMotion.State.new()
	s.pos.y = p.floor_y
	s.lin = Vector3(v0, 0.0, 0.0)
	s.ang = Vector3(0.0, 0.0, -v0 / p.radius)
	var t := 0.0
	while not BallMotion.is_at_rest(s) and t < 60.0:
		BallMotion.advance(s, 0.01, p)
		t += 0.01
	return [s.pos.x, t]


func _model() -> void:
	var spec := TableSpec.new()
	var r := spec.ball_radius_m
	var p := BallMotion.make_params(spec, r)
	var a := p.gravity * p.roll_mu
	for v0 in [0.12, 0.3, 0.8, 2.0, 5.0]:
		var ref := _numeric(v0, a, p)
		var got := _closed(v0, p)
		_check(absf(got[0] - ref[0]) < 0.003 + 0.01 * ref[0], "closed form roll from %.2f m/s: %.3f m vs numeric %.3f m" % [v0, got[0], ref[0]])
		_check(absf(got[1] - ref[1]) < 0.03 + 0.01 * ref[1], "closed form stop time from %.2f m/s: %.2f s vs numeric %.2f s" % [v0, got[1], ref[1]])
	var slow := _closed(TAIL_FROM, p)
	p.settle_boost = 0.0
	var plain := _closed(TAIL_FROM, p)
	print("creep model: a 0.3 m/s roll stops in %.2f s / %.2f m (constant drag: %.2f s / %.2f m)" % [slow[1], slow[0], plain[1], plain[0]])
	_check(is_equal_approx(plain[0], TAIL_FROM * TAIL_FROM / (2.0 * a)) or absf(plain[0] - TAIL_FROM * TAIL_FROM / (2.0 * a)) < 0.002, "boost 0 is the old constant drag")
	_check(slow[1] < 0.5 and plain[1] > 1.1, "the settle ramp stops a 0.3 m/s ball in under 0.5 s (was %.2f)" % plain[1])
	# viscous damping on top: still a closed form that matches
	p = BallMotion.make_params(spec, r)
	p.damp = 0.2
	for v0 in [0.2, 1.5]:
		var ref := _numeric(v0, a, p)
		var got := _closed(v0, p)
		_check(absf(got[0] - ref[0]) < 0.003 + 0.01 * ref[0], "with damping, roll from %.1f m/s: %.3f m vs %.3f m" % [v0, got[0], ref[0]])
	# spin about the normal: exponential + constant, reaches zero
	p = BallMotion.make_params(spec, r)
	p.rest_ang = 0.0  # keep the model from snapping a slow spin to rest: its own zero is what is tested
	var w := 8.0
	var k := p.roll_mu * p.spin_decay / (0.4 * r) + p.ang_damp
	var ref_w := w
	var tt := 0.0
	while ref_w > 0.0 and tt < 60.0:
		ref_w -= (k * ref_w + p.spin_stop) * 0.0001
		tt += 0.0001
	var s := BallMotion.State.new()
	s.pos.y = p.floor_y
	s.ang = Vector3(0.0, w, 0.0)
	s.lin = Vector3.ZERO
	BallMotion.advance(s, tt - 0.01, p)
	_check(s.ang.y > 0.0, "english is still turning just before its stop time (%.2f rad/s)" % s.ang.y)
	BallMotion.advance(s, 0.03, p)
	_check(s.ang.y == 0.0, "and gone just after (%.2f s for 8 rad/s)" % tt)
	_check(tt < 2.0, "8 rad/s of english is gone in under 2 s (%.2f s)" % tt)


func _lone(v0: float, w: float) -> Array:
	fx.reset_rack()
	await physics_frame
	var b := fx.cue_ball
	var s := fx.table.spec
	var y := fx.table.global_position.y + s.bed_height_m + s.ball_radius_m + s.clearance_margin_m
	b.restore(Vector3(fx.table.global_position.x - 2.0, y, fx.table.global_position.z))
	await physics_frame
	await physics_frame
	fx.table.sim._on_struck(b, ShotIntent.new())
	b.freeze = false
	b.is_resting = false
	b.linear_velocity = Vector3(v0, 0.0, 0.0)
	b.angular_velocity = Vector3(0.0, w, -v0 / b.radius)
	var x0 := b.global_position.x
	var f0 := Engine.get_physics_frames()
	while not b.is_resting and Engine.get_physics_frames() - f0 < 20 * PhysicsSim.LIVE_TICK:
		await physics_frame
	return [b.global_position.x - x0, (Engine.get_physics_frames() - f0) / float(PhysicsSim.LIVE_TICK)]


func _engine_vs_model() -> void:
	var p: BallMotion.Params = fx.cue_ball.motion
	for v0 in [0.25, 0.6, 1.0]:
		var jolt: Array = await _lone(v0, 0.0)
		var m := _closed(v0, p)
		print("creep lone ball %.2f m/s: Jolt %.3f m / %.2f s, model %.3f m / %.2f s" % [v0, jolt[0], jolt[1], m[0], m[1]])
		_check(absf(jolt[0] - m[0]) < 0.02 + 0.05 * m[0], "the model's roll-out from %.2f m/s is the engine's (%.3f vs %.3f m)" % [v0, m[0], jolt[0]])
		_check(absf(jolt[1] - m[1]) < 0.15 + 0.1 * m[1], "and its stop time (%.2f vs %.2f s)" % [m[1], jolt[1]])
	var spin: Array = await _lone(0.0, 8.0)
	print("creep lone ball 8 rad/s english: still after %.2f s" % spin[1])
	_check(spin[1] < 2.0, "english at standstill is gone in under 2 s (%.2f s)" % spin[1])


## Seconds from the last moment any ball was over TAIL_FROM to the table at rest, and the whole shot, per break.
func _breaks(n: int, seed_n: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_n
	var tails: Array = []
	var shots: Array = []
	var tps := float(PhysicsSim.LIVE_TICK)
	for i in n:
		fx.reset_rack()
		await physics_frame
		await physics_frame
		while fx.table.sim.awake > 0:
			await physics_frame
		var cue := fx.cue_ball
		var tgt: Ball = fx.balls[1 + rng.randi() % (fx.balls.size() - 1)]
		var d := Vector2(tgt.global_position.x - cue.global_position.x, tgt.global_position.z - cue.global_position.z)
		var it := ShotIntent.new()
		it.aim_dir = d.normalized().rotated(deg_to_rad(rng.randfn(0.0, 1.5)))
		it.power = rng.randf_range(0.4, 1.0)
		it.spin_offset = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 0.5)
		cue.strike(it, CUE)
		var f0 := Engine.get_physics_frames()
		var last_fast := 0.0
		var t := 0.0
		await physics_frame
		while fx.table.sim.awake > 0 and t < 20.0:
			t = (Engine.get_physics_frames() - f0) / tps
			for b in fx.balls:
				if not b.is_resting and not b.freeze and not b.is_pocketed and b.linear_velocity.length() > TAIL_FROM:
					last_fast = t
					break
			await physics_frame
		tails.append(t - last_fast)
		shots.append(t)
	return {tail = _med(tails), tail_max = tails.max(), shot = _med(shots), shot_max = shots.max()}


func _run() -> void:
	_model()
	await physics_frame
	fx.add_table()
	await physics_frame
	fx.spawn_balls(12)
	var spec := fx.table.spec
	await _engine_vs_model()

	var after: Dictionary = await _breaks(8, 7)
	spec.set_live(&"settle_boost", 0.0)
	spec.set_live(&"spin_stop_rad_s2", 0.0)
	fx.table.apply_physics()
	var before: Dictionary = await _breaks(6, 7)
	spec.set_live(&"settle_boost", TableSpec.new().settle_boost)
	spec.set_live(&"spin_stop_rad_s2", TableSpec.new().spin_stop_rad_s2)
	fx.table.apply_physics()
	print("creep break tail (last ball > %.1f m/s -> rest): median %.2f s, max %.2f s now; %.2f / %.2f s without the settle drag and spin loss. Shot median %.1f s (was %.1f s)" % [TAIL_FROM, after.tail, after.tail_max, before.tail, before.tail_max, after.shot, before.shot])
	_check(after.tail <= TAIL_MAX_MEDIAN, "median tail %.2f s over %.2f s" % [after.tail, TAIL_MAX_MEDIAN])
	_check(before.tail > 2.0 * after.tail, "the settle drag and spin loss are what ended the tail (%.2f s without)" % before.tail)

	# 4° tilt Event: the pull is capped under the rolling drag, so a tilted shot still ends
	fx.table.sim.set_stat(&"table_tilt_deg", 4.0)
	fx.table.sim.set_tilt_direction(Vector2(1.0, 0.5))
	var pull := fx.table.sim.tilt_accel(spec)
	var drag := 9.8 * spec.rolling_resistance
	_check(pull <= spec.tilt_max_vs_roll * drag + 1e-4 and pull < drag, "tilt pull %.3f m/s² is capped under the %.3f m/s² rolling drag" % [pull, drag])
	var tilted: Dictionary = await _breaks(8, 7)
	print("creep tilted 4°: shot median %.1f s, max %.1f s, tail %.2f s (uncapped it ran 9 s median)" % [tilted.shot, tilted.shot_max, tilted.tail])
	_check(tilted.shot <= SHOT_MAX_TILTED, "a 4° tilted break ends in %.1f s (median)" % tilted.shot)
	_check(tilted.tail <= 2.0 * TAIL_MAX_MEDIAN, "and has no creep tail (%.2f s)" % tilted.tail)

	print("CREEP OK" if _fail == 0 else "CREEP FAILED: %d" % _fail)
	quit(1 if _fail > 0 else 0)
