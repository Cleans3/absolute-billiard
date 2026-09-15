extends SceneTree

## One-shot: loop-2 (gamma F2, plan.md T5.2) evidence shots — corner low, corner top-down, side
## top-down, close enough that a loose jaw block or wood-on-cloth (verdict_loop1 F2) would be
## unmistakable if it still existed. Same camera framing as gamma's own gamma_l1_closeup.gd so the
## before/after is directly comparable. Same precedent as screenshot_loop1.gd — kept, run once.
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_loop2.gd

const OUT := "/home/cleanse/work/.herdr/adhoc-wip-table-ball/beta4/"

var scene: Node


func _initialize() -> void:
	scene = load("res://src/levels/MainLevel.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	root.size = Vector2i(1280, 800)
	_run()


func _wait(n: int) -> void:
	for i in n:
		await process_frame


func _shot(shot_name: String) -> void:
	await _wait(4)
	DirAccess.make_dir_recursive_absolute(OUT)
	var err := root.get_texture().get_image().save_png(OUT + shot_name + ".png")
	print("shot ", shot_name, " ", error_string(err))


func _run() -> void:
	await _wait(40)
	var table: Table = scene.get_node("Table")
	var s := table.spec
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var t := table.global_position
	var bed := s.bed_height_m
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.fov = 40.0
	cam.current = true

	cam.global_position = t + Vector3(-hl + 0.05, bed + 0.9, -hw + 0.05)
	cam.look_at(t + Vector3(-hl - 0.03, bed, -hw - 0.03), Vector3(0, 0, -1))
	await _shot("corner_topdown_close")

	cam.global_position = t + Vector3(-hl + 0.45, bed + 0.25, -hw + 0.45)
	cam.look_at(t + Vector3(-hl - 0.03, bed + 0.02, -hw - 0.03), Vector3.UP)
	await _shot("corner_low_close")

	cam.global_position = t + Vector3(0, bed + 0.7, -hw + 0.05)
	cam.look_at(t + Vector3(0, bed, -hw - 0.03), Vector3(0, 0, -1))
	await _shot("side_topdown_close")
	quit()
