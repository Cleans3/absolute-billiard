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
const DROP_TOL := 0.012  # m under the cloth plane before a ball counts as dropping into a hole (a ball creeping for seconds sinks 3 mm into the bed in Jolt)
const DAMP_EPS := 1e-6  # below this the rolling closed form divides by ~0: use the damp-free one
const MAX_PHASES := 600
const ROLL_INERTIA := 1.4  # 1 + I / (m r^2) of a solid sphere
## m/s: a tilt pulls a ball only above it (Ball and this model alike). Below ~0.1 m/s the rolling drag (settle ramp) beats a 4 degree pull, so a
## ball there is slowing down anyway; letting the pull act on it leaves an unstable balance at that speed in which Jolt's slip and the model's
## none disagree by 40 %, and a ball creeping along it for seconds is a divergence event every ~0.1 s (adhoc-1014a G: x2 events per break).
const TILT_MIN_SPEED := 0.12
const SETTLE_SLIP := 0.05  # m/s of contact-point slip at which the settle drag is gone (a sliding ball is driven by cloth friction, not the nap)
const SLIDE_STEP := 1.0 / 60.0  # slide drag is first-order per step; short steps keep long dt honest
const TILT_STEP := 1.0 / 120.0  # the tilt is folded in per step too: the host's own tick (PhysicsSim.LIVE_TICK), so its per-tick prediction and a client's long advance() integrate alike


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
	var hazard: HazardModel  # Pinball pins / Vacation shoreline (PhysicsSim.set_hazard); null = a plain table. Sunken Ship is `tilt` alone.


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


static func advance(s: State, dt: float, p: Params) -> void:
	var t := dt
	var phases := 0
	while t > 0.0 and phases < MAX_PHASES:
		phases += 1
		if s.pos.y < p.floor_y - DROP_TOL and p.cup_floor_y > -INF:
			t = _drop(s, t, p)  # under the cloth plane = over a hole: falling to the cup floor, which stops it
		elif s.pos.y > p.floor_y + AIR_TOL or s.lin.y > AIR_VY:
			t = _fly(s, t, p)
		elif p.hazard != null:
			if _rested(s, p):
				break
			t = _ground_hz(s, t, p)
		elif p.tilt == Vector2.ZERO:
			t = _ground(s, t, p)
		else:  # tilt is folded in per short step: first-order, like the slide drag
			if _rested(s, p):
				break
			var step := minf(t, TILT_STEP)
			t -= step - _ground(s, step, p)
	if s.lin.length() < p.rest_speed and s.ang.length() < p.rest_ang:
		s.lin = Vector3.ZERO
		s.ang = Vector3.ZERO


## The host rests a ball below `rest_speed` / `rest_ang` at the top of a tick, before any force, so a tilt never moves it again (a ball
## a tilted table's drag and pull have just stopped stays stopped, not creeping on downhill). The model checks it per step, not only at
## the end of `advance`, wherever a tilt could otherwise carry on.
static func _rested(s: State, p: Params) -> bool:
	return s.lin.length_squared() < p.rest_speed * p.rest_speed and s.ang.length_squared() < p.rest_ang * p.rest_ang


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


## On the cloth: slide until slip stops, then roll to a stop. Returns leftover time. `zone` scales the rolling drag only (Vacation's
## water / sand, `HazardModel.zone_mult`): the Coulomb slide below is the bed's material and stays global.
static func _ground(s: State, t: float, p: Params, zone := 1.0) -> float:
	var g := p.gravity
	var r := p.radius
	var a_roll := g * p.roll_mu * p.friction_mult * zone
	# spin about the normal: exponential (Ball: -spin·m·r·μ·decay / I) plus the constant pivot loss
	var k := p.roll_mu * p.friction_mult * zone * p.spin_decay / (0.4 * r) + p.ang_damp
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
		var tilt := p.tilt if speed >= TILT_MIN_SPEED else Vector2.ZERO
		var ax := -mu * uhx - a_roll * dhx - p.damp * vx + tilt.x
		var az := -mu * uhz - a_roll * dhz - p.damp * vz + tilt.y
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
	if p.tilt != Vector2.ZERO and speed >= TILT_MIN_SPEED:  # host applies tilt to balls above TILT_MIN_SPEED only
		# a pull on the centre of a ball that rolls without slipping also has to spin it up: it accelerates at 1 / (1 + 2/5) of the pull
		# (the drag's own torque is matched in Ball, the tilt's is not; adhoc-1014a G: the model used the whole pull and ran away from Jolt at 4 degrees)
		var pull := p.tilt / ROLL_INERTIA
		s.pos += Vector3(0.5 * pull.x * t_used * t_used, 0.0, 0.5 * pull.y * t_used * t_used)
		s.lin.x += pull.x * t_used
		s.lin.z += pull.y * t_used
		s.ang.x = s.lin.z / r
		s.ang.z = -s.lin.x / r
	s.ang.y = _spin(s.ang.y, t, k, p.spin_stop)
	return 0.0


const HZ_SLACK_M := 0.002  # a ground stretch is straight to within this (a slide's curve, a step's tilt)
static var _trial := State.new()  # advance() is single-threaded and never re-entered


## `_ground` on a table with pins or a shoreline (`p.hazard`). Far from both it is the plain closed form; within reach of one the
## stretch is cut to SLIDE_STEP and tried first: if its straight path meets the shoreline the ball is advanced to the crossing (the
## next stretch then reads the other zone), if it meets a pin the ball is advanced to the contact and bounced (HazardModel.bounce).
## Returns leftover time. Airborne balls never get here (`advance` sends them to `_fly`: a hop clears the pins).
static func _ground_hz(s: State, t: float, p: Params) -> float:
	var h := p.hazard
	var step := t if p.tilt == Vector2.ZERO else minf(t, TILT_STEP)
	var zone := h.zone_mult(s.pos, s.lin.x, s.lin.z)
	var v := Vector2(s.lin.x, s.lin.z)
	var speed := v.length()
	if speed < 1e-6:
		return t - step + _ground(s, step, p, zone)  # still: nothing to meet (a slip that sets it off is the next stretch's)
	var lateral := 0.5 * p.tilt.length() * step * step + HZ_SLACK_M
	if h.clear(s.pos, v / speed, speed * step + lateral, lateral, p.radius):
		return t - step + _ground(s, step, p, zone)
	step = minf(step, SLIDE_STEP)
	_trial.copy_from(s)
	var used := step - _ground(_trial, step, p, zone)
	var hit := h.first_event(s.pos, _trial.pos, p.radius)
	if hit.x < 0.0:
		s.copy_from(_trial)
		return t - used
	var tt := used * hit.x
	_ground(s, tt, p, zone)
	var n := Vector2(hit.y, hit.z)
	if hit.w == 0.0:  # the shoreline: put the ball exactly on it
		var d := h.shore_n.dot(Vector2(s.pos.x, s.pos.z)) - h.shore_c
		s.pos.x -= n.x * d
		s.pos.z -= n.y * d
	else:  # a pin: on its surface, then the bounce
		var at := h.pins[int(hit.w) - 1]
		var reach := h.pin_r + p.radius + 1e-6
		s.pos.x = at.x + n.x * reach
		s.pos.z = at.y + n.y * reach
		var out := HazardModel.bounce(s.lin, s.ang, n)
		s.lin = out[0]
		s.ang = out[1]
	return t - tt


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
