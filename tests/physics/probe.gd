extends SceneTree

## Headless feel probe (01 §4 fixtures, partial; plan.md T1.4/T1.7/T1.9): stop distance, cushion
## angle vs speed, draw/follow, straight-in pot, jaw hit, cue reach, full-power rail return.
##   godot --path . --headless -s tests/physics/probe.gd
## Prints numbers; asserts the qualitative rules (ball stops, hard hit rebounds flatter, draw
## comes back, a pot pots, a reach limit is a limit).

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_CONTROLLER := preload("res://src/gameplay/cue/CueController.tscn")
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
	_kill(b)

	var soft := await _rail_angle(2.0)
	var hard := await _rail_angle(9.0)
	print("cushion 45° in: soft %.1f m/s -> %.1f° out, hard %.1f m/s -> %.1f° out" % [2.0, soft, 9.0, hard])
	assert(hard < soft - 10.0, "hard hit must rebound flatter")

	var draw := await _spin_shot(-0.9)
	var follow := await _spin_shot(0.9)
	print("cue ball after full hit at 0.4: draw dx=%.2f m, follow dx=%.2f m" % [draw, follow])
	assert(draw < 0.0 and follow > 0.05, "draw must come back, follow must go through")

	await _straight_in_pot()
	await _jaw_hit()
	await _drop_zone_negatives()
	await _corner_along_rail_pot()
	await _rail_return()
	await _reach_test()

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


## queue_free() on a resting RigidBody3D can sit pending for many frames in headless SceneTree
## runs (no idle-frame processing between our physics_frame awaits) — remove synchronously so a
## later test's raycast never finds a "freed" ball still sitting in the scene.
func _kill(n: Node) -> void:
	root.remove_child(n)
	n.free()


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
	_kill(b)
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
	_kill(obj)
	_kill(cue)
	await physics_frame
	return dx


## T1.4: ball 0.5 m off a corner pocket, straight centre-ball roll into it: 100/100 pots.
func _straight_in_pot() -> void:
	var pocket := table.get_pocket(&"corner_se")
	var dir := Vector2(pocket.position.x, pocket.position.z).normalized()
	var start := Vector3(pocket.position.x, y, pocket.position.z) - Vector3(dir.x, 0, dir.y) * 0.5
	var b := _ball(RED_T, start)
	await physics_frame
	print("probe: straight-in pot")
	var v0 := 1.2
	b.linear_velocity = Vector3(dir.x, 0, dir.y) * v0
	b.angular_velocity = Vector3(dir.y, 0, -dir.x) * (v0 / b.radius)  # pure roll
	var timer := create_timer(6.0)
	while not b.is_pocketed and timer.time_left > 0.0:
		await physics_frame
	print("probe: straight-in pocketed=%s" % b.is_pocketed)
	assert(b.is_pocketed, "0.5 m straight-in shot at a corner must pot")
	await _rest()
	_kill(b)


## T1.4: 8 m/s into a corner facing, 20° off the direct pocket line — must never tunnel, leave
## the table or produce NaN; either it pots anyway or it rattles and ends up at rest on the cloth.
func _jaw_hit() -> void:
	var pocket := table.get_pocket(&"corner_nw")
	var dir := Vector2(pocket.position.x, pocket.position.z).normalized().rotated(deg_to_rad(20.0))
	var start := Vector3(pocket.position.x, y, pocket.position.z) - Vector3(dir.x, 0, dir.y) * 1.0
	var b := _ball(RED_T, start)
	await physics_frame
	print("probe: jaw hit")
	var v0 := 8.0
	b.linear_velocity = Vector3(dir.x, 0, dir.y) * v0
	b.angular_velocity = Vector3(dir.y, 0, -dir.x) * (v0 / b.radius)
	table.sim._on_struck(b, ShotIntent.new())
	await _rest()
	var p := b.global_position
	var hl := table.spec.length_m * 0.5
	var hw := table.spec.width_m * 0.5
	var margin := table.spec.rail_width_m
	var nan := is_nan(p.x) or is_nan(p.y) or is_nan(p.z)
	var below_cloth := not b.is_pocketed and p.y < y - table.spec.clearance_margin_m - 0.01
	var outside := not b.is_pocketed and (absf(p.x) > hl + margin or absf(p.z) > hw + margin)
	print("probe: jaw hit pocketed=%s pos=%s nan=%s below=%s outside=%s" % [b.is_pocketed, p, nan, below_cloth, outside])
	assert(not nan, "jaw hit produced NaN")
	assert(not below_cloth, "jaw hit ball fell below the cloth without being pocketed")
	assert(not outside, "jaw hit ball left the table")
	_kill(b)


