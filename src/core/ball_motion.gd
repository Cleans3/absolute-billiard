class_name BallMotion
extends RefCounted

## Pure closed-form ball motion between contacts (04 §2.4), shared by host prediction and client
## reconstruction. Mirrors `Ball._integrate_forces`: Coulomb sliding until the contact point stops
## slipping, then rolling with constant rolling-resistance decel, spin about the table normal
## decaying exponentially, ballistic flight when airborne. Every discontinuity (cushion, ball,
## jaw, landing) is NOT modelled — the host transmits those as events.

const SLIP_EPS := 0.005  # m/s of contact-point slip below which the ball counts as rolling
const AIRBORNE_EPS := 0.003  # m above rest_y before a ball counts as airborne (S3); below = micro-hop noise
const AIR_TOL := AIRBORNE_EPS  # m above floor_y (and vy above AIR_VY) before a ball counts as airborne; below = micro-hop noise
const AIR_VY := 0.25
const TICK_DT := 1.0 / 120.0  # PhysicsSim.LIVE_TICK: the step Jolt flies a ball with (see `_fly`)
## The cloth under a ball that comes down on it (a jump shot's stroke, every landing): `e` of the downward speed comes back up, nothing
## below MIN_HOP_VY (a rebound that small is a settle), nothing past JUMP_VY_MAX off a stroke. Jolt's own cloth is dead (TableSpec.BASE_BOUNCE).
const JUMP_E := 0.45
const LAND_E := 0.4
const MIN_HOP_VY := 0.30  # above AIR_VY: a rebound is always in the air
const JUMP_VY_MAX := 3.0
const DAMP_EPS := 1e-6  # below this the rolling closed form divides by ~0: use the damp-free one
const MAX_PHASES := 600
const SETTLE_SLIP := 0.05  # m/s of contact-point slip at which the settle drag is gone (a sliding ball is driven by cloth friction, not the nap)
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
	var settle_speed := 0.3  # m/s: below it a rolling ball's drag ramps up (see settle_factor)
	var settle_boost := 0.0
	var spin_stop := 0.0  # rad/s²: constant loss of spin about the table normal, on top of the exponential
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
	p.settle_speed = spec.settle_speed_mps
	p.settle_boost = spec.settle_boost
	p.spin_stop = spec.spin_stop_rad_s2
	p.damp = (spec.ball_linear_damp + 0.4 * p.ang_damp) / 1.4


## Ball-centre height of a ball resting in a pocket cup (06 P30): the floor sits `cup_depth_m` under the cloth.
static func cup_floor_y(spec: TableSpec, radius: float) -> float:
	return spec.bed_height_m - spec.cup_depth_m + radius


## S3 airborne rule (adhoc-1014a): a ball is airborne when its centre is more than AIRBORNE_EPS over `rest_y`. While it is, no cloth friction,
## spin decay, water/sand term or tilt force acts on it, and pins and rails collide only if its centre is below their top.
static func is_airborne(y: float, rest_y: float) -> bool:
	return y > rest_y + AIRBORNE_EPS


static func advance(s: State, dt: float, p: Params) -> void:
	var t := dt
	var phases := 0
	while t > 0.0 and phases < MAX_PHASES:
		phases += 1
		if s.pos.y < p.floor_y - AIR_TOL and p.cup_floor_y > -INF:
			t = _drop(s, t, p)  # under the cloth plane = over a hole: falling to the cup floor, which stops it
		elif s.pos.y > p.floor_y + AIR_TOL or absf(s.lin.y) > AIR_VY:  # up off the cloth, or still coming down on it (a touch-down lands inside the tolerance band)
			t = _fly(s, t, p)
		elif p.tilt == Vector2.ZERO:
			t = _ground(s, t, p)
		else:  # tilt is folded in per short step: first-order, like the slide drag
			var step := minf(t, SLIDE_STEP)
			t -= step - _ground(s, step, p)
	if s.lin.length() < p.rest_speed and s.ang.length() < p.rest_ang and not is_airborne(s.pos.y, p.floor_y):  # the top of a hop is not a rest
		s.lin = Vector3.ZERO
		s.ang = Vector3.ZERO


## Drag multiplier on a rolling ball: 1 from `settle_speed` up, (1 + boost) at standstill, linear between (Ball applies the
## same, scaling the boost by how little the ball slips).
static func settle_factor(speed: float, settle_speed: float, boost: float) -> float:
	if boost <= 0.0 or settle_speed <= 0.0:
		return 1.0
	return 1.0 + boost * clampf(1.0 - speed / settle_speed, 0.0, 1.0)


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


## A ball meeting the cloth plane (`p.floor_y`) with `s.lin.y < 0`: Coulomb friction at the contact point works on the slip for as long as the
## impact lasts (impulse μ·|vy|, or what stops the slip: u/3.5 for a solid sphere), and `e` of the downward speed comes back up (nothing below
## MIN_HOP_VY, nothing past `vy_max`). A jump shot's stroke (the cue drives the ball into the cloth) and every landing are this one function,
## which is also the one the host fires (`Ball.strike`, `Ball._air_step`), so Jolt and the model agree on both.
static func cloth_impact(s: State, p: Params, e: float, vy_max := INF) -> void:
	var down := -s.lin.y
	if down <= 0.0:
		return
	var rc := Vector3(0.0, -p.radius, 0.0)
	var u := s.lin + s.ang.cross(rc)
	u.y = 0.0
	var ul := u.length()
	if ul > 1e-6:
		var mu := p.slide_mu * p.friction_mult
		var j := -u / ul * minf(mu * down, ul / 3.5)
		s.lin += j
		s.ang += rc.cross(j) / (0.4 * p.radius * p.radius)
	var up := minf(e * down, vy_max)
	s.lin.y = up if up >= MIN_HOP_VY else 0.0


