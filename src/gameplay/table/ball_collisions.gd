class_name BallCollisions
extends RefCounted

## Ball–ball impacts resolved in time order (01 §4 "Ball–ball contact"). Jolt solves every touching pair of a step as
## one lump: a rack acts as a rigid wall (the cue ball rebounds, the far balls get half) and its restitution bias even
## adds energy. Here impacts come one after the other, so the next pair sees the speed the last one left and Newton's
## cradle comes out of it; impacts inside one contact duration (a ball hitting two at once, the apex of a rack) are
## solved together, so a symmetric hit stays symmetric. Pure data in, velocities out: PhysicsSim feeds it the pre-step
## state of a cluster.

const MAX_EVENTS := 128
const V_MIN := 0.02  # m/s of normal approach below which a touch is not an impact
const TOUCH_EPS := 0.0005  # m of gap at or under which a pair counts as touching
const CONTACT_SEC := 1.0e-4  # impacts closer in time than this are one event (a real ball's contact lasts 0.1-0.3 ms)
const SOLVER_PASSES := 40


class Body extends RefCounted:
	var pos := Vector3.ZERO  # at time `t`
	var vel := Vector3.ZERO
	var ang := Vector3.ZERO
	var mass := 1.0
	var radius := 0.05
	var t := 0.0
	var hit := false  # took part in at least one impact
	var ref: Object  # the caller's handle (its Ball); never touched here

	func at(time: float) -> Vector3:
		return pos + vel * (time - t)

	func advance(time: float) -> void:
		pos = at(time)
		t = time


## Plays `dt` seconds of straight-line motion over `bodies`, applying every ball–ball impact in the order it happens
## (normal restitution `e`, Coulomb friction `mu`, solid-sphere spin). Returns the number of impacts; bodies that took
## part have `hit` set and carry their final `vel` / `ang`.
static func simulate(bodies: Array[Body], dt: float, e: float, mu: float) -> int:
	var n := bodies.size()
	var times := PackedFloat64Array()  # upper triangle: time of the next impact of pair (i < j)
	times.resize(n * n)
	times.fill(INF)
	for i in n:
		for j in range(i + 1, n):
			times[i * n + j] = _next_impact(bodies[i], bodies[j], 0.0, dt)
	var events := 0
	while events < MAX_EVENTS:
		var best := INF
		for k in n * n:
			best = minf(best, times[k])
		if best == INF:
			break
		var pairs: Array[Vector2i] = []  # every pair that touches within one contact duration of the earliest
		var touched := {}
		for k in n * n:
			if times[k] <= best + CONTACT_SEC:
				pairs.append(Vector2i(k / n, k % n))
				touched[k / n] = true
				touched[k % n] = true
		for i: int in touched:
			bodies[i].advance(best)
		var contacts := _contacts(bodies, pairs)
		if contacts.is_empty():
			for pr in pairs:
				times[pr.x * n + pr.y] = INF  # their approach was already spent by an earlier impulse
			continue
		if contacts.size() == 1:
			_impact(bodies[contacts[0].a], bodies[contacts[0].b], e, mu)
		else:
			_solve(bodies, contacts, e, mu)
		for c in contacts:
			bodies[c.a].hit = true
			bodies[c.b].hit = true
		events += contacts.size()
		for i: int in touched:
			for k in n:
				if k != i:
					_refresh(times, bodies, n, i, k, best, dt)
	return events


class Contact extends RefCounted:
	var a := 0
	var b := 0
	var n := Vector3.RIGHT  # a -> b
	var vn0 := 0.0  # normal speed at the start of the event, < 0 approaching
	var p := 0.0  # normal impulse so far


static func _contacts(bodies: Array[Body], pairs: Array[Vector2i]) -> Array[Contact]:
	var out: Array[Contact] = []
	for pr in pairs:
		var a := bodies[pr.x]
		var b := bodies[pr.y]
		var d := b.pos - a.pos
		var dist := d.length()
		if dist <= 0.0:
			continue
		var n := d / dist
		var vn := (b.vel - a.vel).dot(n)
		if vn < -V_MIN:
			var c := Contact.new()
			c.a = pr.x
			c.b = pr.y
			c.n = n
			c.vn0 = vn
			out.append(c)
	return out


