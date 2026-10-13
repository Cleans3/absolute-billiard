class_name HazardModel
extends RefCounted

## The geometry of one live hazard (docs/plan/03 §3.9, 01 "Hazard models"): Sunken Ship (a tilt toward one corner pocket),
## Vacation (the cloth split into water and sand along a shoreline), Pinball (4 pins). Pure data and maths, no nodes: the
## host's `Ball._integrate_forces` and the client's `BallMotion` read the SAME object, so what Jolt does and what a client
## reconstructs agree. Every number rides the `apply_event` payload as `params` (ints, mm): the host rolls them once
## (`roll`), every peer builds the model from them (`from_params`), so nothing here is random on a client.
##
## World space (BallMotion works in it): `xf` is the Table's global transform at the time the Event applies.

const SUNKEN_SHIP := &"sunken_ship"
const VACATION := &"vacation"
const PINBALL := &"pinball"

# --- Pinball. Sizes are ball radii, so they follow TableSpec.scale.
const PIN_COUNT := 4
const PIN_R_RADII := 0.9           ## pin radius
const PIN_H_RADII := 2.0           ## pin height above the cloth: the ball centre (1 radius) is below its top, a jump arc clears it
const PIN_GAP_RADII := 12.0        ## centre to centre, pin to pin: a corridor of 4+ ball diameters stays open between any two
const PIN_EDGE_RADII := 7.0        ## pin centre to a nose line
const PIN_HEAD_RADII := 10.0       ## clear disc round the head spot (the cue ball's)
const PIN_RACK_RADII := 10.0       ## ... round the foot spot (the rack's)
const PIN_AVOID_RADII := 8.0       ## ... round each ball of an authored rack
const PIN_POCKET_RADII := 8.0      ## past 1.5 x the hole's cup circle (so a later pocket_radius_mult still clears)
const PIN_KEEP_RADII := 2.5        ## racks and respawns keep a ball centre this far past the pin's axis
const PIN_STICK_MPS := 0.2         ## Jolt's bounce_velocity_threshold (project.godot): a slower approach does not bounce
const PIN_ELASTIC_HITS := 8        ## per ball per shot; past it a pin is a plain obstacle (PIN_CAP_E) ...
const PIN_CAP_E := 0.9             ## ... and the shot ceiling (RoundDirector) stills what is left

# --- Vacation: the cloth's rolling drag, by side of the shoreline. The ball-cloth Coulomb slide is the bed's and stays global.
const WATER_MULT := 0.3
const SAND_MULT := 2.2
const SHORE_EPS := 1e-9

var kind: StringName
var params := PackedInt32Array()
var xf := Transform3D.IDENTITY
var ball_r := 0.0
var cloth_y := 0.0                  ## table-local height of the cloth

# sunken_ship
var corner := &""
var corner_local := Vector2.ZERO    ## the pocket's centre, table-local xz (read from the layout, never hardcoded)
var tilt_dir := Vector2.ZERO        ## world xz unit vector from the table centre to that pocket

# vacation (world space)
var shore_n := Vector2.ZERO         ## unit normal of the shoreline
var shore_c := 0.0                  ## n . p of the line
var water_sign := 1.0               ## the side of the line (sign of n . p - c) that is water
var shore_local_z := 0.0

# pinball (world space xz centres; `pins_local` are the table-local mm-snapped values that travelled)
var pins := PackedVector2Array()
var pins_local := PackedVector2Array()
var pin_r := 0.0
var pin_top_y := -INF               ## world y of the pin tops


## True when BallMotion has anything to do for this hazard (a tilt alone is the old `Params.tilt`).
func active() -> bool:
	return not pins.is_empty() or shore_n != Vector2.ZERO


# ---------------------------------------------------------------- roll (host) and build (every peer)

## The corner pockets of `layout`, layout order (nw, ne, sw, se).
static func corners(layout: TableLayout) -> Array[PocketSpec]:
	var out: Array[PocketSpec] = []
	for p in layout.pockets:
		if String(p.id).begins_with("corner_"):
			out.append(p)
	return out


## Host: the ints that define this Round's `kind`, a pure function of `seed` (hash of campaign seed, Night, Round), the layout
## and `avoid` (table-local balls of an authored rack the pins must stay clear of).
static func roll(kind_id: StringName, seed: int, spec: TableSpec, layout: TableLayout, avoid := PackedVector2Array()) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	match kind_id:
		SUNKEN_SHIP:
			return PackedInt32Array([rng.randi() % corners(layout).size()])
		VACATION:
			var lim := int(spec.width_m * 120.0)  # the shoreline wanders +-12 % of the width about the long axis
			return PackedInt32Array([rng.randi_range(-lim, lim), 1 if rng.randi() % 2 == 0 else -1])
		PINBALL:
			return _roll_pins(rng, spec, layout, avoid)
	return PackedInt32Array()


