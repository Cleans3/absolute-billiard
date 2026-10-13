extends SceneTree

## The jump shot really hops (adhoc-1014a V4, 01 §3 "Jump", S3): the host's Jolt ball leaves the cloth, flies the arc, lands and bounces, and the
## client's BallMotion draws the same path.
##   1. BallMotion on its own: Jolt's integrator is the model's parabola, the cloth impact conserves what it should, a bounce chain comes to rest.
##   2. Strokes (elevation x power x spin) on the host, each watched by SimDiff (events over a simulated 50 ms link into a BallReplica): the host
##      leaves the cloth, the model's path (BallMotion.advance from Ball.Plan.launch) is the host's to a few mm through the flight and the bounces,
##      the first landing is the same point to 2 mm, the client stays inside 5 mm of the host, and the event count stays small.
##   3. A jump clears one object ball (a flat stroke at the same ball hits it).
##   4. An airborne ball is not potted by the pocket it flies over; the same ball dropped into the mouth is.
##   5. S3: nothing acts on a ball in flight (cloth friction x3, tilt) and a locked cue clamps the elevation.
##   6. 12 random jump strokes into a full rack: every shot ends, every ball ends on the cloth, in a pocket or off the table (none hangs in the air or
##      on a rail), nothing is NaN, and the client reconstruction stays within a few mm of the host.
##   godot --path . --headless -s tests/physics/jump_probe.gd        prints JUMP OK

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const FLIGHT_M := 0.003      # model vs host while the ball is in the air (an integrator difference, not a modelling one)
const PATH_M := 0.008        # model vs host through the landing and the bounces after it (the slide to roll is the cloth model's, 01 §3: a few mm)
const LAND_M := 0.002        # the first touch-down, model vs host
const CLIENT_M := 0.005      # SimDiff gate (07 §3)
const EVENT_CAP := 60        # events one hop shot may stream (a plain roll sends ~3)
const MIN_HOP_M := 0.05
const AFTER_SEC := 0.4       # how long after the first touch-down the model is held to the host (a cushion ends the comparison)

## Cue ball against the physics clock: the sample at each tick's start is stamped with the time of all the steps before it.
class Rec extends Node:
	var ball: Ball
	var other: Ball
	var on := false
	var t := 0.0
	var ts := PackedFloat32Array()
	var ps := PackedVector3Array()
	var vs := PackedVector3Array()
	var os := PackedVector3Array()

	func arm() -> void:
		ts.clear()
		ps.clear()
		vs.clear()
		os.clear()
		t = 0.0
		on = true

	func _physics_process(delta: float) -> void:
		if not on:
			return
		ts.append(t)
		ps.append(ball.global_position)
		vs.append(ball.linear_velocity)
		os.append(other.global_position if other != null else Vector3.ZERO)
		t += delta


var table: Table
var rec := Rec.new()
var diff: SimDiff
var _fail := 0
var _balls: Array[Ball] = []
var _worst := {flight = 0.0, path = 0.0, land = 0.0, client = 0.0}
var _events_max := 0
var _apex_max := 0.0
var y := 0.0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	root.add_child(rec)
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("JUMP: " + msg)


func _run() -> void:
	await physics_frame
	_model()
	diff = SimDiff.new()
	root.add_child(diff)
	diff.attach(table.sim)
	await _strokes()
	await _clears_a_ball()
	await _pockets()
	await _nothing_acts_in_the_air()
	await _stress()
	_locked()
	print("jump: worst flight %.2f mm, path %.2f mm, first landing %.2f mm, client %.2f mm; at most %d events a shot; highest hop %.0f mm" % [
		_worst.flight * 1000.0, _worst.path * 1000.0, _worst.land * 1000.0, _worst.client * 1000.0, _events_max, _apex_max * 1000.0])
	if _fail > 0:
		printerr("JUMP FAILED: %d" % _fail)
		quit(1)
		return
	print("JUMP OK")
	quit()


# ---------------------------------------------------------------- 1. the model on its own

