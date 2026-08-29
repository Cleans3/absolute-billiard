extends SceneTree

## Headless feel probe (01 §4 fixtures, partial): stop distance, cushion angle vs speed, draw/follow.
##   godot --path . --headless -s tests/physics/probe.gd
## Prints numbers; asserts the qualitative rules (ball stops, hard hit rebounds flatter, draw comes back).

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")

var table: Table
var y := 0.0
var _flag := false  # lambdas capture locals by value; signals set this member instead


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	_run()


func _run() -> void:
	await physics_frame
	var v0 := 1.5
	var b := _ball(CUE_T, Vector3(-1.2, y, 0))
	await physics_frame
	print("probe: rolling")
	b.linear_velocity = Vector3(v0, 0, 0)
	b.angular_velocity = Vector3(0, 0, -v0 / b.radius)  # pure roll
	var t0 := Time.get_ticks_msec()
	await _rest()
	var dist := b.global_position.x + 1.2
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	print("roll %.1f m/s: stopped after %.2f m in %.1f s" % [v0, dist, secs])
	assert(dist > 0.3 and dist < 3.0, "rolling resistance out of range")
	b.queue_free()

	var soft := await _rail_angle(2.0)
	var hard := await _rail_angle(9.0)
	print("cushion 45° in: soft %.1f m/s -> %.1f° out, hard %.1f m/s -> %.1f° out" % [2.0, soft, 9.0, hard])
	assert(hard < soft - 10.0, "hard hit must rebound flatter")

	var draw := await _spin_shot(-0.9)
	var follow := await _spin_shot(0.9)
	print("cue ball after full hit at 0.4: draw dx=%.2f m, follow dx=%.2f m" % [draw, follow])
	assert(draw < 0.0 and follow > 0.05, "draw must come back, follow must go through")
	print("PROBE OK")
	quit()


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	return b


func _rest() -> void:
	var timer := create_timer(12.0)
	_flag = table.sim.awake == 0
	if not _flag:
		table.sim.all_resting.connect(func() -> void: _flag = true, CONNECT_ONE_SHOT)
	while not _flag and timer.time_left > 0.0:
		await physics_frame
	print("probe: rest awake=%d" % table.sim.awake)
	if not _flag:
		for b in table.sim._balls:
			print("  still awake: sleeping=%s v=%s w=%s" % [b.sleeping, b.linear_velocity, b.angular_velocity])


func _rail_angle(speed: float) -> float:
	var b := _ball(CUE_T, Vector3(0, y, 0))
	await physics_frame
	print("probe: rail %.1f" % speed)
	table.sim._on_struck(b, ShotIntent.new())  # contact monitor on without a cue
	var s := speed / sqrt(2.0)
	b.linear_velocity = Vector3(s, 0, s)  # 45° toward the +z long rail
	_flag = false
	b.body_entered.connect(func(body: Node) -> void: _flag = _flag or body.has_meta(&"rail_normal"))
	var guard := create_timer(6.0)
	while not _flag and guard.time_left > 0.0:
		await physics_frame
	print("probe: rail hit=%s" % _flag)
	for i in 6:
		await physics_frame
	var v := b.linear_velocity
	var ang := rad_to_deg(atan2(absf(v.z), absf(v.x)))
	b.queue_free()
	await _rest()
	return ang


func _spin_shot(spin_y: float) -> float:
	var obj := _ball(RED_T, Vector3(0, y, 0))
	var cue := _ball(CUE_T, Vector3(-0.4, y, 0))
	await physics_frame
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(1, 0)
	intent.power = 0.25
	intent.spin_offset = Vector2(0, spin_y)
	var cs := CueSpec.new()
	cue.strike(intent, cs)
	await _rest()
	var dx := cue.global_position.x - 0.0  # relative to the object ball's start
	obj.queue_free()
	cue.queue_free()
	await physics_frame
	return dx