static func _roll_pins(rng: RandomNumberGenerator, spec: TableSpec, layout: TableLayout, avoid: PackedVector2Array) -> PackedInt32Array:
	var r := spec.ball_radius_m
	var hx := spec.length_m * 0.5 - PIN_EDGE_RADII * r
	var hz := spec.width_m * 0.5 - PIN_EDGE_RADII * r
	var blocked: Array[Vector3] = []
	for p in layout.pockets:
		blocked.append(Vector3(p.position.x, p.position.z, layout.holes[p.id].cup_radius * 1.5 + PIN_POCKET_RADII * r))
	blocked.append(Vector3(layout.spots.head.x, layout.spots.head.z, PIN_HEAD_RADII * r))
	blocked.append(Vector3(layout.spots.foot.x, layout.spots.foot.z, PIN_RACK_RADII * r))
	for a in avoid:
		blocked.append(Vector3(a.x, a.y, PIN_AVOID_RADII * r))
	var gap := PIN_GAP_RADII * r
	var pts: Array[Vector2] = []
	var tries := 0
	while pts.size() < PIN_COUNT:
		tries += 1
		if tries % 400 == 0:
			gap *= 0.9  # a crowded table (a spread authored rack): relax the spacing, never the keepouts
		var c := Vector2(snappedf(rng.randf_range(-hx, hx), 0.001), snappedf(rng.randf_range(-hz, hz), 0.001))
		var ok := true
		for b in blocked:
			if c.distance_squared_to(Vector2(b.x, b.y)) < b.z * b.z:
				ok = false
				break
		for q in pts:
			if ok and c.distance_squared_to(q) < gap * gap:
				ok = false
		if ok:
			pts.append(c)
		assert(tries < 100000, "HazardModel: no room for %d pins" % PIN_COUNT)
		if tries >= 100000:
			break
	var out := PackedInt32Array()
	for q in pts:
		out.append(roundi(q.x * 1000.0))
		out.append(roundi(q.y * 1000.0))
	return out


## Every peer, from the payload. Null for a kind with no geometry, or for params that do not fit it.
static func from_params(kind_id: StringName, p: PackedInt32Array, spec: TableSpec, layout: TableLayout, xform: Transform3D) -> HazardModel:
	var h := HazardModel.new()
	h.kind = kind_id
	h.params = p
	h.xf = xform
	h.ball_r = spec.ball_radius_m
	h.cloth_y = spec.bed_height_m
	match kind_id:
		SUNKEN_SHIP:
			var cs := corners(layout)
			if p.size() != 1 or p[0] < 0 or p[0] >= cs.size():
				return null
			h.corner = cs[p[0]].id
			h.corner_local = Vector2(cs[p[0]].position.x, cs[p[0]].position.z)
			h.tilt_dir = _xz(xform.basis * Vector3(h.corner_local.x, 0.0, h.corner_local.y)).normalized()
		VACATION:
			if p.size() != 2 or absi(p[1]) != 1:
				return null
			h.shore_local_z = float(p[0]) / 1000.0
			h.shore_n = _xz(xform.basis * Vector3.BACK).normalized()
			h.shore_c = h.shore_n.dot(_xz(xform * Vector3(0.0, 0.0, h.shore_local_z)))
			h.water_sign = float(p[1])
		PINBALL:
			if p.size() != PIN_COUNT * 2:
				return null
			h.pin_r = PIN_R_RADII * h.ball_r
			h.pin_top_y = (xform * Vector3(0.0, h.cloth_y + PIN_H_RADII * h.ball_r, 0.0)).y
			for i in PIN_COUNT:
				var q := Vector2(float(p[i * 2]) / 1000.0, float(p[i * 2 + 1]) / 1000.0)
				h.pins_local.append(q)
				h.pins.append(_xz(xform * Vector3(q.x, h.cloth_y, q.y)))
		_:
			return null
	return h


static func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## What `EffectManager.hazard_state()` returns for this model: plain ints and names, hashable, the same on every peer.
func state() -> Dictionary:
	var d := {"id": String(kind), "params": Array(params)}
	match kind:
		SUNKEN_SHIP:
			d["corner"] = String(corner)
		VACATION:
			d["shore_mm"] = params[0]
			d["water_side"] = params[1]
		PINBALL:
			var pts: Array = []
			for q in pins_local:
				pts.append([roundi(q.x * 1000.0), roundi(q.y * 1000.0)])
			d["pins"] = pts
	return d


## Discs (table-local x, z, radius) a ball centre must stay out of: racks and respawns read them.
func keepouts() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for q in pins_local:
		out.append(Vector3(q.x, q.y, pin_r + PIN_KEEP_RADII * ball_r))
	return out


# ---------------------------------------------------------------- friction by zone

## The multiplier on the cloth's ROLLING drag (and spin decay) at `pos` for a ball moving (vx, vz): 1 off Vacation, water or
## sand by the side of the shoreline. Exactly on the line the side it is moving into counts. The Coulomb slide stays global.
func zone_mult(pos: Vector3, vx: float, vz: float) -> float:
	if shore_n == Vector2.ZERO:
		return 1.0
	var d := shore_n.x * pos.x + shore_n.y * pos.z - shore_c
	if absf(d) < SHORE_EPS:
		d = shore_n.x * vx + shore_n.y * vz
	return WATER_MULT if d * water_sign > 0.0 else SAND_MULT