func _model() -> void:
	var r := table.spec.ball_radius_m
	var p := BallMotion.make_params(table.spec, r)
	var g := p.gravity
	var dt := 1.0 / 120.0
	_check(BallMotion.is_airborne(p.floor_y + 0.01, p.floor_y) and not BallMotion.is_airborne(p.floor_y + 0.001, p.floor_y), "is_airborne: over the cloth by more than AIRBORNE_EPS")
	# Jolt integrates v first, then x: the model's parabola passes through every one of its ticks
	var m := BallMotion.State.new()
	m.pos = Vector3(0.0, p.floor_y, 0.0)
	m.lin = Vector3(3.0, 2.0, -1.0)
	var j := BallMotion.State.new()
	j.pos = m.pos
	j.lin = m.lin
	var worst := 0.0
	for k in 40:
		j.lin.y -= g * dt
		j.pos += j.lin * dt
		var q := BallMotion.State.new()
		q.copy_from(m)
		BallMotion.advance(q, (k + 1) * dt, p)
		worst = maxf(worst, q.pos.distance_to(j.pos))
		if k == 38:
			_check(absf(q.lin.y - j.lin.y) < 1e-6, "the model's lin.y is Jolt's reported velocity (%f vs %f)" % [q.lin.y, j.lin.y])
	_check(worst < 0.0003, "the model's parabola is Jolt's integrator to %.2f mm over 40 ticks" % (worst * 1000.0))
	# the cloth: a rolling ball loses nothing but the bounce's share, a sliding one is slowed by Coulomb friction, a small rebound is a settle
	var s := BallMotion.State.new()
	s.lin = Vector3(4.0, -3.0, 0.0)
	s.ang = Vector3(0.0, 0.0, -4.0 / r)
	BallMotion.cloth_impact(s, p, 0.4)
	_check(is_equal_approx(s.lin.x, 4.0) and is_equal_approx(s.lin.y, 1.2), "rolling contact: no friction, e 0.4 of 3 m/s back up (%s)" % s.lin)
	s.lin = Vector3(4.0, -3.0, 0.0)
	s.ang = Vector3.ZERO
	BallMotion.cloth_impact(s, p, 0.4)
	_check(absf(s.lin.x - (4.0 - p.slide_mu * 3.0)) < 1e-6 and s.ang.z != 0.0, "sliding contact: friction takes mu x 3 m/s off a 4 m/s slide (%s)" % s.lin)
	s.lin = Vector3(0.0, -0.5, 0.0)
	BallMotion.cloth_impact(s, p, 0.4)
	_check(s.lin.y == 0.0, "a rebound under MIN_HOP_VY (%.2f) is a settle" % BallMotion.MIN_HOP_VY)
	s.lin = Vector3(0.0, -20.0, 0.0)
	BallMotion.cloth_impact(s, p, BallMotion.JUMP_E, BallMotion.JUMP_VY_MAX)
	_check(is_equal_approx(s.lin.y, BallMotion.JUMP_VY_MAX), "a stroke's rebound is capped at JUMP_VY_MAX")
	# a launch comes to rest on the cloth after a few bounces, and does not freeze at the top of one
	m.lin = Vector3(0.0, 3.0, 0.0)
	var t := 0.0
	var apex_held := true
	while not BallMotion.is_at_rest(m) and t < 20.0:
		BallMotion.advance(m, 0.01, p)
		t += 0.01
		if BallMotion.is_airborne(m.pos.y, p.floor_y) and m.lin == Vector3.ZERO:
			apex_held = false
	_check(apex_held and BallMotion.is_at_rest(m) and is_equal_approx(m.pos.y, p.floor_y), "a vertical launch bounces to rest on the cloth in %.1f s, never frozen mid-air (y %.4f)" % [t, m.pos.y])
	_check(t < 3.0, "the bounce chain ends (%.1f s)" % t)


# ---------------------------------------------------------------- 2. the strokes

func _strokes() -> void:
	# elevation, power, spin, aim (deg off +x): the lowest and the highest of the jump range, with follow, draw and side spin
	var cases := [
		[35.0, 0.45, Vector2(0.0, 0.0), 0.0],
		[45.0, 0.60, Vector2(0.0, 0.0), 8.0],
		[60.0, 0.80, Vector2(0.0, 0.0), -6.0],
		[60.0, 1.00, Vector2(0.0, 0.0), 0.0],
		[75.0, 0.70, Vector2(0.0, 0.5), 0.0],
		[50.0, 0.70, Vector2(0.0, -0.5), 4.0],
		[45.0, 0.70, Vector2(0.55, 0.0), 0.0],
		[80.0, 0.90, Vector2(0.0, 0.0), 0.0],
	]
	for c in cases:
		await _stroke(c[0], c[1], c[2], c[3])


