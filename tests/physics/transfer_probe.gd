extends SceneTree

## Ball→ball transfer in the real engine, Jolt's own response vs BallCollisions (01 §4 "Ball–ball contact"):
##   godot --path . --headless --fixed-fps 120 -s tests/physics/transfer_probe.gd     prints TRANSFER OK
## Same shots with `ball_cascade_enabled` off (Jolt: touching balls solved as one lump) and on. Measured the tick after the
## impact, frictionless cloth and no drag, so the numbers are the impact alone. Also: roll-out and cushion rebound.

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")

var table: Table
var y := 0.0
var _fail := 0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	_run.call_deferred()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("TRANSFER: " + msg)


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	return b


func _kill(bs: Array) -> void:
	for n in bs:
		root.remove_child(n)
		n.free()


func _ke(bs: Array) -> float:
	var k := 0.0
	for b: Ball in bs:
		k += 0.5 * b.mass * b.linear_velocity.length_squared()
	return k


## Cue ball (bs[0]) rolling at `v0` into `bs[1..]`; returns state 4 ticks after the first object ball moves.
func _shot(bs: Array, v0: float) -> Dictionary:
	var cue: Ball = bs[0]
	await physics_frame
	table.sim._on_struck(cue, ShotIntent.new())
	await physics_frame
	cue.freeze = false
	cue.is_resting = false
	cue.linear_velocity = Vector3(v0, 0, 0)
	cue.angular_velocity = Vector3(0, 0, -v0 / cue.radius)
	var ke0 := _ke(bs)
	var hit := false
	var after := 0
	for i in 400:
		await physics_frame
		if not hit:
			for k in range(1, bs.size()):
				hit = hit or (bs[k] as Ball).linear_velocity.length() > 0.05
		if hit:
			after += 1
			if after >= 4:
				break
	var obj := 0.0
	var far := 0.0
	var moving := 0
	for k in range(1, bs.size()):
		var s := (bs[k] as Ball).linear_velocity.length()
		obj = maxf(obj, s)
		moving += 1 if s > 0.3 else 0
		far = (bs[k] as Ball).linear_velocity.x if k == bs.size() - 1 else far
	return {cue = cue.linear_velocity.x / v0, top = obj / v0, far = far / v0, ke = _ke(bs) / ke0, moving = moving}


func _scenario(label: String, make: Callable, v0: float) -> Dictionary:
	var out := {}
	for on in [false, true]:
		table.spec.ball_cascade_enabled = on
		var bs: Array = make.call()
		out[on] = await _shot(bs, v0)
		_kill(bs)
		await physics_frame
	var j: Dictionary = out[false]
	var c: Dictionary = out[true]
	print("%s @ %.0f m/s | Jolt: cue %+.0f%% top %.0f%% far %.0f%% KE %.0f%% | BallCollisions: cue %+.0f%% top %.0f%% far %.0f%% KE %.0f%%" % [
		label, v0, 100.0 * j.cue, 100.0 * j.top, 100.0 * j.far, 100.0 * j.ke, 100.0 * c.cue, 100.0 * c.top, 100.0 * c.far, 100.0 * c.ke])
	return c


func _pair() -> Array:
	return [_ball(CUE_T, Vector3(-0.3, y, 0)), _ball(RED_T, Vector3(0.0, y, 0))]


func _chain() -> Array:
	var g := 2.0 * table.spec.ball_radius_m + table.spec.clearance_margin_m
	return [_ball(CUE_T, Vector3(-0.3, y, 0)), _ball(RED_T, Vector3(0, y, 0)), _ball(RED_T, Vector3(g, y, 0)), _ball(RED_T, Vector3(2 * g, y, 0))]


func _rack() -> Array:
	var g := 2.0 * table.spec.ball_radius_m + table.spec.clearance_margin_m
	var bs: Array = [_ball(CUE_T, Vector3(-0.25, y, 0))]
	for row in 5:
		for k in row + 1:
			bs.append(_ball(RED_T, Vector3(row * g * 0.866, y, (k - row * 0.5) * g)))
	return bs


