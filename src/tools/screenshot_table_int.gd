extends SceneTree

## One-shot: load MainLevel from the player's own spawn transform, toggle HUD + gizmos on
## (same input-event precedent as debug_screenshot.gd), screenshot, quit (plan.md T3.3).
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_table_int.gd

const OUT := "/home/cleanse/work/.herdr/adhoc-wip-table-ball/beta1/table_int.png"

var _frames := 0
var _scene: Node


func _initialize() -> void:
	_scene = load("res://src/levels/MainLevel.tscn").instantiate()
	root.add_child(_scene)
	current_scene = _scene
	root.size = Vector2i(1280, 800)


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
