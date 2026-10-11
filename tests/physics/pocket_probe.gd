extends SceneTree

## Real pockets (06 P30, adhoc-1011a T2/T3): mouth widths, the hole in the bed, the drop below the cloth before a
## pot counts, off-line shots still dropping, jaw rejection beyond the mouth, resize/move of the real hole.
##   godot --path . --headless -s tests/physics/pocket_probe.gd
## Prints numbers, asserts the rules; "POCKET PROBE OK" when all hold.

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")

var table: Table
var cloth := 0.0
var _dropped: Array[StringName] = []


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	_run()


func _run() -> void:
	await physics_frame
	table.ball_dropped.connect(func(_b: Ball, id: StringName) -> void: _dropped.append(id))
	cloth = table.spec.bed_height_m
	_mouths()
	await _drop_is_visible()
	await _off_line()
	await _jaw_rejection()
	await _fast_does_not_skip()
	await _slow_rim_drop()
	await _grow_swallows_resting_ball()
	await _moving_opening()
	print("POCKET PROBE OK")
	quit()


## Mouth = tip-to-tip gap of the two cushion noses (06 P30): corner >= 2.5 D, side >= 2.7 D, at every scale.
func _mouths() -> void:
	for scale in [1.0, 2.0]:
		var spec := TableSpec.new()
		spec.scale = scale
		var lay := TableGeometry.layout(spec)
		var d := spec.ball_radius_m * 2.0
		for ps in lay.pockets:
			var hole: TableLayout.Hole = lay.holes[ps.id]
			var gap := hole.inner[0].distance_to(hole.inner[hole.inner.size() - 1])
			var need := 2.5 if String(ps.id).begins_with("corner") else 2.7
			print("pocket: %s scale=%.1f mouth=%.2f D (need >= %.1f)" % [ps.id, scale, gap / d, need])
			assert(gap >= need * d - 1e-6, "%s mouth %.2f D < %.1f D" % [ps.id, gap / d, need])
			assert(is_equal_approx(gap, ps.mouth_width_m), "mouth_width_m must be the tip-to-tip gap")
			assert(hole.radius > spec.ball_radius_m, "hole must be wider than a ball")


func _ball_at(local: Vector2, extra_y := 0.0) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = RED_T
	b.spec = table.spec
	root.add_child(b)
	b.global_position = table.to_global(Vector3(local.x, cloth + table.spec.ball_radius_m + 0.002 + extra_y, local.y))
	table.sim.register(b)
	return b


func _kill(b: Ball) -> void:
	root.remove_child(b)
	b.free()


## Rolls `b` along `dir` (unit xz) at `speed` the way Ball.strike would leave it.
func _launch(b: Ball, dir: Vector2, speed: float) -> void:
	b.freeze = false
	b.is_resting = false
	var d := Vector3(dir.x, 0.0, dir.y)
	b.linear_velocity = d * speed
	b.angular_velocity = Vector3(d.z, 0, -d.x) * (speed / b.radius)
	table.sim._on_struck(b, ShotIntent.new())


func _wait(cond: Callable, seconds: float) -> void:
	var t := create_timer(seconds)
	while not cond.call() and t.time_left > 0.0:
		await physics_frame


func _clear(b: Ball) -> void:
	_kill(b)
	await physics_frame
	table.sim._recount()


func _toward(pocket_id: StringName) -> Vector2:
	var ps := table.get_pocket(pocket_id)
	return Vector2(ps.position.x, ps.position.z)


## A straight-in drop: the ball is potted only once its centre is `pot_depth_m` below the cloth, so it is seen dropping
## first, and it is not hidden (retired) until it has settled in the cup.
func _drop_is_visible() -> void:
	for id in [&"corner_se", &"side_s"]:
		var at := _toward(id)
		var dir := at.normalized() if String(id).begins_with("corner") else Vector2(0, 1)
		var b := _ball_at(at - dir * 0.6)
		await physics_frame
		_launch(b, dir, 1.2)
		var pot_y := INF
		var min_y_before := INF
		var hidden_before_pot := false
		var t := create_timer(5.0)
		while not b.retired and t.time_left > 0.0:
			await physics_frame
			if not b.is_pocketed:
				min_y_before = minf(min_y_before, b.global_position.y)
				hidden_before_pot = hidden_before_pot or not b.visible
			elif pot_y == INF:
				pot_y = b.global_position.y
		print("pocket: %s straight-in pot_y=%.3f (cloth %.3f, limit %.3f) min_y_before=%.3f retired=%s" % [id, pot_y, cloth, cloth - table.spec.pot_depth_m, min_y_before, b.retired])
		assert(b.is_pocketed and b.retired, "%s: straight-in must pot, then retire" % id)
		assert(pot_y <= cloth - table.spec.pot_depth_m + 0.03, "%s: potted before the ball was down in the cup (y %.3f)" % [id, pot_y])
		assert(min_y_before < cloth + table.spec.ball_radius_m - 0.01, "%s: the ball never visibly dropped before the pot" % id)
		assert(not hidden_before_pot, "%s: ball hidden while not potted" % id)
		await _clear(b)