## Several impacts at once (they share balls): projected Gauss-Seidel on the normal impulses until every contact leaves
## at e × its approach speed, then friction contact by contact. One contact is `_impact`'s closed form.
static func _solve(bodies: Array[Body], contacts: Array[Contact], e: float, mu: float) -> void:
	for pass_i in SOLVER_PASSES:
		var worst := 0.0
		for c in contacts:
			var a := bodies[c.a]
			var b := bodies[c.b]
			var inv_m := 1.0 / a.mass + 1.0 / b.mass
			var err := -e * c.vn0 - (b.vel - a.vel).dot(c.n)  # > 0: leaving too slowly
			var dp := maxf(c.p + err / inv_m, 0.0) - c.p
			c.p += dp
			a.vel -= c.n * dp / a.mass
			b.vel += c.n * dp / b.mass
			worst = maxf(worst, absf(err))
		if worst < 1.0e-6:
			break
	var imps: Array[Vector3] = []  # all from the same state, applied together: order never favours a contact
	for c in contacts:
		imps.append(_friction_impulse(bodies[c.a], bodies[c.b], c.n, c.p, mu))
	for k in contacts.size():
		_apply_tangent(bodies[contacts[k].a], bodies[contacts[k].b], contacts[k].n, imps[k])


static func _refresh(times: PackedFloat64Array, bodies: Array[Body], n: int, i: int, k: int, now: float, dt: float) -> void:
	var lo := mini(i, k)
	var hi := maxi(i, k)
	times[lo * n + hi] = _next_impact(bodies[lo], bodies[hi], now, dt)


## Absolute time in [now, dt] at which `a` and `b` next touch while closing, else INF.
static func _next_impact(a: Body, b: Body, now: float, dt: float) -> float:
	var d := b.at(now) - a.at(now)
	var u := b.vel - a.vel
	var closing := d.dot(u)
	if closing >= 0.0:
		return INF
	var rr := a.radius + b.radius
	var dist := d.length()
	if dist - rr <= TOUCH_EPS:
		return now if -closing / dist >= V_MIN else INF
	var span := dt - now
	var a2 := u.length_squared()
	if dist - rr > sqrt(a2) * span:
		return INF
	var disc := closing * closing - a2 * (d.length_squared() - rr * rr)
	if disc < 0.0:
		return INF
	var tt := (-closing - sqrt(disc)) / a2
	if tt > span:
		return INF
	var n := (d + u * tt) / rr
	return now + tt if -u.dot(n) >= V_MIN else INF


## One impact at the bodies' current positions: normal impulse from `e`, then friction at the contact point, capped by
## `mu` × the normal impulse (so it grips until the slip stops, then slides). Both bodies are solid spheres.
static func _impact(a: Body, b: Body, e: float, mu: float) -> void:
	var n := (b.pos - a.pos).normalized()
	var vn := (b.vel - a.vel).dot(n)
	if vn >= 0.0:
		return
	var j := -(1.0 + e) * vn / (1.0 / a.mass + 1.0 / b.mass)
	a.vel -= n * j / a.mass
	b.vel += n * j / b.mass
	_friction(a, b, n, j, mu)


## Coulomb friction at the contact point of a pair that exchanged normal impulse `j`, along `n` (a -> b). Moves linear
## velocity and spin: this is where throw and english transfer come from.
static func _friction(a: Body, b: Body, n: Vector3, j: float, mu: float) -> void:
	_apply_tangent(a, b, n, _friction_impulse(a, b, n, j, mu))


## The tangential impulse on `b` (`a` takes the opposite): opposes the slip of the contact points, at most `mu` × `j`.
static func _friction_impulse(a: Body, b: Body, n: Vector3, j: float, mu: float) -> Vector3:
	var slip := (b.vel + b.ang.cross(-n * b.radius)) - (a.vel + a.ang.cross(n * a.radius))
	slip -= n * slip.dot(n)
	var slip_len := slip.length()
	if slip_len < 1e-6 or mu <= 0.0 or j <= 0.0:
		return Vector3.ZERO
	var inv_m := 1.0 / a.mass + 1.0 / b.mass
	return -slip / slip_len * minf(mu * j, slip_len / (3.5 * inv_m))  # 3.5 = 1 + 2.5: 1/m plus r²/I of a solid sphere


static func _apply_tangent(a: Body, b: Body, n: Vector3, imp: Vector3) -> void:
	a.vel -= imp / a.mass
	b.vel += imp / b.mass
	a.ang += (n * a.radius).cross(-imp) / (0.4 * a.mass * a.radius * a.radius)
	b.ang += (-n * b.radius).cross(imp) / (0.4 * b.mass * b.radius * b.radius)