func _stroke(elev: float, power: float, spin: Vector2, aim_deg: float) -> void:
	var sim := table.sim
	var cue := _ball(CUE_T, Vector3(-1.9, y, 0.0))
	rec.ball = cue
	for i in 90:
		await physics_frame
	var label := "elev %.0f power %.2f spin (%.1f, %.1f) aim %.0f" % [elev, power, spin.x, spin.y, aim_deg]
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT.rotated(deg_to_rad(aim_deg))
	intent.power = power
	intent.spin_offset = spin
	intent.elevation_deg = elev
	var plan := Ball.plan_strike(intent, sim.active_cue, cue.radius, cue.spec.max_ball_speed_mps)
	_check(plan.jump, "%s: a jump" % label)
	var launch := plan.launch(cue.radius, cue.motion)
	var d0 := diff.events
	diff.max_err_m = 0.0
	rec.arm()
	sim.request_shot(intent)
	await sim.all_resting
	for i in 30:
		await physics_frame
	rec.on = false
	var events := diff.events - d0
	_events_max = maxi(_events_max, events)
	# the host left the cloth, how high, and where it came down: the first sample after the top whose vertical speed is up again (the bounce) or
	# that is on the cloth
	var floor_y := cue.motion.floor_y
	var apex := 0.0
	var apex_i := -1
	var first_air := -1
	for i in rec.ps.size():
		var h := rec.ps[i].y - floor_y
		if first_air < 0 and h > BallMotion.AIRBORNE_EPS:
			first_air = i
		if first_air >= 0 and h > apex:
			apex = h
			apex_i = i
		if first_air >= 0 and i > apex_i + 2 and apex > 0.02 and h < apex - 0.02:
			break  # past the top, the first flight is the one measured
	var land_i := -1
	for i in range(maxi(apex_i, 1) + 2, rec.ps.size()):
		if rec.vs[i].y >= 0.0 or rec.ps[i].y - floor_y <= BallMotion.AIRBORNE_EPS:
			land_i = i
			break
	_apex_max = maxf(_apex_max, apex)
	_check(apex > MIN_HOP_M, "%s: the host's ball rose %.0f mm (a hop is over %.0f mm)" % [label, apex * 1000.0, MIN_HOP_M * 1000.0])
	_check(first_air >= 0 and land_i > first_air, "%s: the host's ball left the cloth and came down" % label)
	if land_i < 0:
		await _clear()
		return
	# the model from the same launch against the host, tick by tick: in the air, then through the touch-down and the bounces after it, until the
	# host meets a cushion (the model has none)
	var m := BallMotion.State.new()
	var s0 := BallMotion.State.new()
	s0.pos = rec.ps[0]
	s0.lin = launch.lin
	s0.ang = launch.ang
	var flight := 0.0
	var path := 0.0
	var m_apex := 0.0
	var t_end := rec.ts[land_i] + AFTER_SEC
	var err_series := ""
	for i in rec.ts.size():
		if rec.ts[i] > t_end or absf(rec.ps[i].x) > 2.3 or absf(rec.ps[i].z) > 1.1:
			break
		m.copy_from(s0)
		BallMotion.advance(m, rec.ts[i], cue.motion)
		var e := m.pos.distance_to(rec.ps[i])
		if i <= apex_i + 2 or i < land_i:
			m_apex = maxf(m_apex, m.pos.y - floor_y)
		if i < land_i:
			flight = maxf(flight, e)
		else:
			path = maxf(path, e)
			err_series += " %.1f" % (e * 1000.0)
	_worst.flight = maxf(_worst.flight, flight)
	_worst.path = maxf(_worst.path, path)
	_check(flight <= FLIGHT_M, "%s: in the air the model is %.2f mm off the host (limit %.0f)" % [label, flight * 1000.0, FLIGHT_M * 1000.0])
	_check(path <= PATH_M, "%s: through the landing and the %.1f s after it the model is %.2f mm off the host (limit %.0f; mm by tick:%s)" % [label, AFTER_SEC, path * 1000.0, PATH_M * 1000.0, err_series])
	_check(absf(m_apex - apex) <= 0.003, "%s: apex %.1f mm in the model, %.1f mm on the host" % [label, m_apex * 1000.0, apex * 1000.0])
	# the first touch-down: the same place at the same time
	var tl := BallMotion.time_to_land(s0, cue.motion)
	m.copy_from(s0)
	BallMotion.advance(m, tl + 1.0 / 120.0, cue.motion)
	var host_at := _host_at(tl + 1.0 / 120.0)
	var land_err := Vector2(m.pos.x - host_at.x, m.pos.z - host_at.z).length()
	_worst.land = maxf(_worst.land, land_err)
	_check(land_err <= LAND_M, "%s: the first touch-down is %.2f mm apart, model vs host (limit %.0f)" % [label, land_err * 1000.0, LAND_M * 1000.0])
	_check(absf(rec.ts[land_i] - tl) <= 1.0 / 60.0, "%s: the host touches down at %.3f s, the model at %.3f s" % [label, rec.ts[land_i], tl])
	# no friction while it flew: the horizontal speed held through the flight
	if land_i > first_air + 6:
		var v0 := Vector2(rec.vs[first_air + 2].x, rec.vs[first_air + 2].z).length()
		var v1 := Vector2(rec.vs[land_i - 2].x, rec.vs[land_i - 2].z).length()
		_check(absf(v1 - v0) <= 0.02, "%s: horizontal speed %.3f -> %.3f m/s across the flight (nothing acts on a ball in the air)" % [label, v0, v1])
	_worst.client = maxf(_worst.client, diff.max_err_m)
	_check(diff.max_err_m <= CLIENT_M, "%s: the client reconstruction is %.2f mm off the host (gate %.0f mm)" % [label, diff.max_err_m * 1000.0, CLIENT_M * 1000.0])
	_check(events <= EVENT_CAP, "%s: %d events streamed (cap %d)" % [label, events, EVENT_CAP])
	print("jump[%s]: apex %.0f mm, lands %.2f s, model vs host: flight %.2f mm, landing %.2f mm, +%.1f s %.2f mm; client %.2f mm, %d events" % [
		label, apex * 1000.0, rec.ts[land_i], flight * 1000.0, land_err * 1000.0, AFTER_SEC, path * 1000.0, diff.max_err_m * 1000.0, events])
	await _clear()