## "Slightly off the pocket line still drops": 0.6 R of lateral miss at both pocket kinds.
func _off_line() -> void:
	for id in [&"corner_nw", &"side_n"]:
		for sign in [-1.0, 1.0]:
			var at := _toward(id)
			var dir := at.normalized() if String(id).begins_with("corner") else Vector2(0, signf(at.y))
			var across := Vector2(-dir.y, dir.x)
			var b := _ball_at(at - dir * 0.7 + across * sign * 0.6 * table.spec.ball_radius_m)
			await physics_frame
			_launch(b, dir, 1.4)
			await _wait(func() -> bool: return b.is_pocketed, 4.0)
			print("pocket: %s off-line %+.1f x0.6R pocketed=%s" % [id, sign, b.is_pocketed])
			assert(b.is_pocketed, "%s: a 0.6 R off-line shot must still drop" % id)
			await _clear(b)


## A shot at the cushion beyond the mouth is rejected, not swallowed: the jaw still jaws.
func _jaw_rejection() -> void:
	var s := table.spec
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var tip_x := -hl + s.corner_mouth_m / sqrt(2.0)  # NW corner's tip on the north rail
	var aim := Vector2(tip_x + 0.3, -hw)  # the cushion face 0.3 m past the tip
	var dir := Vector2(-0.45, -0.89).normalized()
	var b := _ball_at(aim - dir * 0.9)
	await physics_frame
	_launch(b, dir, 2.5)
	await _wait(func() -> bool: return b.is_pocketed or table.sim.awake == 0, 6.0)
	var p := table.to_local(b.global_position)
	print("pocket: jaw rejection pocketed=%s pos=%s" % [b.is_pocketed, p])
	assert(not b.is_pocketed, "a ball that hits the cushion beyond the mouth must rebound, not pot")
	assert(p.y > cloth - 0.01, "a rejected ball must stay on the cloth")
	await _clear(b)


## The back wall: a 3 m/s ball straight into a side pocket must drop, not skip across the hole and out.
func _fast_does_not_skip() -> void:
	for id in [&"side_s", &"corner_ne"]:
		var at := _toward(id)
		var dir := at.normalized() if String(id).begins_with("corner") else Vector2(0, 1)
		var b := _ball_at(at - dir * 0.8)
		await physics_frame
		_launch(b, dir, 3.0)
		await _wait(func() -> bool: return b.is_pocketed, 4.0)
		print("pocket: %s 3 m/s pocketed=%s" % [id, b.is_pocketed])
		assert(b.is_pocketed, "%s: a 3 m/s straight-in ball must drop" % id)
		await _clear(b)


## A creeping ball crossing the rim falls in: no pocket stalls a slow ball on the lip.
func _slow_rim_drop() -> void:
	var at := _toward(&"side_n")
	var b := _ball_at(at + Vector2(0, 0.55))
	await physics_frame
	_launch(b, Vector2(0, -1), 0.6)
	await _wait(func() -> bool: return b.is_pocketed or table.sim.awake == 0, 8.0)
	print("pocket: slow 0.6 m/s into side_n pocketed=%s" % b.is_pocketed)
	assert(b.is_pocketed, "a slow ball must fall in once its centre passes the rim")
	await _clear(b)


