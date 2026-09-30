extends SceneTree

## Headless feel probe (01 §4 fixtures, partial; plan.md T1.4/T1.7/T1.9): stop distance, cushion
## angle vs speed, draw/follow, straight-in pot, jaw hit, cue reach, full-power rail return.
##   godot --path . --headless -s tests/physics/probe.gd
## Prints numbers; asserts the qualitative rules (ball stops, hard hit rebounds flatter, draw
## comes back, a pot pots, a reach limit is a limit).

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
	b.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	b.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
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
	await _seam_pots()
	await _side_jaw_scale1()
	await _rail_return()

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
	b.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	b.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
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
	b.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	b.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
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
	b.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	b.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
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
	db.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	db.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
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
	f.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	f.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
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


func _seam_shoot(pos: Vector3, v: Vector3) -> Ball:
	var b := _ball(RED_T, pos)
	await physics_frame
	b.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	b.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
	b.linear_velocity = v
	var dir := v.normalized()
	b.angular_velocity = Vector3(dir.z, 0, -dir.x) * (v.length() / b.radius)
	table.sim._on_struck(b, ShotIntent.new())
	var timer := create_timer(5.0)
	while not b.is_pocketed and timer.time_left > 0.0:
		await physics_frame
	return b


## Loop 2 (gamma F1, plan.md T5.1): a ball hugging either rail into a corner at moderate speed, or
## cutting into one off-angle, must still pot at both scales — the cushion/facing seam (loop-1
## verdict F1: a ghost contact where two separate StaticBody3D met, not a geometry gap) must never
## deflect it. Rebuilds the shared `table` at scale 1.0 and back, same precedent as
## `_side_jaw_scale1` below.
func _seam_pots() -> void:
	for scale in [1.0, 2.0]:
		table.spec.scale = scale
		table.rebuild()
		y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
		await physics_frame
		var s := table.spec
		var hl := s.length_m * 0.5
		var hw := s.width_m * 0.5
		var r := s.ball_radius_m
		var speeds: Array = [0.8, 1.5] if scale == 1.0 else [3.0]
		for sp in speeds:
			for off in [1.02, 1.05, 1.3]:
				var b := await _seam_shoot(Vector3(-hl + 14.0 * r, y, -hw + r * off), Vector3(-sp, 0, 0))
				print("probe: seam long-rail scale=%.1f %.1f m/s off=%.2fR pocketed=%s pos=%s" % [scale, sp, off, b.is_pocketed, b.global_position])
				assert(b.is_pocketed, "seam: long-rail shot must pot (scale %.1f, %.1f m/s, off %.2fR)" % [scale, sp, off])
				_kill(b)
				await _rest()
		if scale == 1.0:
			for off in [1.02, 1.05, 1.3]:
				var b := await _seam_shoot(Vector3(-hl + r * off, y, -hw + 14.0 * r), Vector3(0, 0, -1.5))
				print("probe: seam short-rail scale=1.0 1.5 m/s off=%.2fR pocketed=%s pos=%s" % [off, b.is_pocketed, b.global_position])
				assert(b.is_pocketed, "seam: short-rail shot must pot (off %.2fR)" % off)
				_kill(b)
				await _rest()
			var pocket := table.get_pocket(&"corner_se")
			var target := Vector3(pocket.position.x, 0, pocket.position.z)
			var diag := Vector3(1, 0, 1).normalized()
			for ang in [0.0, 15.0, 25.0]:
				var d := diag.rotated(Vector3.UP, deg_to_rad(ang))
				var start := target - d * 12.0 * r
				var b := await _seam_shoot(start + Vector3(0, y, 0), d * 1.2)
				print("probe: seam cut-in scale=1.0 1.2 m/s ang=%.0f pocketed=%s pos=%s" % [ang, b.is_pocketed, b.global_position])
				assert(b.is_pocketed, "seam: cut-in shot must pot (angle %.0f deg)" % ang)
				_kill(b)
				await _rest()
	table.spec.scale = 2.0
	table.rebuild()
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	await physics_frame


## Loop 1 (gamma H, plan.md T4.8): a ball into a side jaw at 9 m/s (near the cue power cap) must
## stay on the table at every scale — pocketed or rattled back, either is fine, but it must never
## tunnel a facing/cushion or launch clean over the rail. Rebuilds the shared `table` at scale 1.0
## (regulation-accurate ball size/spin is exactly what exposed it: same absolute cue speed, but a
## smaller ball spins twice as fast for it) and back to 2.0 afterwards — a second Table/PhysicsSim
## can't coexist with the shared one, both register the same "Game/AwakeBalls" global monitor.
func _side_jaw_scale1() -> void:
	table.spec.scale = 1.0
	table.rebuild()
	var s := table.spec
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var r := s.ball_radius_m
	var sm := s.side_mouth_m * 0.5
	var yy := s.bed_height_m + r + s.clearance_margin_m
	var h := _ball(RED_T, table.global_position + Vector3(-sm - 6.0 * r, yy, hw - 6.0 * r))
	await physics_frame
	print("probe: side jaw 9 m/s at scale 1.0")
	var hdir := (Vector3(-sm, 0, hw) - Vector3(-sm - 6.0 * r, 0, hw - 6.0 * r)).normalized()
	h.freeze = false  # what Ball.strike does: a frozen body drops a set velocity,
	h.is_resting = false  # and PhysicsSim refreezes the rack while nothing counts as awake
	h.linear_velocity = hdir * 9.0
	h.angular_velocity = Vector3(hdir.z, 0, -hdir.x) * (9.0 / h.radius)
	table.sim._on_struck(h, ShotIntent.new())
	var timer := create_timer(8.0)
	while table.sim.awake > 0 and timer.time_left > 0.0 and not h.is_pocketed:
		await physics_frame
	var hp := h.global_position - table.global_position
	var outside := absf(hp.x) > hl + s.rail_width_m or absf(hp.z) > hw + s.rail_width_m
	var below := hp.y < s.bed_height_m
	print("probe: side jaw 9 m/s pocketed=%s pos=%s outside=%s below=%s" % [h.is_pocketed, hp, outside, below])
	assert(not outside, "a 9 m/s side-jaw hit must never leave the table")
	assert(not below, "a 9 m/s side-jaw hit must never fall through the table uncaught")
	_kill(h)
	await physics_frame
	table.spec.scale = 2.0
	table.rebuild()
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	await physics_frame


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
