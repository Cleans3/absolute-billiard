class_name BallMotion
extends RefCounted

## Pure closed-form ball motion between contacts (04 §2.4), shared by host prediction and client
## reconstruction. Mirrors `Ball._integrate_forces`: Coulomb sliding until the contact point stops
## slipping, then rolling with constant rolling-resistance decel, spin about the table normal
## decaying exponentially, ballistic flight when airborne. Every discontinuity (cushion, ball,
## jaw, landing) is NOT modelled — the host transmits those as events.

const SLIP_EPS := 0.005  # m/s of contact-point slip below which the ball counts as rolling
const AIR_TOL := 0.003  # m above floor_y (and vy above AIR_VY) before a ball counts as airborne; below = micro-hop noise
const AIR_VY := 0.25
const DAMP_EPS := 1e-6  # below this the rolling closed form divides by ~0: use the damp-free one
const MAX_PHASES := 600
const SLIDE_STEP := 1.0 / 60.0  # slide drag is first-order per step; short steps keep long dt honest


class State extends RefCounted:
	var pos := Vector3.ZERO
	var lin := Vector3.ZERO
	var ang := Vector3.ZERO

	func copy_from(o: State) -> void:
		pos = o.pos
		lin = o.lin
		ang = o.ang


## Per-ball constants, built once from the TableSpec + ball radius; `friction_mult` follows the
## host's `cloth_friction_mult` stat.
class Params extends RefCounted:
	var radius := 0.05715
	var floor_y := 0.0  # ball-centre height when resting on the cloth
	var cup_floor_y := -INF  # ball-centre height when resting on a pocket cup's floor; below the cloth plane a ball is dropping
	var gravity := 9.8
	var roll_mu := 0.035
	var slide_mu := 0.2
	var spin_decay := 0.55
	var rest_speed := 0.02
	var rest_ang := 0.15  # rad/s
	var damp := 0.1  # 1/s: rolling ball's effective (lin + 0.4·ang) / 1.4 Jolt damping
	var ang_damp := 0.1
	var friction_mult := 1.0
	var tilt := Vector2.ZERO  # m/s² along the table plane (x, z) on moving balls; = g·sin(table_tilt_deg)·dir


static func make_params(spec: TableSpec, radius: float) -> Params:
	var p := Params.new()
	p.radius = radius
	p.floor_y = spec.bed_height_m + radius
	p.cup_floor_y = cup_floor_y(spec, radius)
	p.gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	apply_spec(p, spec)
	return p


## The feel numbers of `spec` into `p` (everything TableSpec.LIVE_FIELDS changes that the model reads).
static func apply_spec(p: Params, spec: TableSpec) -> void:
	p.roll_mu = spec.rolling_resistance
	p.slide_mu = spec.cloth_friction
	p.spin_decay = spec.spin_decay
	p.rest_speed = spec.rest_speed_mps
	p.rest_ang = spec.rest_ang_rad_s
	p.ang_damp = spec.ball_angular_damp
	p.damp = (spec.ball_linear_damp + 0.4 * p.ang_damp) / 1.4


## Ball-centre height of a ball resting in a pocket cup (06 P30): the floor sits `cup_depth_m` under the cloth.
static func cup_floor_y(spec: TableSpec, radius: float) -> float:
	return spec.bed_height_m - spec.cup_depth_m + radius


static func advance(s: State, dt: float, p: Params) -> void:
	var t := dt
	var phases := 0
	while t > 0.0 and phases < MAX_PHASES:
		phases += 1
		if s.pos.y < p.floor_y - AIR_TOL and p.cup_floor_y > -INF:
			t = _drop(s, t, p)  # under the cloth plane = over a hole: falling to the cup floor, which stops it
		elif s.pos.y > p.floor_y + AIR_TOL or s.lin.y > AIR_VY:
			t = _fly(s, t, p)
		elif p.tilt == Vector2.ZERO:
			t = _ground(s, t, p)
		else:  # tilt is folded in per short step: first-order, like the slide drag
			var step := minf(t, SLIDE_STEP)
			t -= step - _ground(s, step, p)
	if s.lin.length() < p.rest_speed and s.ang.length() < p.rest_ang:
		s.lin = Vector3.ZERO
		s.ang = Vector3.ZERO


static func is_at_rest(s: State) -> bool:
	return s.lin == Vector3.ZERO and s.ang == Vector3.ZERO