func _host_at(t: float) -> Vector3:
	for i in range(1, rec.ts.size()):
		if rec.ts[i] >= t:
			var span := rec.ts[i] - rec.ts[i - 1]
			return rec.ps[i - 1].lerp(rec.ps[i], 0.0 if span <= 0.0 else (t - rec.ts[i - 1]) / span)
	return rec.ps[rec.ps.size() - 1]


# ---------------------------------------------------------------- 3. over one ball

func _clears_a_ball() -> void:
	var sim := table.sim
	for elev in [60.0, 0.0]:
		var cue := _ball(CUE_T, Vector3(-1.9, y, 0.0))
		var obj := _ball(RED_T, Vector3(-1.3, y, 0.0))
		rec.ball = cue
		rec.other = obj
		for i in 90:
			await physics_frame
		var obj0 := obj.global_position
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2.RIGHT
		intent.power = 0.85
		intent.elevation_deg = elev
		var model := ShotModel.new()
		model.trace(cue, intent, sim.active_cue, table)
		rec.arm()
		sim.request_shot(intent)
		await sim.all_resting
		rec.on = false
		rec.other = null
		var min_h := INF  # the cue ball's height over the cloth as it passes the object ball's centre
		var past := -1    # the tick the cue ball is clear of the object ball (the far cushion can send it back later)
		var moved := 0.0
		for i in range(1, rec.ps.size()):
			if past < 0 and rec.ps[i - 1].x < obj0.x and rec.ps[i].x >= obj0.x:
				min_h = rec.ps[i].y - cue.motion.floor_y
			if past < 0 and rec.ps[i].x > obj0.x + 0.3:
				past = i
			if past < 0 or elev == 0.0:
				moved = maxf(moved, rec.os[i].distance_to(obj0))
		if elev > 0.0:
			_check(past > 0 and moved < 0.001, "a jump leaves the object ball where it was until the cue ball is past it (moved %.1f mm)" % (moved * 1000.0))
			_check(min_h >= 2.0 * cue.radius, "the cue ball passes over the object ball's centre %.0f mm up (needs %.0f)" % [min_h * 1000.0, 2.0 * cue.radius * 1000.0])
			_check(model.hit != ShotModel.Hit.BALL, "the guide agrees: no touch on the way over (hit %d at x %.2f)" % [model.hit, model.hit_pos.x])
			_check(model.has_land and model.land_pos.x > obj0.x, "the guide marks a landing beyond the ball (x %.2f)" % model.land_pos.x)
			print("jump over a ball: passes %.0f mm up, the guide lands it at x %.2f" % [min_h * 1000.0, model.land_pos.x])
		else:
			_check(moved > 0.05, "the same stroke flat hits it (moved %.0f mm)" % (moved * 1000.0))
			_check(model.hit == ShotModel.Hit.BALL, "the guide agrees: the flat stroke hits the ball")
		await _clear()


