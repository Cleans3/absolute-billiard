class_name ShotModel
extends RefCounted

## The shot guide's model (01 §3 "Shot guide"): where the cue ball goes from a live `ShotIntent`, built from the pieces the host runs,
## never a second physics. The launch is `Ball.plan_strike` (the host's own formula: speed, spin offset, elevation, miscue), every
## stretch between contacts is `BallMotion.advance` (the model clients reconstruct the host with: cloth friction, tilt and every live
## feel number are the host's), a ball-ball impact is `BallCollisions.simulate` (the host's resolver), a cushion applies
## `TableSpec.cushion_restitution_at` x the hazard's rail multiplier (what `Ball._rail_rebound` does) plus Coulomb friction on the
## tangent. Pure data, no nodes: `ShotGuide` draws it and `tests/physics/shot_guide_probe.gd` holds it against the host.
##
## Limits (01 §3): the first stretch runs to its first contact or `LEG1_MAX_M`; one more stretch follows a contact (the cue
## ball past a ball, the ball off a cushion) up to `LEG2_MAX_M` or the next contact; the struck ball's line is `OBJ_MAX_M`.
## Jaws, pocket drops and a ball struck by the struck ball are not followed.

enum Hit { NONE, BALL, RAIL, POCKET }

const STEP_M := 0.05  # distance between path samples on the cloth
const DT_MIN := 1.0 / 240.0
const DT_MAX := 1.0 / 30.0
const LEG1_MAX_M := 6.0
const LEG1_MAX_SEC := 8.0
const LEG2_MAX_M := 2.5
const OBJ_MAX_M := 1.2
const MAX_STEPS := 900
const CONTACT_LEAD_M := 0.0005  # a ball this close to a face and closing counts as touching
## Share of the downward speed an elevated cue gives the ball that the cloth sends back up. The cloth is dead (TableSpec.BASE_BOUNCE
## cancels its bounce), so a jump shot does not hop on its own: this is 0 until the probe shows the host lifting off.
const JUMP_BOUNCE := 0.0

# ---- result (valid after `trace`; arrays are reused, copy what outlives the next call)
var plan: Ball.Plan
var path := PackedVector3Array()      ## cue-ball centre, first stretch, world
var path_t := PackedFloat32Array()    ## seconds after the strike of each `path` point
var after := PackedVector3Array()     ## cue ball after the first contact
var obj_path := PackedVector3Array()  ## the struck ball, from its centre (a BALL hit only)
var hit := Hit.NONE                   ## what ends the first stretch (NONE = it rolls out, runs out of length or leaves the table)
var hit_time := 0.0
var hit_pos := Vector3.ZERO           ## cue-ball centre at the first contact: the ghost ball
var hit_normal := Vector3.ZERO        ## BALL: cue -> object; RAIL: the cushion's inward normal
var hit_ball: Ball
var hit_rail := &""
var obj_dir := Vector3.ZERO           ## the struck ball's direction after the impact (unit, horizontal)
var obj_speed := 0.0
var airborne := false                 ## some point of the first or second stretch is off the cloth
var land_pos := Vector3.ZERO
var has_land := false
var off_table := false
var rest_pos := Vector3.ZERO          ## where the first stretch ended when it ended at rest (`hit == NONE`)

var _cue: Ball
var _table: Table
var _sim: PhysicsSim
var _r := 0.0
var _cloth_y := 0.0
var _nose_h := 0.0
var _origin := Vector3.ZERO
var _obstacles: Array[Ball] = []
var _rail_a := PackedVector3Array()
var _rail_n := PackedVector3Array()
var _rail_e := PackedVector3Array()
var _rail_len := PackedFloat32Array()
var _rail_ids: Array[StringName] = []
var _prev := BallMotion.State.new()
var _c_kind := Hit.NONE
var _c_ball: Ball
var _c_rail := -1
var _elapsed := 0.0
var _t_scratch := PackedFloat32Array()  # sample times of the stretches that keep none


