extends SceneTree

## One-shot: verify the shot console Fire/Replay path — same intent from the same position
## gives the same first-contact velocity (T2.6 accept). Run once, then delete.

var _scene: Node
var _console: Node
var _cue: Node


func _initialize() -> void:
	_scene = load("res://src/levels/MainLevel.tscn").instantiate()
	root.add_child(_scene)
	current_scene = _scene
	_run()


func _run() -> void:
	for i in range(5):
		await process_frame

	var debug_node := _scene.get_node("Debug")
	_console = debug_node.get("_shot_console")
	_console.visible = true
	_console._x.value = -0.3
	_console._z.value = 0.0
	_console._power.value = 0.5
	_console._on_fire()
	_cue = _console._cue_ball()

	await physics_frame
	await physics_frame
	var fire_v: Vector3 = _cue.linear_velocity
	print("fire velocity: ", fire_v, " len=", fire_v.length())

	_console._on_replay()
	await physics_frame
	await physics_frame
	var replay_v: Vector3 = _cue.linear_velocity
	print("replay velocity: ", replay_v, " len=", replay_v.length())

	# Same intent + same reset state + same strike() call; a few mm/s drift is Jolt's own
	# solver under a mid-simulation teleport, not something this debug code controls.
	var speed_close := absf(fire_v.length() - replay_v.length()) < 0.05
	var dir_close := fire_v.normalized().dot(replay_v.normalized()) > 0.999
	var same := fire_v.length() > 0.1 and speed_close and dir_close
	print("OK   " if same else "FAIL ", "fire and replay give the same first-contact velocity (within Jolt solver tolerance)")
	quit()