## Seconds until a ball in flight reaches the cloth plane (0 if it is not above it).
static func time_to_land(s: State, p: Params) -> float:
	var vy := s.lin.y - 0.5 * p.gravity * TICK_DT
	return (vy + sqrt(vy * vy + 2.0 * p.gravity * maxf(s.pos.y - p.floor_y, 0.0))) / p.gravity


## Ballistic; returns the time left after landing (0 if still in the air). Over the cloth (`floor_y` unset) the touch-down is a `cloth_impact`
## (friction, then the bounce, which `advance` flies on as the next phase). `lin.y` is the velocity Jolt reports, and Jolt integrates the
## velocity before the position (v += a·dt, x += v·dt), which flies the true parabola of `lin.y − g·dt/2`: that is the one drawn here, so a
## hop is the host's to the millimetre and not 2 cm low after half a second.
static func _fly(s: State, t: float, p: Params, floor_y := NAN) -> float:
	var g := p.gravity
	var cloth := is_nan(floor_y)
	var floor_at := p.floor_y if cloth else floor_y
	var shift := 0.5 * g * TICK_DT if cloth else 0.0
	var h := s.pos.y - floor_at
	var vy := s.lin.y - shift
	var t_land := (vy + sqrt(vy * vy + 2.0 * g * maxf(h, 0.0))) / g
	var step := minf(t, t_land)
	s.pos += Vector3(s.lin.x * step, vy * step - 0.5 * g * step * step, s.lin.z * step)
	s.lin.y = vy - g * step + shift
	if t_land > t:
		return 0.0
	s.pos.y = floor_at
	if cloth:
		s.lin.y = vy - g * t_land  # the speed it meets the cloth with
		cloth_impact(s, p, LAND_E)
		if s.lin.y > 0.0:
			s.lin.y += shift
	else:
		s.lin.y = 0.0
	return t - t_land


## On the cloth: slide until slip stops, then roll to a stop. Returns leftover time.
static func _ground(s: State, t: float, p: Params) -> float:
	var g := p.gravity
	var r := p.radius
	var a_roll := g * p.roll_mu * p.friction_mult
	# spin about the normal: exponential (Ball: -spin·m·r·μ·decay / I) plus the constant pivot loss
	var k := p.roll_mu * p.friction_mult * p.spin_decay / (0.4 * r) + p.ang_damp
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
		s.ang.y = _spin(s.ang.y, t1, k, p.spin_stop)
		return t - t1
	# rolling: constant drag a (+ viscous damp), ramping up below settle_speed; closed form per stretch
	var t_used := 0.0
	if speed > 0.0:
		var dx := vx / speed
		var dz := vz / speed
		var run := _roll(speed, t, a_roll, p)
		s.pos += Vector3(dx * run.x, 0.0, dz * run.x)
		s.lin.x = dx * run.y
		s.lin.z = dz * run.y
		s.ang.x = s.lin.z / r
		s.ang.z = -s.lin.x / r
		t_used = t - run.z
	if p.tilt != Vector2.ZERO and speed > 0.0:  # host applies tilt to moving balls only
		s.pos += Vector3(0.5 * p.tilt.x * t_used * t_used, 0.0, 0.5 * p.tilt.y * t_used * t_used)
		s.lin.x += p.tilt.x * t_used
		s.lin.z += p.tilt.y * t_used
		s.ang.x = s.lin.z / r
		s.ang.z = -s.lin.x / r
	s.ang.y = _spin(s.ang.y, t, k, p.spin_stop)
	return 0.0


## Spin about the table normal: dw/dt = -k·w - stop·sign(w). Reaches zero and stays there.
static func _spin(w: float, t: float, k: float, stop: float) -> float:
	var a := absf(w)
	if k > DAMP_EPS:
		var q := stop / k
		a = (a + q) * exp(-k * t) - q
	else:
		a -= stop * t
	return signf(w) * maxf(a, 0.0)


## Roll from speed v0 for up to t s. Returns (distance, speed after, time left): drag a, ramping to (1 + boost)·a below settle_speed.
static func _roll(v0: float, t: float, a: float, p: Params) -> Vector3:
	var vc := p.settle_speed if p.settle_boost > 0.0 else 0.0
	var dist := 0.0
	var v := v0
	var left := t
	if v > vc:  # v' = -a - c·v down to vc (or to a stop when the ramp is off)
		var seg := _run(v, vc, left, a, -p.damp)
		dist += seg.x
		v = seg.y
		left = seg.z
	if left > 0.0 and v > 0.0:  # v' = -a·(1 + boost·(1 - v/vc)) - c·v, linear in v
		var seg := _run(v, 0.0, left, a * (1.0 + p.settle_boost), a * p.settle_boost / vc - p.damp)
		dist += seg.x
		v = seg.y
		left = seg.z
	return Vector3(dist, v, left)


## One linear stretch v' = -A + m·v from v0 down to v1 (or for t s, whichever ends first): (distance, speed, time left).
static func _run(v0: float, v1: float, t: float, A: float, m: float) -> Vector3:
	var flat := absf(m) <= DAMP_EPS
	var K := 0.0 if flat else A / m
	var t_to := (v0 - v1) / A if flat else log((v1 - K) / (v0 - K)) / m
	var dt := minf(t, t_to)
	var v: float
	var d: float
	if flat:
		v = v0 - A * dt
		d = v0 * dt - 0.5 * A * dt * dt
	else:
		var e := exp(m * dt)
		v = K + (v0 - K) * e
		d = K * dt + (v0 - K) * (e - 1.0) / m
	if t >= t_to:
		v = v1
	return Vector3(d, maxf(v, 0.0), t - dt)