# ---------------------------------------------------------------- 4. pockets

func _pockets() -> void:
	var hole: TableLayout.Hole = null
	for h: TableLayout.Hole in table.layout.holes.values():
		if absf(h.center.x) < 0.05 and h.center.y > 0.0:
			hole = h
	_check(hole != null, "the table has a side pocket on +z")
	if hole == null:
		return
	var cue := _ball(CUE_T, Vector3(-0.5, y + 0.19, hole.center.y - 0.06))
	await physics_frame
	table.sim._on_struck(cue, ShotIntent.new())  # a shot is live: sensors armed, the ball thawed
	cue.apply_central_impulse(Vector3(4.0, 0.6, 0.0) * cue.mass)
	var over_h := -1.0
	var landed := false
	var t := 0.0
	while t < 1.5 and not cue.is_pocketed and not landed:
		await physics_frame
		t += 1.0 / 120.0
		var x := cue.global_position.x - table.global_position.x
		if absf(x) < 0.02:
			over_h = cue.global_position.y - cue.motion.floor_y
		landed = x > 0.3 and cue.global_position.y - cue.motion.floor_y <= BallMotion.AIRBORNE_EPS
	_check(over_h > 0.08, "the ball crossed the side pocket's mouth %.0f mm up" % (over_h * 1000.0))
	_check(not cue.is_pocketed and landed, "an airborne ball flying over a pocket's mouth is not potted: it lands on the cloth beyond (x %.2f)" % cue.global_position.x)
	await _clear()
	# dropped into the mouth: a pot, as always
	var drop := _ball(CUE_T, Vector3(hole.center.x, y + 0.2, hole.center.y - 0.02))
	await physics_frame
	table.sim._on_struck(drop, ShotIntent.new())
	t = 0.0
	while t < 2.0 and not drop.is_pocketed:
		await physics_frame
		t += 1.0 / 120.0
	_check(drop.is_pocketed, "a ball that comes down in the mouth is potted")
	await _clear()


# ---------------------------------------------------------------- 5. S3 and the locks

func _nothing_acts_in_the_air() -> void:
	var sim := table.sim
	var tracks: Array[PackedVector3Array] = []
	for mode in [0, 1]:
		sim.set_stat(&"cloth_friction_mult", 3.0 if mode == 1 else 1.0)
		sim.set_tilt_direction(Vector2(0.6, 0.8))
		sim.set_stat(&"table_tilt_deg", 1.5 if mode == 1 else 0.0)
		var cue := _ball(CUE_T, Vector3(-1.9, y, 0.0))
		rec.ball = cue
		for i in 90:
			await physics_frame
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2.RIGHT
		intent.power = 0.8
		intent.elevation_deg = 60.0
		rec.arm()
		sim.request_shot(intent)
		await sim.all_resting
		rec.on = false
		var a := PackedVector3Array()
		var started := false
		for i in rec.ps.size():
			var up := rec.ps[i].y - cue.motion.floor_y > BallMotion.AIRBORNE_EPS
			if up:
				started = true
				a.append(rec.ps[i])
			elif started:
				break  # the first flight only: the bounces after it meet a cloth that is not the same
		tracks.append(a)
		await _clear()
	sim.set_stat(&"cloth_friction_mult", 1.0)
	sim.set_stat(&"table_tilt_deg", 0.0)
	var n := mini(tracks[0].size(), tracks[1].size())
	var worst := 0.0
	for i in n:
		worst = maxf(worst, tracks[0][i].distance_to(tracks[1][i]))
	_check(n > 20, "both strokes flew (%d airborne ticks)" % n)
	_check(worst < 0.001, "cloth friction x3 and a 1.5 degree tilt change the flight by %.2f mm (nothing acts on a ball in the air)" % (worst * 1000.0))


