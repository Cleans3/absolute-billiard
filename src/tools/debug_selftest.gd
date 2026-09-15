extends SceneTree

## One-shot: exercise every debug_* action as a real input event and assert the expected
## effect. Run once against a live display, then delete (same precedent as rig_builder.gd).

var _scene: Node
var _debug: Node
var _frames := 0
var _fail := false
var _rack_count_before := 0

const STEPS := [
	"freecam_on", "freecam_check_on", "freecam_off", "freecam_check_off",
	"spec_on", "spec_check_on", "spec_off", "spec_check_off",
	"console_on", "console_check_on", "console_off", "console_check_off",
	"timescale", "timescale_check",
	"rack_before", "rack_next", "rack_check",
]
var _step := 0


func _initialize() -> void:
	_scene = load("res://src/levels/MainLevel.tscn").instantiate()
	root.add_child(_scene)
	current_scene = _scene


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("OK   ", label)
	else:
		print("FAIL ", label)
		_fail = true


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	if _frames == 5:
		_debug = _scene.get_node("Debug")
		_check(_debug != null, "Debug node present (release guard did not free it in a debug run)")

	if _frames % 2 != 0:
		return false
	if _step >= STEPS.size():
		_check(not _fail, "ALL SELFTEST STEPS")
		quit()
		return true

	var player: Node = _scene.get_node("Player")
	var rack: Node = _scene.get_node("DemoRack")
	var s: String = STEPS[_step]
	match s:
		"freecam_on":
			_press("debug_freecam")
		"freecam_check_on":
			_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "freecam on -> mouse captured")
			_check(not player.is_physics_processing(), "freecam on -> player physics suppressed")
		"freecam_off":
			_press("debug_freecam")
		"freecam_check_off":
			_check(player.is_physics_processing(), "freecam off -> player physics restored")
		"spec_on":
			_press("debug_spec")
		"spec_check_on":
			_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "spec panel on -> mouse visible")
		"spec_off":
			_press("debug_spec")
		"spec_check_off":
			_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "spec panel off -> mouse captured")
		"console_on":
			_press("debug_console")
		"console_check_on":
			_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "console on -> mouse visible")
		"console_off":
			_press("debug_console")
		"console_check_off":
			_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "console off -> mouse captured")
		"timescale":
			_press("debug_timescale")
		"timescale_check":
			_check(is_equal_approx(Engine.time_scale, 0.5), "timescale step 1 -> 0.5 (got %s)" % Engine.time_scale)
		"rack_before":
			_rack_count_before = rack.get_child_count()
		"rack_next":
			_press("debug_rack_next")
		"rack_check":
			_check(rack.get_child_count() > 0, "rack preset spawned balls (%d -> %d)" % [_rack_count_before, rack.get_child_count()])
	_step += 1
	return false