## E2: a mouth that grows takes the cloth from under a resting ball near it; the ball is thawed and drops (the
## RoundDirector then puts it back — it is not a shot).
func _grow_swallows_resting_ball() -> void:
	var hole: TableLayout.Hole = table.layout.holes[&"corner_sw"]
	var dir := Vector2(1, -1).normalized()  # from the SW pocket centre into the table
	var p := hole.center + dir * (hole.radius + table.spec.ball_radius_m * 0.6)
	var b := _ball_at(p)
	await physics_frame
	for i in 60:
		await physics_frame
	assert(not b.is_pocketed, "resting just outside the rim must stay put")
	assert(b.freeze, "a resting ball is frozen")
	_dropped.clear()
	table.apply_pocket_stats(1.3, 0.0, 1)
	await _wait(func() -> bool: return b.is_pocketed, 4.0)
	print("pocket: mouth x1.3 swallowed the resting ball=%s dropped=%s" % [b.is_pocketed, _dropped])
	assert(b.is_pocketed and _dropped.has(&"corner_sw"), "a grown hole must drop a ball resting inside it")
	await _clear(b)
	table.apply_pocket_stats(1.0, 0.0, 1)
	await physics_frame


## Moving Pockets: the real opening slides (a cover over a wider cut). A resting ball inside the nominal circle but
## outside the slid one stays on cloth; when the opening reaches it, it drops. The cover is never coplanar with the bed.
func _moving_opening() -> void:
	var amp := 0.06
	table.apply_pocket_stats(1.0, amp, 7)
	await physics_frame
	var cover := table.get_node_or_null(^"Cover_side_n") as AnimatableBody3D
	assert(cover != null, "Moving Pockets must build a cover per pocket")
	var top := -INF
	for c in cover.get_children():
		if c is CollisionShape3D:
			for v: Vector3 in (c.shape as ConvexPolygonShape3D).points:
				top = maxf(top, v.y)
	assert(top >= 0.001, "cover top must sit >= 1 mm above the cloth (never coplanar), got %.4f" % top)
	table.set_felt_color(Color(0.8, 0.1, 0.1))
	for mi in cover.find_children("CoverMesh", "MeshInstance3D", false, false):
		assert((mi.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color(0.8, 0.1, 0.1)), "cover must recolour with the cloth")
	table.set_felt_color(TableVisuals.CLOTH_COLOR)

	var hole: TableLayout.Hole = table.layout.holes[&"side_n"]
	var ps: PocketSpec = table.pockets[&"side_n"]
	var tangent := Vector2(-ps.mouth_normal.y, ps.mouth_normal.x).normalized()
	var t_pos := _time_for_offset(7, &"side_n", amp, 1.0)
	var t_neg := _time_for_offset(7, &"side_n", amp, -1.0)
	table.set_pocket_time(t_pos)  # the opening has slid by +amp along the tangent
	var slid := tangent * Table.pocket_offset(7, &"side_n", t_pos, amp)
	var r := table.spec.ball_radius_m
	var drop := r + 0.3 * r  # ball centre 0.3 R past the nose line, toward the table
	var half := sqrt(hole.radius * hole.radius - drop * drop)  # half chord of the nominal circle at that depth
	var p := Vector2(hole.center.x - signf(slid.x) * (half - 0.35 * r), hole.center.y - signf(hole.center.y) * drop)
	var inside_nominal := p.distance_to(hole.center) < hole.radius
	var inside_moved := p.distance_to(hole.center + slid) < hole.radius
	print("pocket: moving opening slid=%s ball=%s inside_nominal=%s inside_moved=%s" % [slid, p, inside_nominal, inside_moved])
	assert(inside_nominal and not inside_moved, "probe setup: ball must be inside the nominal circle and outside the slid one")
	var b := _ball_at(p)
	await physics_frame
	for i in 90:
		await physics_frame
	assert(not b.is_pocketed, "a ball over the cover (outside the slid opening) must not drop")
	table.set_pocket_time(t_neg)
	await _wait(func() -> bool: return b.is_pocketed, 4.0)
	print("pocket: opening slid under the ball -> pocketed=%s" % b.is_pocketed)
	assert(b.is_pocketed, "when the opening reaches a resting ball it drops")
	await _clear(b)
	table.apply_pocket_stats(1.0, 0.0, 7)
	await physics_frame


## A pocket-clock time at which the oscillation offset is at its +amp (sign 1) or -amp (sign -1) extreme.
static func _time_for_offset(seed: int, id: StringName, amp: float, sign: float) -> float:
	var best_t := 0.0
	var best := INF
	for i in 600:
		var t := Table.OSC_PERIOD_SEC * float(i) / 600.0
		var d := absf(Table.pocket_offset(seed, id, t, amp) - sign * amp)
		if d < best:
			best = d
			best_t = t
	return best_t
