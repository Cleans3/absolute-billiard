class_name PerfFixture
extends Node3D

## Base of the 07 §9 fixtures. Subclasses implement `_run()` (a coroutine) and push budget rows with
## `check()`. Runs standalone (`godot --path . res://src/debug/perf_<x>.tscn -- --key=value`, exit 1 on any
## FAIL) or as a child of perf_sequence.tscn, which sets `params` first and listens to `finished`.
## Emulator/dev-PC numbers are never budgets (07 header) — the rows say PASS/FAIL against 07's numbers regardless,
## the caller decides how much to trust them.

signal finished(rows: Array)

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const BLUE_T := preload("res://src/resources/ball_types/blue_mid.tres")
const TABLE_POS := Vector3(0, 0, -3.5)  # MainLevel.tscn's Table transform

var params: Dictionary = {}
var fixture_name := "fixture"
var rows: Array[Dictionary] = []
var logger: PerfLogger
var table: Table
var balls: Array[Ball] = []
var cue_ball: Ball
var standalone := false


func _ready() -> void:
	standalone = params.is_empty() and get_parent() == get_tree().root
	if standalone:
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--") and a.contains("="):
				var kv := a.substr(2).split("=", true, 1)
				params[kv[0]] = kv[1]
	_boot.call_deferred()


func _boot() -> void:
	logger = PerfLogger.new()
	add_child(logger)
	await _run()
	logger.end()
	if standalone:
		for r in rows:
			print(format_row(r))
		var failed := rows.any(func(r: Dictionary) -> bool: return r.status == "FAIL")
		print("%s %s" % [fixture_name.to_upper(), "FAIL" if failed else "OK"])
		get_tree().quit(1 if failed else 0)
	finished.emit(rows)


func _run() -> void:
	pass


func arg(key: String, fallback: Variant) -> Variant:
	if not params.has(key):
		return fallback
	return type_convert(params[key], typeof(fallback))


## One budget row. `gate` false = informational (shown, never fails). SKIP when the metric needs a renderer
## and there is none (headless CI) or the platform does not report it (`available` false: GPU timer / draw-call
## monitor read 0 on the Compatibility renderer and on some drivers).
func check(name: String, value: float, limit: float, op: String, unit: String, needs_renderer := false, gate := true, available := true) -> void:
	var status := "INFO"
	if (needs_renderer and not PerfLogger.renders()) or not available:
		status = "SKIP"
	elif gate:
		status = "PASS" if (value <= limit if op == "<=" else value >= limit) else "FAIL"
	rows.append({fixture = fixture_name, budget = name, value = value, limit = limit, op = op, unit = unit, status = status})


static func format_row(r: Dictionary) -> String:
	return "PERF|%s|%s|%.3f|%s %.3f %s|%s" % [r.fixture, r.budget, r.value, r.op, r.limit, r.unit, r.status]


func add_room() -> void:
	add_child(ROOM.instantiate())


func add_table() -> void:
	table = TABLE.instantiate()
	table.position = TABLE_POS
	add_child(table)


func add_camera(pos: Vector3, look_at_pos: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = pos
	cam.look_at(look_at_pos)
	cam.current = true
	return cam


## Cue ball on the kitchen line + `count` object balls in a foot-spot triangle (rows of 1..5), table-local metres,
## as pooled bodies: created once, `reset_rack()` re-places them.
func spawn_balls(count: int) -> void:
	var slots := rack_slots(count)
	for i in slots.size():
		var b: Ball = BALL.instantiate()
		b.ball_type = CUE_T if i == 0 else (RED_T if i % 2 == 1 else BLUE_T)
		b.spec = table.spec
		b.id = "perf_%d" % i
		add_child(b)
		table.sim.register(b)
		balls.append(b)
	cue_ball = balls[0]
	reset_rack()


func rack_slots(count: int) -> Array[Vector2]:
	var s := table.spec
	var gap := s.ball_radius_m * 2.0 + s.clearance_margin_m
	var out: Array[Vector2] = [Vector2(s.kitchen_line_x, 0.0)]
	var row := 0
	while out.size() <= count:
		for k in row + 1:
			if out.size() > count:
				break
			out.append(Vector2(s.foot_spot_x + row * gap * 0.866, (k - row * 0.5) * gap))
		row += 1
	return out


func reset_rack() -> void:
	var s := table.spec
	var slots := rack_slots(balls.size() - 1)
	var y := table.global_position.y + s.bed_height_m + s.ball_radius_m + s.clearance_margin_m
	for i in balls.size():
		var b := balls[i]
		b.restore(Vector3(table.global_position.x + slots[i].x, y, table.global_position.z + slots[i].y))
		b.reset_physics_interpolation()


## Low-poly stand-in for a Player/PlayerSlot avatar (07 header: 4 networked players), same mesh count as Player.tscn's.
func add_avatar(pos: Vector3, yaw_deg: float) -> Node3D:
	var root_n := Node3D.new()
	root_n.position = pos
	root_n.rotation_degrees.y = yaw_deg
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.45, 0.4)
	var parts: Array = [
		[CapsuleMesh.new(), Vector3(0, 0.9, 0)],
		[SphereMesh.new(), Vector3(0, 1.7, 0)],
		[CapsuleMesh.new(), Vector3(-0.28, 1.25, -0.1)],
		[CapsuleMesh.new(), Vector3(0.28, 1.25, -0.1)],
		[CylinderMesh.new(), Vector3(0.3, 1.1, -0.6)],
		[BoxMesh.new(), Vector3(0, 1.9, 0)],
	]
	for p in parts:
		var mi := MeshInstance3D.new()
		var m: PrimitiveMesh = p[0]
		if m is CapsuleMesh:
			m.radius = 0.12
			m.height = 0.5 if (p[1] as Vector3).y < 1.0 else 0.35
			m.radial_segments = 8
			m.rings = 2
		elif m is SphereMesh:
			m.radius = 0.11
			m.height = 0.22
			m.radial_segments = 10
			m.rings = 6
		elif m is CylinderMesh:
			m.top_radius = 0.01
			m.bottom_radius = 0.015
			m.height = 1.4
			m.radial_segments = 6
		elif m is BoxMesh:
			m.size = Vector3(0.28, 0.06, 0.28)
		m.material = mat
		mi.mesh = m
		mi.position = p[1]
		root_n.add_child(mi)
	add_child(root_n)
	return root_n