func _locked() -> void:
	var cue := CueSpec.new()
	_check(cue.jump_unlocked, "a stock cue can jump from the start")
	cue.jump_unlocked = false
	_check(Ball.effective_elevation(70.0, Vector2.ZERO, cue) < Ball.JUMP_MIN_ELEVATION_DEG, "a cue without the jump stops short of it")
	cue.jump_unlocked = true
	_check(Ball.effective_elevation(120.0, Vector2.ZERO, cue) == Ball.MAX_ELEVATION_DEG, "the host never trusts an elevation past %.0f" % Ball.MAX_ELEVATION_DEG)
	_check(Ball.effective_elevation(70.0, Vector2(0.7, 0.0), cue) < Ball.MASSE_MIN_ELEVATION_DEG, "hard English without massé stops the cue short of it")


# ---------------------------------------------------------------- 6. a rack and random jumps

func _stress() -> void:
	var sim := table.sim
	var r := table.spec.ball_radius_m
	var cue := _ball(CUE_T, Vector3(-table.spec.length_m / 4.0, y, 0.0))
	var reds: Array[Ball] = []
	var apex_x := table.spec.length_m / 4.0
	var spots: Array[Vector3] = []
	for row in 5:
		for k in row + 1:
			spots.append(Vector3(apex_x + row * r * 1.74, y, (k - row * 0.5) * r * 2.02))
			reds.append(_ball(RED_T, spots[spots.size() - 1]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1014
	var worst_client := 0.0
	var hung := 0
	var ended_up := 0
	var left := 0
	for n in 12:
		cue.restore(Vector3(-table.spec.length_m / 4.0, y, rng.randf_range(-0.4, 0.4)))
		for i in reds.size():
			reds[i].restore(spots[i])
		for i in 90:
			await physics_frame
		while sim.awake > 0:
			await physics_frame
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2.RIGHT.rotated(deg_to_rad(rng.randf_range(-35.0, 35.0)))
		intent.power = rng.randf_range(0.4, 1.0)
		intent.elevation_deg = rng.randf_range(30.0, 80.0)
		intent.spin_offset = Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5))
		diff.max_err_m = 0.0
		var label := "stroke %d: elev %.0f power %.2f aim %.0f" % [n, intent.elevation_deg, intent.power, rad_to_deg(intent.aim_dir.angle())]
		sim.request_shot(intent)
		var t := 0.0
		while sim.awake > 0 and t < 20.0:
			await physics_frame
			t += 1.0 / 120.0
			for b in sim.get_balls():  # a hop over the cushion leaves the table: RoundDirector puts such a ball back (OFF_TABLE_RADII); here it is retired
				if b.global_position.y < b.motion.floor_y - 1.0 and not b.retired:
					left += 1
					b.retire()
		if sim.awake > 0:
			hung += 1
			_check(false, "%s: the shot did not end in 20 s (%d balls still awake: %s)" % [label, sim.awake, _awake_names(sim)])
			continue
		for i in 40:
			await physics_frame
		for b in sim.get_balls():
			if not b.global_position.is_finite() or not b.linear_velocity.is_finite():
				_check(false, "%s: a ball is NaN" % label)
				continue
			var local := table.to_local(b.global_position)
			var on_table := absf(local.x) < table.spec.length_m * 0.5 + 0.3 and absf(local.z) < table.spec.width_m * 0.5 + 0.3
			if b.is_pocketed or b.retired or not on_table:
				continue
			var h := b.global_position.y - b.motion.floor_y
			if absf(h) > 0.003:
				_check(false, "%s: a ball ended %.1f mm off the cloth plane at (%.2f, %.2f)" % [label, h * 1000.0, local.x, local.z])
			else:
				ended_up += 1
		worst_client = maxf(worst_client, diff.max_err_m)
	print("jump stress: 12 strokes into a rack, %d shots hung, %d balls rested on the cloth, %d left the table, worst client error %.2f mm" % [hung, ended_up, left, worst_client * 1000.0])
	_check(worst_client <= 0.008, "the client stays within 8 mm of the host through a jump into a rack (%.2f mm)" % (worst_client * 1000.0))
	await _clear()


func _awake_names(sim: PhysicsSim) -> String:
	var out := PackedStringArray()
	for b in sim.get_balls():
		if not b.is_resting and not b.freeze:
			out.append("%d at %s v %s" % [b.net_id, b.global_position, b.linear_velocity])
	return ", ".join(out)


# ---------------------------------------------------------------- helpers

func _clear() -> void:
	for b in _balls:
		if is_instance_valid(b):
			b.queue_free()
	_balls.clear()
	for i in 6:
		await physics_frame


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	_balls.append(b)
	return b
