extends SceneTree

## Nothing outruns a collider (adhoc-1013c U12, 01 §3 "Speed ceiling"). A full-power break is 20 m/s and a stat can ask for more;
## `TableSpec.max_ball_speed_mps` (24) is the ceiling `Ball.strike` and `Ball._integrate_forces` enforce, and the cushion, jaw and
## cup colliders are at least that ceiling / LIVE_TICK thick (24 / 120 = 200 mm). This probe fires balls AT the ceiling into
## every kind of obstacle and asserts none is crossed.
##   godot --path . --headless -s tests/physics/speed_probe.gd        prints SPEED OK

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const RUN_FRAMES := 150  # 1.25 s at 120 Hz: several rail crossings at 24 m/s

var table: Table
var y := 0.0
var _fail := 0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("SPEED: " + msg)


func _run() -> void:
	await physics_frame
	_plan()
	await _clip()
	await _cushions()
	await _balls()
	await _jaws()
	if _fail > 0:
		printerr("SPEED FAILED: %d" % _fail)
		quit(1)
		return
	print("SPEED OK")
	quit()


## The pure part: the power curve and the ceiling.
func _plan() -> void:
	var cue := CueSpec.new()
	_check(is_zero_approx(cue.speed_at(0.0)) and is_equal_approx(cue.speed_at(1.0), cue.power_cap_speed_mps), "speed_at spans 0 .. the cap")
	var prev := -1.0
	for i in 21:
		var v := cue.speed_at(i / 20.0)
		_check(v > prev, "speed_at is strictly increasing (%.2f after %.2f)" % [v, prev])
		prev = v
	_check(cue.speed_at(0.5) < 0.4 * cue.power_cap_speed_mps, "half a charge is well under half the cap (%.1f m/s)" % cue.speed_at(0.5))
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 1.0
	var ceiling := table.spec.max_ball_speed_mps
	var plan := Ball.plan_strike(intent, cue, table.spec.ball_radius_m, ceiling, 3.0)
	_check(is_equal_approx(plan.speed, ceiling), "a power stat of x3 is clipped to the %.0f m/s ceiling (got %.1f)" % [ceiling, plan.speed])
	_check(cue.power_cap_speed_mps <= ceiling, "the cue's cap (%.1f) fits under the ceiling (%.1f)" % [cue.power_cap_speed_mps, ceiling])
	var thick := ceiling / float(PhysicsSim.LIVE_TICK)
	var cushion := (table.get_node("rail_e").get_child(0) as CollisionShape3D).shape as BoxShape3D
	_check(cushion.size.x >= thick - 1e-6, "the cushion collider (%.0f mm) is at least one ceiling-speed step (%.0f mm) thick" % [cushion.size.x * 1000.0, thick * 1000.0])
	print("speed: cap %.0f m/s, ceiling %.0f m/s, step-safe collider %.0f mm, half charge %.1f m/s" % [cue.power_cap_speed_mps, ceiling, thick * 1000.0, cue.speed_at(0.5)])


## A ball set to 40 m/s is brought down to the ceiling within a few ticks (a heavy cue ball into a light one, a blast).
func _clip() -> void:
	var b := _ball(RED_T, Vector3(-1.0, y, 0.3))
	await physics_frame
	_launch(b, Vector3.RIGHT * 40.0)
	for i in 4:
		await physics_frame
	var v := b.linear_velocity.length()
	print("speed: 40 m/s ball is at %.2f m/s four ticks later" % v)
	_check(v <= table.spec.max_ball_speed_mps + 0.05, "a 40 m/s ball is clipped to the ceiling (%.2f m/s)" % v)
	_kill(b)
	await physics_frame


## Every rail at the ceiling, straight on and on a diagonal: the ball's centre never passes the nose line (it would be inside
## the cushion), and it is still on the table afterwards.
func _cushions() -> void:
	var hl := table.spec.length_m * 0.5
	var hw := table.spec.width_m * 0.5
	var v := table.spec.max_ball_speed_mps
	var cases := [
		["east", Vector3(0.0, y, 0.3), Vector3.RIGHT],
		["west", Vector3(0.0, y, -0.3), Vector3.LEFT],
		["south", Vector3(1.0, y, 0.0), Vector3.BACK],
		["north", Vector3(-1.0, y, 0.0), Vector3.FORWARD],
		["east diagonal", Vector3(0.0, y, 0.3), Vector3(1.0, 0.0, 0.6).normalized()],
		["south diagonal", Vector3(-1.2, y, 0.0), Vector3(0.7, 0.0, 1.0).normalized()],
	]
	for c in cases:
		var b := _ball(RED_T, c[1])
		await physics_frame
		_launch(b, (c[2] as Vector3) * v)
		var worst := 0.0
		for i in RUN_FRAMES:
			await physics_frame
			var q := b.global_position
			if b.is_pocketed or table.in_hole(Vector2(q.x, q.z)):
				continue
			worst = maxf(worst, maxf(absf(q.x) - hl, absf(q.z) - hw))
		var p := b.global_position
		print("speed: cushion %s at %.0f m/s: worst overshoot of the nose line %.0f mm, now (%.2f, %.2f, %.2f)" % [c[0], v, worst * 1000.0, p.x, p.y, p.z])
		_check(worst <= 0.0, "%s: the ball centre passed the nose line by %.0f mm (tunnelled into or through the cushion)" % [c[0], worst * 1000.0])
		_check(b.is_pocketed or (absf(p.x) < hl + 0.05 and absf(p.z) < hw + 0.05 and p.y > table.spec.bed_height_m - 0.05), "%s: the ball is off the table" % c[0])
		_kill(b)
		await physics_frame


