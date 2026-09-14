extends SceneTree

## Headless awake-lag probe (loop 1, gamma F3a, plan.md T4.3): PhysicsSim.awake must track a real
## break live — a nonzero "moving but awake==0" frame count is the regression gamma found (awake
## lagging ~1.2 s behind actual ball motion because recount only fired on Jolt's own sleep signal,
## never on a strike or on Ball.is_resting itself flipping).
##   godot --path . --headless -s tests/physics/awake_probe.gd

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const RACK := preload("res://src/gameplay/round/demo_rack.gd")
const CUE_SPEC := preload("res://src/resources/cues/demo_cue.tres")

var table: Table
var rack: Node3D


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	rack = Node3D.new()
	rack.set_script(RACK)
	rack.table = table
	root.add_child(rack)
	_run()


func _run() -> void:
	for i in 60:
		await physics_frame

	var cue: Ball
	for b in rack.get_children():
		if b.is_cue_ball:
			cue = b
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(1, 0)
	intent.power = 1.0
	cue.strike(intent, CUE_SPEC)

	var max_awake := 0
	var max_moving := 0
	var lag_frames := 0
	var timer := create_timer(12.0)
	while timer.time_left > 0.0:
		await physics_frame
		var moving := 0
		for b in rack.get_children():
			if not b.is_pocketed and b.linear_velocity.length() > table.spec.rest_speed_mps:
				moving += 1
		max_moving = maxi(max_moving, moving)
		max_awake = maxi(max_awake, table.sim.awake)
		if moving > 0 and table.sim.awake == 0:
			lag_frames += 1
	print("awake probe: max awake=%d max moving=%d lag frames (moving>0, awake==0)=%d" % [max_awake, max_moving, lag_frames])
	assert(lag_frames == 0, "PhysicsSim.awake must never read 0 while a ball is actually moving")
	print("AWAKE PROBE OK")
	quit()
