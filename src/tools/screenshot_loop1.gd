extends SceneTree

## One-shot: loop-1 (gamma F1-F3, plan.md T4) evidence shots — corner + side pocket at player eye
## height (no floor visible through the pocket mouth) and the HUD mid-break (step ms / contact
## pairs / awake). Same precedent as screenshot_table_int.gd — kept, run once per loop.
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_loop1.gd

const OUT := "/home/cleanse/work/.herdr/adhoc-wip-table-ball/beta3/"
const EYE_HEIGHT := 1.8  # doc 01/04: player eye height above the floor, cloth is bed_height_m below that

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
	var img := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT)
	var err := img.save_png(OUT + shot_name + ".png")
	print("shot ", shot_name, " ", error_string(err))


func _run() -> void:
	await _wait(20)
	var table: Table = scene.get_node("Table")
	var s := table.spec
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var t := table.global_position
	var bed := s.bed_height_m
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.fov = 70.0
	cam.current = true

	# Corner pocket, standing at the table's own eye height, close enough that "floor visible
	# through the mouth" (gamma F2) would be unmistakable if it still existed.
	cam.global_position = t + Vector3(hl - 0.6, EYE_HEIGHT, hw - 0.6)
	cam.look_at(t + Vector3(hl + s.ball_radius_m, bed, hw + s.ball_radius_m), Vector3.UP)
	await _shot("corner_pocket_player_height")

	# Side pocket, same eye height, looking straight down the near long rail at it.
	cam.global_position = t + Vector3(0.0, EYE_HEIGHT, hw - 0.9)
	cam.look_at(t + Vector3(0, bed, hw), Vector3.UP)
	await _shot("side_pocket_player_height")

	# HUD mid-break: step ms / contact pairs / awake (T4.4) while balls are actually moving.
	var dbg = scene.get_node("Debug")
	dbg._hud.visible = true
	cam.global_position = t + Vector3(0, bed + 2.5, 0)
	cam.look_at(t + Vector3(0, bed, 0), Vector3(0, 0, -1))
	var con = dbg._shot_console
	con._x.value = s.kitchen_line_x
	con._z.value = 0.0
	con._power.value = 1.0
	con._on_fire()
	var max_ms := 0.0
	var max_pairs := 0
	for i in 60:
		await process_frame
		var line_ms: String = dbg._hud._label.text.split("\n")[2]
		var line_pairs: String = dbg._hud._label.text.split("\n")[3]
		max_ms = maxf(max_ms, line_ms.split(": ")[1].trim_suffix(" ms").to_float())
		max_pairs = maxi(max_pairs, line_pairs.split(": ")[1].to_int())
	print("HUD@60f (peak over the window): max step ms=%.2f max contact pairs=%d" % [max_ms, max_pairs])
	print("HUD@60f (final frame):\n", dbg._hud._label.text)
	await _shot("hud_break")
	quit()