## Traces `intent` (power already chosen: a preview picks its own) for `cue` on `table`.
func trace(cue: Ball, intent: ShotIntent, cue_spec: CueSpec, table: Table) -> void:
	_reset()
	_cue = cue
	_table = table
	_sim = cue.sim
	var power_mult := 1.0
	var spin_radius := cue_spec.spin_offset_radius
	if _sim != null:
		power_mult = _sim.stat(&"cue_power_mult", intent.shooter_id, 1.0)
		spin_radius = _sim.stat(&"cue_spin_radius_mult", intent.shooter_id, spin_radius)
	plan = Ball.plan_strike(intent, cue_spec, cue.radius, cue.spec.max_ball_speed_mps, power_mult, spin_radius)
	if cue.motion == null or plan.speed <= 0.0 or plan.aim3 == Vector3.ZERO:
		return
	_r = cue.radius
	_cloth_y = table.global_position.y + cue.spec.bed_height_m
	_nose_h = cue.spec.cushion_nose_h_m
	_origin = table.global_position
	_gather()
	var s := BallMotion.State.new()
	_launch(s)
	path.append(s.pos)
	path_t.append(0.0)
	hit = _march(s, cue.motion, _r, path, path_t, 0.0, LEG1_MAX_M, null)
	hit_time = _elapsed
	hit_pos = s.pos
	match hit:
		Hit.NONE:
			rest_pos = s.pos
		Hit.BALL:
			_after_ball(s)
		Hit.RAIL:
			hit_rail = _rail_ids[_c_rail]
			hit_normal = _rail_n[_c_rail]
			_bounce(s, _c_rail)
			_march(s, cue.motion, _r, after, _t_scratch, _elapsed, LEG2_MAX_M, null)


## Cue-ball centre `t` seconds after the strike along the first stretch (linear between samples; the last point past its end).
func position_at(t: float) -> Vector3:
	var n := path.size()
	if n == 0:
		return Vector3.ZERO
	for i in range(1, n):
		if path_t[i] >= t:
			var span := path_t[i] - path_t[i - 1]
			return path[i - 1].lerp(path[i], 0.0 if span <= 0.0 else (t - path_t[i - 1]) / span)
	return path[n - 1]


func _reset() -> void:
	path.clear()
	path_t.clear()
	after.clear()
	obj_path.clear()
	_t_scratch.clear()
	hit = Hit.NONE
	hit_time = 0.0
	hit_pos = Vector3.ZERO
	hit_normal = Vector3.ZERO
	hit_ball = null
	hit_rail = &""
	obj_dir = Vector3.ZERO
	obj_speed = 0.0
	airborne = false
	has_land = false
	off_table = false
	rest_pos = Vector3.ZERO
	plan = null
	_cue = null
	_elapsed = 0.0


## Obstacle balls and the cushion faces, in world space, once per trace.
func _gather() -> void:
	_obstacles.clear()
	if _sim != null:
		for b in _sim.get_balls():
			if b != _cue and not b.retired and not b.is_pocketed and b.is_inside_tree():
				_obstacles.append(b)
	var rails := _table.layout.rails
	_rail_a.resize(rails.size())
	_rail_n.resize(rails.size())
	_rail_e.resize(rails.size())
	_rail_len.resize(rails.size())
	_rail_ids.resize(rails.size())
	for i in rails.size():
		var rl := rails[i]
		_rail_a[i] = _table.to_global(rl.a)
		_rail_n[i] = rl.inward_normal
		_rail_e[i] = (rl.b - rl.a).normalized()
		_rail_len[i] = rl.a.distance_to(rl.b)
		_rail_ids[i] = rl.id