## Falling into a pocket cup: ballistic down to `cup_floor_y`, where the felt-lined cup stops it dead (the host
## sends the real bounce/roll as events). Returns the time left after landing.
static func _drop(s: State, t: float, p: Params) -> float:
	var left := _fly(s, t, p, p.cup_floor_y)
	if left > 0.0 or s.pos.y <= p.cup_floor_y + AIR_TOL:
		s.lin = Vector3.ZERO
		s.ang = Vector3.ZERO
		s.pos.y = maxf(s.pos.y, p.cup_floor_y)
		return 0.0
	return left


## Ballistic; returns the time left after landing (0 if still in the air).
static func _fly(s: State, t: float, p: Params, floor_y := NAN) -> float:
	var g := p.gravity
	var floor_at := p.floor_y if is_nan(floor_y) else floor_y
	var h := s.pos.y - floor_at
	var vy := s.lin.y
	var t_land := (vy + sqrt(vy * vy + 2.0 * g * maxf(h, 0.0))) / g
	var step := minf(t, t_land)
	s.pos += Vector3(s.lin.x * step, vy * step - 0.5 * g * step * step, s.lin.z * step)
	s.lin.y = vy - g * step
	if t_land > t:
		return 0.0
	s.pos.y = floor_at
	s.lin.y = 0.0
	return t - t_land


## On the cloth: slide until slip stops, then roll to a stop. Returns leftover time.
static func _ground(s: State, t: float, p: Params) -> float:
	var g := p.gravity
	var r := p.radius
	var a_roll := g * p.roll_mu * p.friction_mult
	# spin about the normal bleeds off exponentially (Ball: -spin·m·r·μ·decay / I)
	var k := p.roll_mu * p.friction_mult * p.spin_decay / (0.4 * r) + p.ang_damp
	var decay := exp(-k * t)
	var vx := s.lin.x
	var vz := s.lin.z
	var ux := vx + r * s.ang.z
	var uz := vz - r * s.ang.x
	var slip := sqrt(ux * ux + uz * uz)
	var speed := sqrt(vx * vx + vz * vz)
	if slip > SLIP_EPS:
		var mu := p.slide_mu * p.friction_mult * g
		var t1 := minf(minf(t, slip / (3.5 * mu)), SLIDE_STEP)
		var uhx := ux / slip
		var uhz := uz / slip
		var dhx := vx / speed if speed > 0.001 else 0.0
		var dhz := vz / speed if speed > 0.001 else 0.0
		var ax := -mu * uhx - a_roll * dhx - p.damp * vx + p.tilt.x
		var az := -mu * uhz - a_roll * dhz - p.damp * vz + p.tilt.y
		s.pos += Vector3(vx * t1 + 0.5 * ax * t1 * t1, 0.0, vz * t1 + 0.5 * az * t1 * t1)
		s.lin.x = vx + ax * t1
		s.lin.z = vz + az * t1
		var alx := 2.5 * mu * uhz / r - dhz * a_roll / r
		var alz := -2.5 * mu * uhx / r + dhx * a_roll / r
		s.ang.x += alx * t1
		s.ang.z += alz * t1
		s.ang.y *= exp(-k * t1)
		return t - t1
	# rolling: v' = -a - c·v  =>  v(t) = (v0 + a/c)·e^-ct - a/c   (c = 0: v(t) = v0 - a·t)
	var c := p.damp
	var t_stop := 0.0
	if speed > 0.0:
		t_stop = log(1.0 + c * speed / a_roll) / c if c > DAMP_EPS else speed / a_roll
	var t2 := minf(t, t_stop)
	if speed > 0.0:
		var dx := vx / speed
		var dz := vz / speed
		var dist: float
		var sp: float
		if c > DAMP_EPS:
			var q := a_roll / c
			var e := exp(-c * t2)
			dist = (speed + q) * (1.0 - e) / c - q * t2
			sp = maxf((speed + q) * e - q, 0.0)
		else:
			dist = speed * t2 - 0.5 * a_roll * t2 * t2
			sp = maxf(speed - a_roll * t2, 0.0)
		s.pos += Vector3(dx * dist, 0.0, dz * dist)
		s.lin.x = dx * sp
		s.lin.z = dz * sp
		s.ang.x = s.lin.z / r
		s.ang.z = -s.lin.x / r
	if p.tilt != Vector2.ZERO and speed > 0.0:  # host applies tilt to moving balls only
		var tt := t2
		s.pos += Vector3(0.5 * p.tilt.x * tt * tt, 0.0, 0.5 * p.tilt.y * tt * tt)
		s.lin.x += p.tilt.x * tt
		s.lin.z += p.tilt.y * tt
		s.ang.x = s.lin.z / r
		s.ang.z = -s.lin.x / r
	s.ang.y *= decay
	return 0.0