func _run() -> void:
	await physics_frame
	var s := table.spec
	var e := s.ball_restitution
	# isolate the impact: no cloth friction, no drag
	table.get_node("Bed").physics_material_override.friction = 0.0
	s.set_live(&"rolling_resistance", 0.0)
	s.set_live(&"spin_decay", 0.0)
	s.set_live(&"ball_friction", 0.0)
	var pair := await _scenario("stun, 2 balls", _pair, 3.0)
	_check(absf(pair.top - (1.0 + e) / 2.0) < 0.02, "object ball takes (1+e)/2 of the cue speed, got %.3f" % pair.top)
	_check(absf(pair.cue) < 0.1, "the cue ball is left with (1-e)/2, got %.3f" % pair.cue)
	var chain := await _scenario("3 touching in line", _chain, 3.0)
	_check(chain.far > 0.85, "the far end of a frozen line takes the speed (Newton's cradle), got %.2f" % chain.far)
	_check(chain.cue > -0.15, "the cue ball does not rebound off a frozen line, got %.2f" % chain.cue)
	var rack := await _scenario("10-ball rack", _rack, 6.0)
	_check(rack.cue > -0.2, "the cue ball does not ricochet off the rack, got %.2f" % rack.cue)
	_check(rack.ke <= 1.0, "a break never gains energy, got %.2f" % rack.ke)
	_check(rack.moving >= 4, "the break moves the rack, %d moving" % rack.moving)
	await _roll_and_rails()
	print("TRANSFER OK" if _fail == 0 else "TRANSFER FAILED: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _rest() -> void:
	var timer := create_timer(40.0)
	while table.sim.awake > 0 and timer.time_left > 0.0:
		await physics_frame


## Defaults back (cloth friction, drag), then what a player feels: how far a soft roll goes and what a cushion gives back.
func _roll_and_rails() -> void:
	var d := TableSpec.new()
	for f in TableSpec.LIVE_FIELDS:
		table.spec.set_live(f, float(d.get(f)))
	table.apply_physics()
	table.spec.ball_cascade_enabled = true
	var b := _ball(CUE_T, Vector3(-1.2, y, 0))
	await physics_frame
	table.sim._on_struck(b, ShotIntent.new())
	b.freeze = false
	b.is_resting = false
	b.linear_velocity = Vector3(1.0, 0, 0)
	b.angular_velocity = Vector3(0, 0, -1.0 / b.radius)
	var t0 := Time.get_ticks_msec()
	await _rest()
	var dist := b.global_position.x + 1.2
	print("roll 1.0 m/s: %.2f m (the same roll with the old 0.035 + Godot's 0.1/s damping: 1.3 m)" % dist)
	_check(dist > 1.8 and dist < 3.2, "a 1 m/s roll goes 2-3 m, got %.2f" % dist)
	_kill([b])
	await physics_frame
	var line := "cushion e (speed out / in, head-on):"
	var prev := 2.0
	for v in [2.0, 4.0, 6.0, 9.0]:
		var hw := table.spec.width_m * 0.5
		var r := _ball(RED_T, Vector3(0.5, y, hw - table.spec.ball_radius_m - 0.25))
		await physics_frame
		table.sim._on_struck(r, ShotIntent.new())
		r.freeze = false
		r.is_resting = false
		r.linear_velocity = Vector3(0, 0, v)
		r.angular_velocity = Vector3(v / r.radius, 0, 0)  # rolling: no slide to eat the run-up
		for i in 200:
			await physics_frame
			if r.touched_wall():
				break
		for i in 6:
			await physics_frame
		var e_out: float = -r.linear_velocity.z / float(v)  # 0.25 m of rolling run-up: under 2 % slower than v
		line += " %.0f m/s: %.2f," % [v, e_out]
		_check(e_out < prev + 0.02, "a harder hit comes back no livelier (%.2f after %.2f)" % [e_out, prev])
		prev = e_out
		_kill([r])
		await physics_frame
		await _rest()
	print(line)