## Loop 1 (gamma A/B/D, plan.md T4.1): a ball resting or rolling on the bed, still on the
## playfield side of a pocket's nose line, must never read as pocketed — only a centre that has
## actually reached the throat does (01 §2). The old drop-zone footprint reached back into the
## bed far enough to catch all three of these.
func _drop_zone_negatives() -> void:
	var hl := table.spec.length_m * 0.5
	var hw := table.spec.width_m * 0.5
	var r := table.spec.ball_radius_m

	# A: resting ball near the NW corner mouth, centre well inside the cushion-end line.
	var inner := -r + table.spec.corner_mouth_m * 0.5 + table.spec.corner_shelf_m
	var d := inner + 0.5 * r
	var a := _ball(RED_T, Vector3(-hl + d, y, -hw + d))
	await physics_frame
	for i in 90:
		await physics_frame
	print("probe: drop-zone A (corner-rest) pocketed=%s" % a.is_pocketed)
	assert(not a.is_pocketed, "a ball resting well inside the cushion line must not pot")
	_kill(a)

	# B: resting ball at the north side pocket, centre 1.2 R inside the nose line.
	var b := _ball(RED_T, Vector3(0, y, -hw + r * 1.2))
	await physics_frame
	for i in 90:
		await physics_frame
	print("probe: drop-zone B (side-rest) pocketed=%s" % b.is_pocketed)
	assert(not b.is_pocketed, "a ball resting inside the side pocket's nose line must not pot")
	_kill(b)
	await _rest()

	# D: ball rolling along the long rail past the north side pocket, hugging it at 1.05 R off the
	# nose line the whole way — never actually crosses the nose line, so it must roll through.
	var db := _ball(RED_T, Vector3(-hl * 0.5, y, -hw + r * 1.05))
	await physics_frame
	db.linear_velocity = Vector3(1.0, 0, 0)
	db.angular_velocity = Vector3(0, 0, -1.0 / db.radius)
	table.sim._on_struck(db, ShotIntent.new())
	var timer := create_timer(4.0)
	while not db.is_pocketed and timer.time_left > 0.0:
		await physics_frame
	print("probe: drop-zone D (rail-roll past side pocket) pocketed=%s pos=%s" % [db.is_pocketed, db.global_position])
	assert(not db.is_pocketed, "a ball hugging the rail past a side pocket without crossing the nose line must not pot")
	_kill(db)
	await _rest()


## Loop 1 (gamma F, plan.md T4.2): a ball hugging the rail into a corner at moderate speed must
## still find the pocket — the jaw facing must not stick out past the nose line and reject it
## before it ever reaches the mouth.
func _corner_along_rail_pot() -> void:
	var hl := table.spec.length_m * 0.5
	var hw := table.spec.width_m * 0.5
	var r := table.spec.ball_radius_m
	var f := _ball(RED_T, Vector3(-hl + 14.0 * r, y, -hw + r * 1.05))
	await physics_frame
	print("probe: corner along-rail")
	f.linear_velocity = Vector3(-1.5, 0, 0)
	f.angular_velocity = Vector3(0, 0, 1.5 / f.radius)
	table.sim._on_struck(f, ShotIntent.new())
	var timer := create_timer(4.0)
	while not f.is_pocketed and timer.time_left > 0.0:
		await physics_frame
	print("probe: corner along-rail 1.5 m/s pocketed=%s pos=%s" % [f.is_pocketed, f.global_position])
	assert(f.is_pocketed, "a moderate-speed ball hugging the rail into a corner must pot, not reject off the jaw")
	_kill(f)
	await _rest()


## T1.7: full-power straight shot from the head spot must clear the table, rebound off the foot
## rail and come back at least half the table length before resting.
func _rail_return() -> void:
	var head := Vector3(table.spec.kitchen_line_x, y, 0)
	var b := _ball(CUE_T, head)
	await physics_frame
	print("probe: rail return")
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(1, 0)
	intent.power = 1.0
	var cs := CueSpec.new()
	b.strike(intent, cs)
	var hl := table.spec.length_m * 0.5
	var peak_x := head.x
	var timer := create_timer(12.0)
	while (table.sim.awake > 0 or not b.is_resting) and timer.time_left > 0.0:
		peak_x = maxf(peak_x, b.global_position.x)
		await physics_frame
	var back := peak_x - b.global_position.x
	print("probe: rail return peak_x=%.2f final_x=%.2f back=%.2f (need >= %.2f)" % [peak_x, b.global_position.x, back, table.spec.length_m * 0.5])
	assert(peak_x > hl - table.spec.ball_radius_m, "full-power shot must reach the foot rail")
	assert(back >= table.spec.length_m * 0.5, "full-power shot must return at least half the table")
	_kill(b)
	await _rest()


## T1.9 (A1): CueController._fire() only strikes a ball within its own cue_reach_m — the reach
## follows the struck ball's TableSpec, not a hardcoded distance.
func _reach_test() -> void:
	var head := Vector3(table.spec.kitchen_line_x, y, 0)
	var reach := table.spec.cue_reach_m
	# offset in z so the far ball never sits behind the near ball on the same ray; the reach
	# check is against the raycast's SURFACE hit point, so push the far ball's centre out by a
	# radius too or "1 mm beyond reach" would still raycast well inside it
	var near_ball := _ball(RED_T, head + Vector3(2.4, 0, 0.3))
	var far_ball := _ball(RED_T, head + Vector3(reach + table.spec.ball_radius_m + 0.001, 0, -0.3))
	await physics_frame
	print("probe: cue reach (limit %.2f m)" % reach)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_position = head + Vector3(0, 0.05, 0)

	var cue: Node3D = CUE_CONTROLLER.instantiate()
	root.add_child(cue)
	await physics_frame

	cam.look_at(near_ball.global_position, Vector3.UP)
	cue.power = 0.3
	cue._fire()
	await physics_frame
	await physics_frame
	var near_hit := near_ball.linear_velocity.length() > 0.01
	print("probe: reach near(2.40m) hit=%s" % near_hit)
	assert(near_hit, "ball within cue_reach_m must be struck")

	cam.look_at(far_ball.global_position, Vector3.UP)
	cue.power = 0.3
	cue._fire()
	await physics_frame
	await physics_frame
	var far_hit := far_ball.linear_velocity.length() > 0.01
	print("probe: reach far(%.3fm) hit=%s" % [reach + 0.001, far_hit])
	assert(not far_hit, "ball 1 mm beyond cue_reach_m must not be struck")

	_kill(near_ball)
	_kill(far_ball)
	_kill(cam)
	_kill(cue)
	await _rest()