## A ball at the ceiling into a resting one, head-on and cut, and into a touching line: nothing passes through anything.
func _balls() -> void:
	var v := table.spec.max_ball_speed_mps
	var r := table.spec.ball_radius_m
	for cut in [0.0, 0.9]:
		var cue := _ball(CUE_T, Vector3(-1.5, y, 0.0))
		var obj := _ball(RED_T, Vector3(-0.5, y, cut * r))
		await physics_frame
		_launch(cue, Vector3.RIGHT * v)
		var passed := false
		for i in 20:
			await physics_frame
			passed = passed or cue.global_position.x > obj.global_position.x
		print("speed: cue at %.0f m/s into a ball (cut %.1f R): cue x %.2f, object x %.2f (from -0.50)" % [v, cut, cue.global_position.x, obj.global_position.x])
		_check(not passed, "cut %.1f R: the cue ball passed through the object ball" % cut)
		_check(obj.global_position.x > -0.4, "cut %.1f R: the object ball was not struck (x %.2f)" % [cut, obj.global_position.x])
		_kill(cue)
		_kill(obj)
		await physics_frame
	var line: Array[Ball] = []
	for k in 4:
		line.append(_ball(RED_T, Vector3(0.0 + k * (2.0 * r + 0.001), y, 0.0)))
	var cue2 := _ball(CUE_T, Vector3(-1.5, y, 0.0))
	await physics_frame
	_launch(cue2, Vector3.RIGHT * v)
	var order_ok := true
	for i in 25:
		await physics_frame
		var xs: Array[float] = [cue2.global_position.x]
		for b in line:
			xs.append(b.global_position.x)
		for k in range(1, xs.size()):
			order_ok = order_ok and xs[k] > xs[k - 1] - 0.5 * r
	print("speed: cue at %.0f m/s into a line of 4: x %.2f | %s" % [v, cue2.global_position.x, line.map(func(b: Ball) -> String: return "%.2f" % b.global_position.x)])
	_check(order_ok, "the cue ball and the line kept their order (nothing tunnelled)")
	_check(line[3].global_position.x > 0.0 + 3.0 * (2.0 * r) + 0.2, "the far end of the line was thrown (x %.2f)" % line[3].global_position.x)
	_kill(cue2)
	for b in line:
		_kill(b)
	await physics_frame


## Each pocket's facings at the ceiling, three angles: the ball is potted, rattles back or rests, never through.
func _jaws() -> void:
	var hl := table.spec.length_m * 0.5
	var hw := table.spec.width_m * 0.5
	var v := table.spec.max_ball_speed_mps
	for id in table.pockets:
		var pocket: PocketSpec = table.pockets[id]
		var local := table.to_local(pocket.position)
		var at := Vector2(local.x, local.z)
		var inward := Vector2(pocket.mouth_normal).normalized()
		for deg in [-25.0, 0.0, 25.0]:
			var dir := (-inward).rotated(deg_to_rad(deg))
			var start := at - dir * 1.0
			var b := _ball(RED_T, Vector3(start.x, y, start.y))
			await physics_frame
			_launch(b, Vector3(dir.x, 0.0, dir.y) * v)
			for i in 90:
				await physics_frame
			var p := b.global_position
			var out := not b.is_pocketed and (absf(p.x) > hl + table.spec.rail_width_m or absf(p.z) > hw + table.spec.rail_width_m)
			var below := not b.is_pocketed and p.y < table.spec.bed_height_m - 0.05
			print("speed: %s jaws at %.0f m/s, %+.0f deg: pocketed=%s out=%s below=%s nan=%s" % [id, v, deg, b.is_pocketed, out, below, is_nan(p.x)])
			_check(not out and not below and not is_nan(p.x), "%s %+.0f deg: the ball left the table or fell through it (%s)" % [id, deg, p])
			_kill(b)
			await physics_frame


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	return b


## What Ball.strike does to a resting ball, with a chosen velocity: thaw it, make it count as awake, arm the contact monitors.
func _launch(b: Ball, v: Vector3) -> void:
	b.freeze = false
	b.is_resting = false
	b.linear_velocity = v
	var dir := v.normalized()
	b.angular_velocity = Vector3(dir.z, 0.0, -dir.x) * (v.length() / b.radius)
	table.sim._on_struck(b, ShotIntent.new())


func _kill(n: Node) -> void:
	root.remove_child(n)
	n.free()