# ---------------------------------------------------------------- the stepping queries BallMotion needs

## True when a ball at `pos` moving along unit `dir` for at most `reach` (+ `slack` sideways) can touch no pin and cross no shoreline.
func clear(pos: Vector3, dir: Vector2, reach: float, slack: float, radius: float) -> bool:
	if shore_n != Vector2.ZERO:
		var d := shore_n.x * pos.x + shore_n.y * pos.z - shore_c
		if absf(d) <= absf(shore_n.dot(dir)) * reach + slack:
			return false
	if pos.y < pin_top_y:
		var p := Vector2(pos.x, pos.z)
		var seg := dir * reach
		var rr := pin_r + radius + slack
		for q in pins:
			var t := 0.0
			var len2 := seg.length_squared()
			if len2 > 0.0:
				t = clampf((q - p).dot(seg) / len2, 0.0, 1.0)
			if (p + seg * t).distance_squared_to(q) <= rr * rr:
				return false
	return true


## First thing the straight segment p0 -> p1 meets: Vector4(f, nx, nz, what), f in [0, 1] along it, what 0 = the shoreline
## (n = its normal), 1 + i = pin i (n = outward, pin -> ball). f < 0: nothing. A ball already on a surface and leaving it meets nothing.
func first_event(p0: Vector3, p1: Vector3, radius: float) -> Vector4:
	var best := Vector4(-1.0, 0.0, 0.0, 0.0)
	if shore_n != Vector2.ZERO:
		var d0 := shore_n.x * p0.x + shore_n.y * p0.z - shore_c
		var d1 := shore_n.x * p1.x + shore_n.y * p1.z - shore_c
		if absf(d0) >= SHORE_EPS and d0 * d1 < 0.0:
			best = Vector4(d0 / (d0 - d1), shore_n.x, shore_n.y, 0.0)
	if p0.y < pin_top_y:
		var a := Vector2(p0.x, p0.z)
		var d := Vector2(p1.x - p0.x, p1.z - p0.z)
		var aa := d.dot(d)
		if aa > 1e-18:
			var rr := pin_r + radius
			for i in pins.size():
				var q := pins[i]
				var m := a - q
				var b := m.dot(d)
				var c := m.dot(m) - rr * rr
				if c < -1e-6 or (b >= 0.0 and c > -1e-6):
					continue  # inside already (Jolt's business), or on the surface and leaving it
				var disc := b * b - aa * c
				if disc < 0.0:
					continue
				var f := maxf((-b - sqrt(disc)) / aa, 0.0)
				if f > 1.0 or (best.x >= 0.0 and f >= best.x):
					continue
				var hit := a + d * f - q
				best = Vector4(f, hit.x / rr, hit.y / rr, 1.0 + i)
	return best


## The pin's answer to a ball with outward normal `n` (xz): e = 1 for the normal velocity, the ball keeps rolling (its horizontal
## spin is mirrored with the velocity, so it does not skid and lose 57 % of its speed on a head-on hit), spin about the vertical
## is untouched. A slower approach than PIN_STICK_MPS does not bounce (Jolt's threshold): the normal velocity is lost, nothing else.
## Host (Ball._pin_rebound) and client (BallMotion) both call this: same numbers.
static func bounce(lin: Vector3, ang: Vector3, n: Vector2) -> Array[Vector3]:
	var vn := lin.x * n.x + lin.z * n.y
	if vn >= 0.0:
		return [lin, ang]
	var out_lin := lin
	if -vn < PIN_STICK_MPS:
		out_lin.x -= vn * n.x
		out_lin.z -= vn * n.y
		return [out_lin, ang]
	out_lin.x -= 2.0 * vn * n.x
	out_lin.z -= 2.0 * vn * n.y
	return [out_lin, mirror_spin(ang, n)]


## The pin's outward normal at the point where a ball whose centre starts at `p` and travels the line `v` first touches the pin at `c`
## (centre distance `big_r`: pin + ball radius). The entry point may lie behind `p` (Jolt found the contact a tick late and the
## ball starts a little inside); ZERO if the line misses the pin or the pin is behind the ball.
static func contact_normal(p: Vector2, v: Vector2, c: Vector2, big_r: float) -> Vector2:
	var aa := v.dot(v)
	if aa < 1e-12:
		return Vector2.ZERO
	var m := p - c
	var b := m.dot(v)
	var disc := b * b - aa * (m.dot(m) - big_r * big_r)
	if disc < 0.0:
		return Vector2.ZERO
	var root := sqrt(disc)
	if (-b + root) / aa < 0.0:
		return Vector2.ZERO
	return (p + v * ((-b - root) / aa) - c).normalized()


## Horizontal spin of a ball whose velocity was mirrored across the plane with normal `n`: -(w - 2 (w.n) n); w.y stays.
static func mirror_spin(ang: Vector3, n: Vector2) -> Vector3:
	var wn := ang.x * n.x + ang.z * n.y
	return Vector3(-(ang.x - 2.0 * wn * n.x), ang.y, -(ang.z - 2.0 * wn * n.y))
