extends SceneTree

## BallCollisions on plain data (no scene, no Jolt): time-ordered ball–ball impacts (01 §4).
##   godot --path . --headless -s tests/physics/collisions_probe.gd     prints COLLISIONS OK
## Asserts what real balls do and Jolt's lump solve does not: a stun hit hands over e-scaled speed, a frozen line passes
## the speed to its far end (Newton's cradle), a break stops the cue ball and loses no energy, friction throws and spins.

const R := 0.05715
const M := 1.36
const E := 0.95
const MU := 0.06

var _fail := 0


func _init() -> void:
	_two_ball()
	_cradle()
	_break_rack()
	_symmetry()
	_gap_chain()
	_throw_and_spin()
	_grazing_and_apart()
	if _fail > 0:
		printerr("COLLISIONS FAILED: %d" % _fail)
		quit(1)
		return
	print("COLLISIONS OK")
	quit()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("COLLISIONS: " + msg)


func _body(x: float, z := 0.0, vx := 0.0, vz := 0.0) -> BallCollisions.Body:
	var b := BallCollisions.Body.new()
	b.pos = Vector3(x, 0.0, z)
	b.vel = Vector3(vx, 0.0, vz)
	b.mass = M
	b.radius = R
	return b


func _ke(bs: Array[BallCollisions.Body]) -> float:
	var k := 0.0
	for b in bs:
		k += 0.5 * b.mass * b.vel.length_squared()
	return k


func _px(bs: Array[BallCollisions.Body]) -> float:
	var p := 0.0
	for b in bs:
		p += b.mass * b.vel.x
	return p


func _two_ball() -> void:
	var v := 3.0
	var bs: Array[BallCollisions.Body] = [_body(0.0, 0.0, v), _body(2.0 * R + 0.02)]
	var n := BallCollisions.simulate(bs, 1.0 / 120.0, E, MU)
	print("two-ball: impacts %d, cue %.3f, object %.3f (ideal %.3f / %.3f)" % [n, bs[0].vel.x, bs[1].vel.x, v * (1.0 - E) / 2.0, v * (1.0 + E) / 2.0])
	_check(n == 1, "two balls, one impact")
	_check(absf(bs[1].vel.x - v * (1.0 + E) / 2.0) < 1e-4, "object ball takes (1+e)/2 of the speed")
	_check(absf(bs[0].vel.x - v * (1.0 - E) / 2.0) < 1e-4, "cue ball keeps (1-e)/2 of the speed")
	_check(absf(_px(bs) - M * v) < 1e-6, "momentum conserved")


## Three balls touching in a line (1 mm gaps like a rack row), hit by the fourth: the far end leaves, the middle two stay.
func _cradle() -> void:
	var v := 3.0
	var g := 2.0 * R + 0.001
	var bs: Array[BallCollisions.Body] = [_body(-0.02, 0.0, v), _body(g - 0.02 + 0.02), _body(2.0 * g), _body(3.0 * g)]
	bs[1].pos.x = 0.0
	bs[2].pos.x = g
	bs[3].pos.x = 2.0 * g
	var e0 := _ke(bs)
	var n := BallCollisions.simulate(bs, 1.0 / 120.0, E, MU)
	print("cradle: impacts %d, speeds %.3f %.3f %.3f %.3f, KE %.0f%%, momentum %.0f%%" % [n, bs[0].vel.x, bs[1].vel.x, bs[2].vel.x, bs[3].vel.x, 100.0 * _ke(bs) / e0, 100.0 * _px(bs) / (M * v)])
	_check(bs[3].vel.x > 0.85 * v, "far end of a touching line takes ~e² of the speed (got %.2f of %.2f)" % [bs[3].vel.x, v])
	_check(absf(bs[0].vel.x) < 0.1 * v, "cue ball stops (got %.2f)" % bs[0].vel.x)
	_check(_ke(bs) <= e0 + 1e-6, "no energy gained")
	_check(absf(_px(bs) - M * v) < 1e-6, "momentum conserved")
	for k in range(1, 4):
		_check(bs[k].vel.x >= bs[k - 1].vel.x - 0.02 * v or k == 1, "balls leave in order, none passing through another")


## 15-ball triangle, stun break at 6 m/s: the cue ball does not ricochet, energy is conserved down to the e loss.
func _break_rack() -> void:
	var v := 6.0
	var g := 2.0 * R + 0.001
	var bs: Array[BallCollisions.Body] = [_body(-0.1, 0.0, v)]
	for row in 5:
		for k in row + 1:
			bs.append(_body(row * g * 0.866, (k - row * 0.5) * g))
	var e0 := _ke(bs)
	var n := BallCollisions.simulate(bs, 1.0 / 120.0, E, MU)
	var moving := 0
	var top := 0.0
	for k in range(1, bs.size()):
		moving += 1 if bs[k].vel.length() > 0.3 else 0
		top = maxf(top, bs[k].vel.length())
	print("break: impacts %d, cue %.3f, balls moving %d, top %.2f m/s (the two back corners), KE %.0f%%, momentum %.0f%%" % [n, bs[0].vel.x, moving, top, 100.0 * _ke(bs) / e0, 100.0 * _px(bs) / (M * v)])
	_check(n >= 6, "the break reaches the rack (%d impacts)" % n)
	_check(bs[0].vel.x > -0.25 * v, "the cue ball does not bounce back off the rack (%.2f m/s)" % bs[0].vel.x)
	_check(_ke(bs) <= e0 * (1.0 + 1e-9), "no energy gained")
	_check(_ke(bs) > 0.6 * e0, "the rack keeps most of the energy: Jolt's lump solve left 40-50 percent")
	_check(top > 0.4 * v, "the break throws balls out of the rack (%.2f m/s)" % top)


