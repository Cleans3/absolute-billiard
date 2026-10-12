extends SceneTree

## One-shot: the real MainLevel (Solo), a camera looking at the wall mirror, to a PNG. Needs a window.
##   godot --path . -s src/tools/screenshot_mirror.gd -- <out.png> [eye_x eye_y eye_z]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "res://mirror.png"
	var eye := Vector3(float(args[1]), float(args[2]), float(args[3])) if args.size() > 3 else Vector3(-3.0, 1.6, -1.2)
	SaveManager.root = "user://shot_mirror"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	if is_instance_valid(lobby):
		lobby.queue_free()  # added by hand above, so the scene change left it in the tree
	var cam := Camera3D.new()
	cam.fov = 70.0
	level.add_child(cam)
	cam.global_position = eye
	cam.look_at(Vector3(-6.9, 1.4, -3.8))
	for i in 90:
		cam.current = true  # the player's camera reclaims current while it spawns
		for cl: CanvasLayer in root.find_children("*", "CanvasLayer", true, false):
			cl.visible = false
		for c: Control in root.get_children().filter(func(n: Node) -> bool: return n is Control):
			c.visible = false
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	print("saved ", out)
	quit(0)
