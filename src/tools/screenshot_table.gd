extends SceneTree

## One-shot: builds a Table + DemoRack, frames it from a player-height viewpoint and saves a PNG
## (plan.md T1.5 accept check).
##   godot --path . --headless -s src/tools/screenshot_table.gd -- <output_path.png>

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const DEMO_RACK := preload("res://src/gameplay/round/demo_rack.gd")


func _init() -> void:
	_run()


func _run() -> void:
	var table: Table = TABLE.instantiate()
	root.add_child(table)
	await physics_frame

	var rack := Node3D.new()
	rack.set_script(DEMO_RACK)
	rack.table = table
	root.add_child(rack)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.1
	root.add_child(sun)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.05, 0.07)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.5, 0.55)
	e.ambient_light_energy = 0.6
	env.environment = e
	root.add_child(env)

	# player-height viewpoint: eye at 1.8 m (Player.tscn's Head), standing at the long rail
	var cam := Camera3D.new()
	var hw := table.spec.width_m * 0.5
	root.add_child(cam)
	cam.position = Vector3(-table.spec.length_m * 0.45, 1.8, hw + table.spec.rail_width_m + 1.6)
	cam.look_at(Vector3(0, table.spec.bed_height_m * 0.6, 0), Vector3.UP)
	cam.current = true
	cam.fov = 65.0

	root.get_viewport().set_size(Vector2i(1280, 800))
	for i in 6:
		await process_frame

	var img := root.get_viewport().get_texture().get_image()
	var out_path := "res://table_screenshot.png"
	if OS.get_cmdline_user_args().size() > 0:
		out_path = OS.get_cmdline_user_args()[0]
	var err := img.save_png(out_path)
	print("screenshot saved to %s: %s" % [out_path, "OK" if err == OK else "ERROR %d" % err])
	quit()
