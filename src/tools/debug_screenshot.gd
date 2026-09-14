extends SceneTree

## One-shot: load MainLevel, press debug_hud + debug_gizmos as real input events, screenshot
## the running game, quit. Run once against a live display, then delete (rig_builder.gd
## precedent).

const OUT := "/home/cleanse/work/.herdr/adhoc-wip-table-ball/beta2/debug.png"

var _frames := 0
var _scene: Node


func _initialize() -> void:
	_scene = load("res://src/levels/MainLevel.tscn").instantiate()
	root.add_child(_scene)
	current_scene = _scene


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 10:
		_press("debug_hud")
		_press("debug_gizmos")
	if _frames == 30:
		var img := root.get_texture().get_image()
		DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
		var err := img.save_png(OUT)
		print("save_png: ", error_string(err), " -> ", OUT)
		quit()
	return false


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
