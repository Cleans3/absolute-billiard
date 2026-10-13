extends SceneTree

## The shot guide never lies (adhoc-1013c U13, 01 §3 "Shot guide"): over a grid of aim x spin x elevation x power (flat, draw/follow,
## side, jump and massé strokes) `ShotModel` traces the shot, then the host strikes the same intent for real and the two are held
## together: same first contact (a ball, a cushion, or none), the contact time inside the host's step, and the cue ball's whole
## path up to the contact within a tolerance. Tolerances (01 §3): a flat stroke (no elevation, spin < 0.6) 12 mm / 15 ms; anything
## else (elevated, massé, hard side spin: the cloth's answer to a downward cue is modelled, not measured) 40 mm / 40 ms; the
## struck ball's direction 6 degrees. Prints the worst error of each class, the hop height of the elevated strokes (the model
## assumes the dead cloth gives none: ShotModel.JUMP_BOUNCE) and the failing cases.
##   godot --path . --headless -s tests/physics/shot_guide_probe.gd        prints GUIDE OK

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const CUE := preload("res://src/resources/cues/demo_cue.tres")  # jump and massé unlocked
const SPINS: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(0.0, 0.7), Vector2(0.0, -0.7), Vector2(0.7, 0.0), Vector2(-0.5, 0.6)]
const ELEVATIONS: Array[float] = [0.0, 25.0, 40.0, 60.0]
const POWERS: Array[float] = [0.45, 0.85]
const FLAT_M := 0.012
const FLAT_S := 0.015
const SPECIAL_M := 0.040
const SPECIAL_S := 0.040
const OBJ_DEG := 6.0
const BORDERLINE_M := 0.006  # a guide that passes the object ball by less than this has no right answer to be held to
const WINDOW_SEC := 3.0


## Records the cue ball (and the object ball) against the physics clock: the sample at each tick's start is stamped with the
## time of all the steps before it, so the first step after a rest-rate strike (60 Hz -> 120 Hz) is the length it really was.
class Recorder extends Node:
	var cue: Ball
	var obj: Ball
	var on := false
	var t := 0.0
	var ts := PackedFloat32Array()
	var ps := PackedVector3Array()
	var os := PackedVector3Array()
	var kinds: Array[StringName] = []  ## every contact the cue ball reported, in order
	var ends := PackedFloat32Array()   ## end of the step that reported it
	var starts := PackedFloat32Array() ## start of that step: the contact is in (start, end]
	var first_kind := &""              ## the first contact that counts (see `pick`)
	var first_t := 0.0
	var first_prev := 0.0
	var prev_t := 0.0                  ## start of the latest step

	func arm() -> void:
		ts.clear()
		ps.clear()
		os.clear()
		t = 0.0
		kinds.clear()
		ends.clear()
		starts.clear()
		first_kind = &""
		on = true

	func _physics_process(delta: float) -> void:
		if not on:
			return
		ts.append(t)
		ps.append(cue.global_position)
		os.append(obj.global_position if obj != null else Vector3.ZERO)
		prev_t = t
		t += delta

	func contact(_ball: Ball, _other: Node, kind: StringName) -> void:
		if on:
			kinds.append(kind)
			ends.append(t)
			starts.append(prev_t)

	## The first contact that is one: a cushion, or a ball that really was struck. Jolt also reports a ball the cue ball only passes
	## within its contact margin of (a near miss); the object ball not moving gives that away.
	func pick() -> void:
		var struck := false
		for p in os:
			struck = struck or p.distance_to(os[0]) > 0.01
		first_kind = &""
		for i in kinds.size():
			if kinds[i] == &"RAIL" or struck:
				first_kind = kinds[i]
				first_t = ends[i]
				first_prev = starts[i]
				return


var table: Table
var rec := Recorder.new()
var model := ShotModel.new()
var y := 0.0
var _fail := 0
var _worst := {flat = [0.0, 0.0, 0.0], special = [0.0, 0.0, 0.0]}  # position m, time s, object degrees
var _hop := 0.0
var _runs := {flat = 0, special = 0}


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	root.add_child(rec)
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("GUIDE: " + msg)


