extends SceneTree

## One-shot: MainLevel-equivalent framing of the bar room (BarRoom + Table + balls) to a PNG. Needs a window.
##   godot --path . -s src/tools/screenshot_bar_room.gd -- <out.png> [view]   view: table | bar | wide | felt | counter | backbar | west | lounge | door | ceiling | juke | tv
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const DEMO_RACK := preload("res://src/gameplay/round/demo_rack.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "res://bar_room.png"
	var view := args[1] if args.size() > 1 else "table"
	root.add_child(ROOM.instantiate())
	var table: Table = TABLE.instantiate()
	table.position = Vector3(0, 0, -3.5)
	root.add_child(table)
	await physics_frame
	var rack := Node3D.new()
	rack.set_script(DEMO_RACK)
	rack.table = table
	root.add_child(rack)
	var cam := Camera3D.new()
	root.add_child(cam)
	match view:
		"bar":
			cam.position = Vector3(-2.0, 1.7, 0.5)
			cam.look_at(Vector3(5.5, 1.2, 3.5))
		"wide":
			cam.position = Vector3(0, 2.6, 6.6)
			cam.look_at(Vector3(0, 0.6, -4.0))
		"felt":
			cam.position = Vector3(-1.4, 1.45, -2.3)
			cam.look_at(Vector3(0.4, 0.9, -4.0))
		"counter":
			cam.position = Vector3(3.2, 1.6, 1.0)
			cam.look_at(Vector3(5.4, 1.1, 2.6))
		"backbar":
			cam.position = Vector3(5.9, 1.7, 3.9)
			cam.look_at(Vector3(6.8, 1.8, 1.8))
		"west":
			cam.position = Vector3(-2.2, 1.7, 3.6)
			cam.look_at(Vector3(-5.5, 1.0, 3.4))
		"lounge":
			cam.position = Vector3(0.5, 1.7, -1.2)
			cam.look_at(Vector3(5.6, 0.7, -6.0))
		"juke":
			cam.position = Vector3(4.4, 1.6, 3.6)
			cam.look_at(Vector3(6.5, 1.2, 5.8))
		"tv":
			cam.position = Vector3(0.0, 1.7, 1.0)
			cam.look_at(Vector3(1.0, 1.5, 7.0))
		"door":
			cam.position = Vector3(-0.5, 1.7, -2.0)
			cam.look_at(Vector3(0.0, 1.8, -7.0))
		"ceiling":
			cam.position = Vector3(0, 1.7, 2.0)
			cam.look_at(Vector3(0, 3.2, -5.0))
		_:
			cam.position = Vector3(-3.0, 1.8, 0.3)
			cam.look_at(Vector3(0.5, 0.9, -3.5))
	cam.fov = 70.0
	cam.current = true
	root.get_viewport().msaa_3d = Viewport.MSAA_2X
	root.size = Vector2i(1280, 720)
	for i in 30:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	print("screenshot ", out, " ", "OK" if img.save_png(out) == OK else "ERR")
	quit()
