extends SceneTree
## 07 §1: the table at rest costs ~nothing. Wall us per physics frame for Table + 13 sleeping balls minus the empty
## scene, under a fixed frame step so every frame is exactly one rest tick:
##   godot --headless --path . --fixed-fps 60 -s tests/perf/rest_cost.gd
## History: monitoring pocket Areas (Jolt sensors) alone cost ~440 us/tick until Table armed them only mid-shot.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const LIMIT_US := 50.0  # 07 §1 "table at rest <= 0.05 ms"
const FRAMES := 1200


func _init() -> void:
	call_deferred("_run")


func _us() -> float:
	await physics_frame
	var t0 := Time.get_ticks_usec()
	for i in FRAMES:
		await physics_frame
	return (Time.get_ticks_usec() - t0) / float(FRAMES)


func _run() -> void:
	var base := await _us()
	var t: Table = TABLE.instantiate()
	root.add_child(t)
	for i in 13:
		var b: Ball = BALL.instantiate()
		b.ball_type = load("res://src/resources/ball_types/red_basic.tres")
		b.spec = t.spec
		root.add_child(b)
		b.global_position = Vector3(0.3 * (i % 5) - 0.6, 0.95, 0.3 * (i / 5) - 0.3)
		t.sim.register(b)
	for i in 300:
		await physics_frame
	assert(t.sim.awake == 0, "balls must have settled")
	for a in t.get_children():
		assert(not (a is Area3D and a.monitoring), "pocket sensors must be off at rest")
	var cost := await _us() - base
	print("rest cost: %.1f us/tick over empty (limit %.0f)" % [cost, LIMIT_US])
	assert(cost <= LIMIT_US, "table at rest costs %.1f us/tick" % cost)
	print("REST COST OK")
	quit()