func _run() -> void:
	await physics_frame
	var cue := _ball(CUE_T, Vector3(-1.6, y, 0.15))
	var obj := _ball(RED_T, Vector3(0.0, y, 0.0))
	rec.cue = cue
	rec.obj = obj
	cue.contacted.connect(rec.contact)
	for elev in ELEVATIONS:
		for spin in SPINS:
			for power in POWERS:
				await _case(cue, obj, spin, elev, power, true)
				await _case(cue, obj, spin, elev, power, false)
	print("guide: %d flat + %d special strokes; worst flat %.1f mm %.1f ms %.1f deg, worst special %.1f mm %.1f ms %.1f deg; highest hop of an elevated stroke %.0f mm" % [
		_runs.flat, _runs.special, _worst.flat[0] * 1000.0, _worst.flat[1] * 1000.0, _worst.flat[2], _worst.special[0] * 1000.0, _worst.special[1] * 1000.0, _worst.special[2], _hop * 1000.0])
	if _fail > 0:
		printerr("GUIDE FAILED: %d" % _fail)
		quit(1)
		return
	print("GUIDE OK")
	quit()


## One stroke: `with_ball` puts the object ball in the line (a 0.7 R cut), otherwise the aim is a 20 degree bank off the long cushion.
func _case(cue: Ball, obj: Ball, spin: Vector2, elev: float, power: float, with_ball: bool) -> void:
	var r := table.spec.ball_radius_m
	var start := Vector3(-1.6, y, 0.15)
	var dir := Vector2.RIGHT if with_ball else Vector2.RIGHT.rotated(deg_to_rad(20.0))
	cue.restore(start)
	obj.restore(start + Vector3(dir.x, 0.0, dir.y) * 1.3 + Vector3(-dir.y, 0.0, dir.x) * (0.7 * r) if with_ball else Vector3(1.0, y, -1.0))
	for i in 60:
		await physics_frame
	while table.sim.awake > 0:
		await physics_frame
	var intent := ShotIntent.new()
	intent.aim_dir = dir
	intent.power = power
	intent.spin_offset = spin
	intent.elevation_deg = elev
	var flat := elev <= 0.0 and spin.length() < Ball.MASSE_MIN_SPIN
	var label := "%s elev %.0f spin (%.1f, %.1f) power %.2f" % ["ball" if with_ball else "bank", elev, spin.x, spin.y, power]
	model.trace(cue, intent, CUE, table)
	if model.path_t.is_empty():
		_check(false, "%s: the guide traced nothing" % label)
		return
	var m_kind := &""
	match model.hit:
		ShotModel.Hit.BALL: m_kind = &"BALL"
		ShotModel.Hit.RAIL: m_kind = &"RAIL"
	var m_pocket := model.hit == ShotModel.Hit.POCKET
	var m_end := model.hit_time
	var m_pos := model.path.duplicate()
	var m_dir := model.obj_dir
	var m_ts := model.path_t.duplicate()
	var window := minf(m_end + 0.25, WINDOW_SEC)
	var borderline := with_ball and model.hit != ShotModel.Hit.BALL and _closest(model.path, obj.global_position) - 2.0 * r < BORDERLINE_M
	rec.arm()
	cue.strike(intent, CUE)
	while rec.t < window and table.sim.awake > 0:
		await physics_frame
	rec.on = false
	rec.pick()
	var tol_m := FLAT_M if flat else SPECIAL_M
	var tol_s := FLAT_S if flat else SPECIAL_S
	var cls := "flat" if flat else "special"
	_runs[cls] += 1
	var hop := 0.0  # highest the cue ball rose off the cloth before its first contact (after one, a bounce is not a hop)
	for i in rec.ps.size():
		if rec.first_kind != &"" and rec.ts[i] > rec.first_prev:
			break
		hop = maxf(hop, rec.ps[i].y - (table.spec.bed_height_m + r))
	if elev > 0.0:
		_hop = maxf(_hop, hop)
	# 1. the same first contact
	var host_kind := rec.first_kind
	if borderline:
		print("guide: %s: passes the object ball by under %.0f mm, first contact not held to account" % [label, BORDERLINE_M * 1000.0])
	elif m_pocket:
		_check(cue.is_pocketed or table.in_hole(Vector2(cue.global_position.x, cue.global_position.z)) or host_kind == &"", "%s: the guide drops the ball in a pocket, the host touched a %s" % [label, host_kind])
	elif m_kind == &"":  # the guide's stretch ended (rolled out, ran out of length) without a contact: the host may touch something later, not sooner
		_check(host_kind == &"" or rec.first_t >= m_end - 0.05, "%s: the guide's stretch ends untouched at %.3f s, the host hits '%s' at %.3f s" % [label, m_end, host_kind, rec.first_t])
	else:
		_check(host_kind == m_kind, "%s: the guide says first contact is '%s' at %.3f s, the host's is '%s' at %.3f s" % [label, m_kind, m_end, host_kind, rec.first_t])
	# 2. the contact lands inside the host's step (give or take the tolerance)
	if host_kind != &"" and host_kind == m_kind:
		var late := m_end - rec.first_t
		var early := rec.first_prev - m_end
		var terr := maxf(maxf(late, early), 0.0)
		_worst[cls][1] = maxf(_worst[cls][1], terr)
		_check(terr <= tol_s, "%s: contact time %.3f s vs the host's (%.3f, %.3f] s, %.0f ms off" % [label, m_end, rec.first_prev, rec.first_t, terr * 1000.0])
	# 3. the whole path up to the contact (a step before it)
	var worst := 0.0
	var upto := (m_end if m_kind != &"" else window) - 0.02
	for i in rec.ts.size():
		if rec.ts[i] > upto or rec.ts[i] > m_ts[m_ts.size() - 1]:
			break
		var e := (rec.ps[i] - _at(m_pos, m_ts, rec.ts[i])).length()
		worst = maxf(worst, e)
	_worst[cls][0] = maxf(_worst[cls][0], worst)
	_check(worst <= tol_m, "%s: the path is %.1f mm off the host's (tolerance %.0f mm), model contact '%s', hop %.0f mm" % [label, worst * 1000.0, tol_m * 1000.0, m_kind, hop * 1000.0])
	# 4. the struck ball leaves in the direction the guide draws
	if with_ball and host_kind == &"BALL" and m_dir != Vector3.ZERO:
		var moved := -1
		for i in rec.os.size():
			if rec.os[i].distance_to(rec.os[0]) > 0.04:
				moved = i
				break
		if moved > 0:
			var d := rec.os[moved] - rec.os[0]
			var deg := rad_to_deg(Vector2(d.x, d.z).angle_to(Vector2(m_dir.x, m_dir.z)))
			_worst[cls][2] = maxf(_worst[cls][2], absf(deg))
			_check(absf(deg) <= OBJ_DEG, "%s: the struck ball leaves %.1f degrees off the guide's line" % [label, deg])


## Shortest horizontal distance from `c` to the polyline `pts`.
func _closest(pts: PackedVector3Array, c: Vector3) -> float:
	var best := INF
	for i in range(1, pts.size()):
		var a := Vector2(pts[i - 1].x, pts[i - 1].z)
		var b := Vector2(pts[i].x, pts[i].z)
		var q := Geometry2D.get_closest_point_to_segment(Vector2(c.x, c.z), a, b)
		best = minf(best, q.distance_to(Vector2(c.x, c.z)))
	return best


## Linear interpolation of the model's samples at `t`.
func _at(pts: PackedVector3Array, ts: PackedFloat32Array, t: float) -> Vector3:
	for i in range(1, pts.size()):
		if ts[i] >= t:
			var span := ts[i] - ts[i - 1]
			return pts[i - 1].lerp(pts[i], 0.0 if span <= 0.0 else (t - ts[i - 1]) / span)
	return pts[pts.size() - 1]


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	return b
