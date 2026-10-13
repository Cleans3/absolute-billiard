extends SceneTree

## One-shot (06 P48): the Bartender's real face, to PNGs. The real MainLevel (Solo), needs a window.
##   godot --path . -s src/tools/screenshot_barkeep_face.gd -- <out.png> front          the local player's own camera at the serve spot (1.8 m)
##   godot --path . -s src/tools/screenshot_barkeep_face.gd -- <out.png> close          0.7 m from the face
##   godot --path . -s src/tools/screenshot_barkeep_face.gd -- <out.png> side           from the customer side, 45 degrees to his right
##   godot --path . -s src/tools/screenshot_barkeep_face.gd -- <out.png> mirror         he stands before the wall mirror, facing it: his face is in the glass
## `fov=<deg>` narrows the free camera (side, mirror). Add `old` to a mode for the old modelled face (the before shot), `fp` to put his head on the first-person layer (the local player's camera must cull it).

const SERVE := Vector3(4.2, 0.0, 2.5)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "res://barkeep_face.png"
	var mode := args[1] if args.size() > 1 else "front"
	var fov := 0.0
	for a in args:
		if a.begins_with("fov="):
			fov = float(a.substr(4))
	SaveManager.root = "user://shot_barkeep_face"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	if is_instance_valid(lobby):
		lobby.queue_free()
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var bartender := level.get_node("Bar/Bartender") as Bartender
	var head := bartender._humanoid.global_position + Vector3(0.0, 1.62, 0.0)
	if args.has("old"):
		bartender._humanoid.get_node("Skeleton/BarkeepFace").free()
		bartender._humanoid.set_face(null)
	if args.has("fp"):
		bartender._humanoid.set_first_person(true)
	var cam: Camera3D = null
	match mode:
		"front":
			player.global_position = SERVE
			player.rotation.y = -PI / 2.0  # looks +X, at him
		"close":
			player.global_position = Vector3(5.3, 0.0, 2.5)
			player.rotation.y = -PI / 2.0
		"side":
			cam = _free_cam(level, head + Vector3(-0.6, 0.0, 0.6), head)
		"mirror":
			# in front of the glass (x -6.9, z -5.6..-2.0), facing it (west); the camera stands behind and to his right
			bartender.global_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(-5.4, 0.0, -3.5))
			player.global_position = Vector3(-1.0, 0.0, -1.0)
			cam = _free_cam(level, Vector3(-3.2, 1.6, -0.8), Vector3(-6.9, 1.5, -2.7))
			cam.fov = 50.0
	if cam != null and fov > 0.0:
		cam.fov = fov
	for i in 90:
		if cam != null:
			cam.current = true
		if cam == null:  # the player's camera: keep the body where the shot wants it
			player.global_position = SERVE if mode == "front" else Vector3(5.3, 0.0, 2.5)
		for cl: CanvasLayer in root.find_children("*", "CanvasLayer", true, false):
			cl.visible = false
		for c: Control in root.get_children().filter(func(n: Node) -> bool: return n is Control):
			c.visible = false
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	print("saved ", out, " mode ", mode)
	quit(0)


func _free_cam(level: Node, at: Vector3, look: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = 40.0
	level.add_child(cam)
	cam.global_position = at
	cam.look_at(look)
	return cam
