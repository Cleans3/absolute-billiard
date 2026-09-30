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
const REST_ANG := 0.15  # rad/s, same as Ball._integrate_forces
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
	var gravity := 9.8
	var roll_mu := 0.035
	var slide_mu := 0.2
	var spin_decay := 0.55
	var rest_speed := 0.02
	var damp := 0.1  # 1/s: rolling ball's effective (lin + 0.4·ang) / 1.4 Jolt damping
	var ang_damp := 0.1
	var friction_mult := 1.0
	var tilt := Vector2.ZERO  # m/s² along the table plane (x, z) on moving balls; = g·sin(table_tilt_deg)·dir


static func make_params(spec: TableSpec, radius: float) -> Params:
	var p := Params.new()
	p.radius = radius
	p.floor_y = spec.bed_height_m + radius
	p.gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	p.roll_mu = spec.rolling_resistance
	p.slide_mu = spec.cloth_friction
	p.spin_decay = spec.spin_decay
	p.rest_speed = spec.rest_speed_mps
	p.ang_damp = float(ProjectSettings.get_setting("physics/3d/default_angular_damp"))
	p.damp = (float(ProjectSettings.get_setting("physics/3d/default_linear_damp")) + 0.4 * p.ang_damp) / 1.4
	return p


static func advance(s: State, dt: float, p: Params) -> void:
	var t := dt
	var phases := 0
	while t > 0.0 and phases < MAX_PHASES:
		phases += 1
		if s.pos.y > p.floor_y + AIR_TOL or s.lin.y > AIR_VY:
			t = _fly(s, t, p)
		elif p.tilt == Vector2.ZERO:
			t = _ground(s, t, p)
		else:  # tilt is folded in per short step: first-order, like the slide drag
			var step := minf(t, SLIDE_STEP)
			t -= step - _ground(s, step, p)
	if s.lin.length() < p.rest_speed and s.ang.length() < REST_ANG:
		s.lin = Vector3.ZERO
		s.ang = Vector3.ZERO


static func is_at_rest(s: State) -> bool:
	return s.lin == Vector3.ZERO and s.ang == Vector3.ZERO


## Ballistic; returns the time left after landing (0 if still in the air).
static func _fly(s: State, t: float, p: Params) -> float:
	var g := p.gravity
	var h := s.pos.y - p.floor_y
	var vy := s.lin.y
	var t_land := (vy + sqrt(vy * vy + 2.0 * g * maxf(h, 0.0))) / g
	var step := minf(t, t_land)
	s.pos += Vector3(s.lin.x * step, vy * step - 0.5 * g * step * step, s.lin.z * step)
	s.lin.y = vy - g * step
	if t_land > t:
		return 0.0
	s.pos.y = p.floor_y
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
	# rolling: v' = -a - c·v  =>  v(t) = (v0 + a/c)·e^-ct - a/c
	var c := p.damp
	var t_stop := log(1.0 + c * speed / a_roll) / c if speed > 0.0 else 0.0
	var t2 := minf(t, t_stop)
	if speed > 0.0:
		var dx := vx / speed
		var dz := vz / speed
		var q := a_roll / c
		var e := exp(-c * t2)
		var dist := (speed + q) * (1.0 - e) / c - q * t2
		s.pos += Vector3(dx * dist, 0.0, dz * dist)
		var sp := maxf((speed + q) * e - q, 0.0)
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