## Velocity and spin the impulse gives (L = offset x J over I = 0.4 m R²), then the cloth's answer to a downward cue: it takes the
## downward speed (`JUMP_BOUNCE` of it comes back up) and Coulomb friction at the contact point works on the slip for as long
## as that impulse lasts, which is what turns an elevated stroke into forward roll.
func _launch(s: BallMotion.State) -> void:
	s.pos = _cue.global_position
	s.lin = plan.aim3 * plan.speed
	s.ang = plan.offset.cross(plan.aim3) * (plan.speed / (0.4 * _r * _r))
	if s.lin.y >= 0.0:
		return
	var down := -s.lin.y
	var rc := Vector3(0.0, -_r, 0.0)
	var u := s.lin + s.ang.cross(rc)
	u.y = 0.0
	var ul := u.length()
	if ul > 1e-6:
		var mu := _cue.motion.slide_mu * _cue.motion.friction_mult
		var jt := minf(mu * down, ul / 3.5)
		var j := -u / ul * jt
		s.lin += j
		s.ang += rc.cross(j) / (0.4 * _r * _r)
	s.lin.y = JUMP_BOUNCE * down


## Marches `s` along `params` until it touches a ball or a cushion (returns Hit.BALL / Hit.RAIL, `_c_*` says which), drops into a
## pocket (Hit.POCKET), or ends (Hit.NONE: at rest, `max_m` long, off the table). Samples go to `pts` / `ts`; `_elapsed` is the
## time at the end, `t0` the time at the start.
func _march(s: BallMotion.State, params: BallMotion.Params, radius: float, pts: PackedVector3Array, ts: PackedFloat32Array, t0: float, max_m: float, skip: Ball) -> Hit:
	var t := t0
	var moved := 0.0
	var steps := 0
	var spec := _cue.spec
	var reach_x := spec.length_m * 0.5 + spec.rail_width_m
	var reach_z := spec.width_m * 0.5 + spec.rail_width_m
	while steps < MAX_STEPS and moved < max_m and t - t0 < LEG1_MAX_SEC:
		steps += 1
		var dt := clampf(STEP_M / maxf(s.lin.length(), 0.3), DT_MIN, DT_MAX)
		_prev.copy_from(s)
		BallMotion.advance(s, dt, params)
		if s.pos.y > params.floor_y + BallMotion.AIR_TOL:
			airborne = true
		elif airborne and not has_land and s.lin.y == 0.0:
			has_land = true
			land_pos = s.pos
		var f := _contact(_prev.pos, s.pos, radius, skip)
		if f >= 0.0:
			var kind := _c_kind
			s.copy_from(_prev)
			BallMotion.advance(s, dt * f, params)
			t += dt * f
			_push(pts, ts, s.pos, t)
			_elapsed = t
			return kind
		t += dt
		moved += s.pos.distance_to(_prev.pos)
		_push(pts, ts, s.pos, t)
		var local := s.pos - _origin
		if _table.in_hole(Vector2(local.x, local.z)):
			_elapsed = t
			return Hit.POCKET
		if absf(local.x) > reach_x or absf(local.z) > reach_z:
			off_table = true
			break
		if BallMotion.is_at_rest(s):
			break
	_elapsed = t
	return Hit.NONE


func _push(pts: PackedVector3Array, ts: PackedFloat32Array, p: Vector3, t: float) -> void:
	pts.append(p)
	ts.append(t)


## Earliest touch of a ball of `radius` moving p0 -> p1 with an obstacle ball or a cushion face, as a fraction of the step (-1: none).
## Sets `_c_kind` / `_c_ball` / `_c_rail`. A cushion face is the nose line pushed in by `radius`; an airborne ball clears it when its bottom is above the nose.
func _contact(p0: Vector3, p1: Vector3, radius: float, skip: Ball) -> float:
	var d := p1 - p0
	var a := d.dot(d)
	_c_kind = Hit.NONE
	if a < 1e-12:
		return -1.0
	var best := 2.0
	for b in _obstacles:
		if b == skip:
			continue
		var rr := radius + b.radius
		var f := p0 - b.global_position
		var bb := f.dot(d)
		var cc := f.dot(f) - rr * rr
		var t := -1.0
		if cc <= 0.0:
			if bb < 0.0:
				t = 0.0  # touching and closing
		else:
			var disc := bb * bb - a * cc
			if disc >= 0.0:
				t = (-bb - sqrt(disc)) / a
				if t > 1.0:
					t = -1.0
		if t >= 0.0 and t < best:
			best = t
			_c_kind = Hit.BALL
			_c_ball = b
	for i in _rail_n.size():
		var d0 := (p0 - _rail_a[i]).dot(_rail_n[i])
		var d1 := (p1 - _rail_a[i]).dot(_rail_n[i])
		var t := -1.0
		if d0 > radius + CONTACT_LEAD_M and d1 <= radius:
			t = (d0 - radius) / (d0 - d1)
		elif d0 <= radius + CONTACT_LEAD_M and d1 < d0 - 1e-7:
			t = 0.0  # resting against the cushion and driven into it
		if t >= 0.0 and t < best:
			var q := p0 + d * t
			var u := (q - _rail_a[i]).dot(_rail_e[i])
			if u >= 0.0 and u <= _rail_len[i] and q.y - radius - _cloth_y < _nose_h:
				best = t
				_c_kind = Hit.RAIL
				_c_rail = i
	return best if _c_kind != Hit.NONE else -1.0