## A symmetric hit stays symmetric whatever order the balls are listed in: the cue ball splits two balls, and the apex of
## a rack feeds the two behind it. Impacts inside one contact duration are one event, not "first A, then B".
func _symmetry() -> void:
	var v := 3.0
	var z := R + 0.002
	var x := sqrt(4.0 * R * R - z * z) + 0.004
	for order in [[1, 2], [2, 1]]:
		var bs: Array[BallCollisions.Body] = [_body(0.0, 0.0, v), null, null]
		bs[order[0]] = _body(x, z)
		bs[order[1]] = _body(x, -z)
		var n := BallCollisions.simulate(bs, 1.0 / 120.0, E, MU)
		var up := bs[order[0]]
		var down := bs[order[1]]
		print("split %s: impacts %d, cue %.3f, sideways %.3f / %.3f, forward %.3f / %.3f" % [order, n, bs[0].vel.x, up.vel.z, down.vel.z, up.vel.x, down.vel.x])
		_check(n == 2, "the cue ball touches both")
		_check(absf(up.vel.z + down.vel.z) < 1e-4 and absf(up.vel.x - down.vel.x) < 1e-4, "a symmetric split throws the two balls symmetrically")
		_check(up.vel.z > 0.1 and down.vel.z < -0.1, "and they leave to the sides")
		_check(absf(bs[0].vel.z) < 1e-4, "the cue ball stays on its line")
		_check(absf(_px(bs) - M * v) < 1e-6, "momentum conserved")
	var g := 2.0 * R + 0.001
	var rack: Array[BallCollisions.Body] = [_body(-0.05, 0.0, v), _body(0.0, 0.0), _body(g * 0.866, g * 0.5), _body(g * 0.866, -g * 0.5)]
	var e0 := _ke(rack)
	BallCollisions.simulate(rack, 1.0 / 120.0, E, MU)
	print("apex: speeds cue %.3f apex %.3f rows %.3f / %.3f" % [rack[0].vel.x, rack[1].vel.x, rack[2].vel.length(), rack[3].vel.length()])
	_check(absf(rack[2].vel.z + rack[3].vel.z) < 1e-4 and absf(rack[2].vel.x - rack[3].vel.x) < 1e-4, "the apex feeds both balls behind it the same")
	_check(_ke(rack) <= e0 + 1e-9, "no energy gained")


## Gaps of a few mm between balls: the second impact happens inside the same tick and still resolves in order.
func _gap_chain() -> void:
	var v := 3.0
	var bs: Array[BallCollisions.Body] = [_body(0.0, 0.0, v), _body(2.0 * R + 0.01), _body(4.0 * R + 0.014)]
	var n := BallCollisions.simulate(bs, 1.0 / 120.0, E, MU)
	_check(n == 2, "a gap of a few mm is crossed inside the tick (%d impacts)" % n)
	_check(bs[2].vel.x > 0.8 * v, "far ball takes the speed over a gap")
	var late: Array[BallCollisions.Body] = [_body(0.0, 0.0, v), _body(2.0 * R + 0.01), _body(4.0 * R + 0.4)]
	var n2 := BallCollisions.simulate(late, 1.0 / 120.0, E, MU)
	_check(n2 == 1, "a ball 40 cm away is not touched this tick")


## An off-centre hit throws the object ball and swaps spin through ball friction; friction never exceeds mu × normal.
func _throw_and_spin() -> void:
	var v := 2.0
	var cut := _body(0.0, 0.0, v)
	var obj := _body(2.0 * R * 0.98, 2.0 * R * 0.2)
	var bs: Array[BallCollisions.Body] = [cut, obj]
	cut.ang = Vector3(0.0, 0.0, -v / R)  # rolling
	var n := BallCollisions.simulate(bs, 1.0 / 120.0, E, MU)
	var dir := obj.vel.normalized()
	print("cut: impacts %d, object dir %.1f deg, object spin %s" % [n, rad_to_deg(atan2(dir.z, dir.x)), obj.ang])
	_check(n == 1, "one impact")
	_check(obj.vel.x > 0.0 and obj.vel.z > 0.0, "object ball goes forward and away from the line")
	_check(obj.ang.length() > 0.0, "contact friction gives the object ball spin")
	var tangential := (obj.vel - cut.vel).length()
	_check(is_finite(tangential) and is_finite(obj.ang.length()), "finite numbers")


func _grazing_and_apart() -> void:
	var miss: Array[BallCollisions.Body] = [_body(0.0, 0.0, 3.0), _body(0.3, 4.0 * R)]
	_check(BallCollisions.simulate(miss, 1.0 / 120.0, E, MU) == 0, "a ball that passes wide is left alone")
	var away: Array[BallCollisions.Body] = [_body(0.0, 0.0, -3.0), _body(2.0 * R)]
	_check(BallCollisions.simulate(away, 1.0 / 120.0, E, MU) == 0, "balls moving apart do not collide")
	var rest: Array[BallCollisions.Body] = [_body(0.0), _body(2.0 * R + 0.0002), _body(4.0 * R + 0.0004)]
	_check(BallCollisions.simulate(rest, 1.0 / 120.0, E, MU) == 0, "balls at rest in contact stay put")
	var slow: Array[BallCollisions.Body] = [_body(0.0, 0.0, 0.01), _body(2.0 * R + 0.0001)]
	_check(BallCollisions.simulate(slow, 1.0 / 120.0, E, MU) == 0, "a creep under V_MIN is not an impact")
