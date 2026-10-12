extends SceneTree

## M3 gate (07 §3): a ≥40-contact break; the client reconstruction (event frames over a simulated
## 50 ms link, rendered 100 ms behind) stays within 5 mm of the host at every tick — plain, and
## again under cloth_friction_mult 0.7 + table_tilt_deg 1.0 (stats the client mirrors at shot start).
##   godot --path . --headless -s tests/sync/simdiff_probe.gd

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const GATE_M := 0.005
const MIN_CONTACTS := 40
const EVENT_BUDGET := 220  # 07 §3, plain break (06 P30: each pot's drop rides the divergence stream)
const MODDED_EVENT_CEILING := 400  # drinks lengthen shots (108 vs 81 contacts); alpha decides whether 07 §3 flexes

var table: Table
var contacts := 0
var _balls: Array[Ball] = []


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	_run()


func _run() -> void:
	await physics_frame
	await _scenario("plain", 1.0, 0.0, EVENT_BUDGET)
	await _scenario("modded", 0.7, 0.3, MODDED_EVENT_CEILING)
	print("SIMDIFF OK")
	quit()


func _scenario(label: String, cloth_mult: float, tilt_deg: float, event_cap: int) -> void:
	var sim := table.sim
	contacts = 0
	sim.set_stat(&"cloth_friction_mult", cloth_mult)
	sim.set_tilt_direction(Vector2(0.6, 0.8))
	sim.set_stat(&"table_tilt_deg", tilt_deg)
	var y := table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	_ball(CUE_T, Vector3(-table.spec.length_m / 4.0, y, 0.0))
	var r := table.spec.ball_radius_m
	var apex := table.spec.length_m / 4.0
	for row in 5:
		for k in row + 1:
			_ball(RED_T, Vector3(apex + row * r * 1.74, y, (k - row * 0.5) * r * 2.02))
	var diff := SimDiff.new()
	root.add_child(diff)
	diff.attach(sim)
	for i in 90:  # balls placed on the cloth settle to is_resting before a shot is legal
		await physics_frame
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 1.0
	sim.request_shot(intent)
	await sim.all_resting
	for i in 40:
		await physics_frame
	print("simdiff[%s]: %d contacts | %s" % [label, contacts, diff.report()])
	assert(contacts >= MIN_CONTACTS, "break too tame: %d contacts" % contacts)
	assert(diff.max_err_m <= GATE_M, "client drifted %.2f mm > 5 mm" % (diff.max_err_m * 1000.0))
	assert(diff.events <= event_cap, "%d events > %d" % [diff.events, event_cap])
	diff.queue_free()
	for b in _balls:
		b.queue_free()
	_balls.clear()
	for i in 4:
		await physics_frame


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	b.contacted.connect(func(_a: Ball, _o: Node, _k: StringName) -> void: contacts += 1)
	_balls.append(b)
	return b