## `s` is at the first ball contact: the host's resolver on the pair gives both balls' velocity and spin. The cue ball goes on
## from there; the struck ball's line runs to its first contact or `OBJ_MAX_M`.
func _after_ball(s: BallMotion.State) -> void:
	hit_ball = _c_ball
	var spec := _cue.spec
	var a := BallCollisions.Body.new()
	a.pos = s.pos
	a.vel = s.lin
	a.ang = s.ang
	a.mass = _cue.mass
	a.radius = _r
	var b := BallCollisions.Body.new()
	b.pos = hit_ball.global_position
	b.mass = hit_ball.mass
	b.radius = hit_ball.radius
	var bodies: Array[BallCollisions.Body] = [a, b]
	BallCollisions.simulate(bodies, 1.0 / float(PhysicsSim.LIVE_TICK), spec.ball_restitution, spec.ball_friction)
	var n := b.pos - a.pos
	hit_normal = n.normalized() if n.length() > 1e-6 else Vector3.ZERO
	obj_speed = b.vel.length()
	var flat := Vector3(b.vel.x, 0.0, b.vel.z)
	obj_dir = flat.normalized() if flat.length() > 1e-6 else Vector3.ZERO
	var os := BallMotion.State.new()
	os.pos = b.pos
	os.lin = b.vel
	os.ang = b.ang
	obj_path.append(os.pos)
	_march(os, hit_ball.motion if hit_ball.motion != null else _cue.motion, hit_ball.radius, obj_path, _t_scratch, 0.0, OBJ_MAX_M, hit_ball)
	s.lin = a.vel
	s.ang = a.ang
	after.append(s.pos)
	_march(s, _cue.motion, _r, after, _t_scratch, hit_time, LEG2_MAX_M, hit_ball)


## The cue ball leaves cushion `i`: normal speed x e(approach), tangent through Coulomb friction at the contact point (it turns
## side spin into a changed angle). Ball._rail_rebound does the same to Jolt's e0 bounce; the vertical speed is left alone because
## the host undoes whatever a wall contact does to it.
func _bounce(s: BallMotion.State, i: int) -> void:
	var spec := _cue.spec
	var n := _rail_n[i]
	var v := Vector3(s.lin.x, 0.0, s.lin.z)
	var vin := -v.dot(n)
	after.append(s.pos)
	if vin <= 0.05:
		return
	var e := spec.cushion_restitution_at(vin)
	if _sim != null:
		e = minf(e * _sim.rail_restitution_mult(_rail_ids[i]), 1.0)
	var vt := v + n * vin
	var rc := -n * _r
	var u := vt + s.ang.cross(rc)
	u.y = 0.0
	var ul := u.length()
	var j := Vector3.ZERO
	if ul > 1e-6:
		j = -u / ul * minf(spec.cushion_friction * vin * (1.0 + spec.cushion_restitution), ul / 3.5)
	var nv := vt + j + n * (e * vin)
	s.lin = Vector3(nv.x, s.lin.y, nv.z)
	s.ang += rc.cross(j) / (0.4 * _r * _r)
