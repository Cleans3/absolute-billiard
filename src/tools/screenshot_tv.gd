extends SceneTree

## One-shot: the real MainLevel (Solo, a live Round), the wall TV and its two feeds, to PNGs. Needs a window.
##   godot --path . -s src/tools/screenshot_tv.gd -- <out_prefix> [tier=0|1|2] [eye_x eye_y eye_z]
## Writes <prefix>_room.png (the TV seen from the room floor, default eye (0, 1.6, 1.5)), <prefix>_feed_tripod.png and
## <prefix>_feed_ceiling.png (each feed's raw texture, exactly what the glass samples; tier 2 has no tripod feed).
## Tier is forced through `QualityManager.current_tier` (0 = two 640 px feeds, 1 = 480 px, 2 = one wide feed).


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var tier := 0
	var args: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("tier="):
			tier = clampi(int(a.substr(5)), 0, 2)
		else:
			args.append(a)
	var prefix := args[0] if args.size() > 0 else "res://tv"
	var eye := Vector3(float(args[1]), float(args[2]), float(args[3])) if args.size() > 3 else Vector3(0.0, 1.6, 1.5)
	SaveManager.root = "user://shot_tv"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	if is_instance_valid(lobby):
		lobby.queue_free()  # added by hand above, so the scene change left it in the tree
	QualityManager.current_tier = tier
	var tv := level.get_node("Tv") as StreamTv
	level.get_node("GameLoop").advance()  # a live Round: the rack is on the table
	for i in 60:
		await process_frame
	var cam := Camera3D.new()
	cam.fov = 60.0
	level.add_child(cam)
	cam.global_position = eye
	cam.look_at(tv.global_position)
	for i in 180:
		cam.current = true  # the player's camera reclaims current while it spawns
		for cl: CanvasLayer in root.find_children("*", "CanvasLayer", true, false):
			cl.visible = false
		for c: Control in root.get_children().filter(func(n: Node) -> bool: return n is Control):
			c.visible = false
		await process_frame
	await RenderingServer.frame_post_draw
	var room := prefix + "_room.png"
	root.get_texture().get_image().save_png(room)
	print("saved ", room)
	var names := ["tripod", "ceiling"]
	for i in 2:
		var vp: SubViewport = tv._vp[i]
		if vp.size.x <= 2:
			continue
		var path := "%s_feed_%s.png" % [prefix, names[i]]
		vp.get_texture().get_image().save_png(path)
		print("saved ", path, " ", vp.size)
	print("tv tier %d passes %d,%d lit %d,%d" % [tier, tv.renders[0], tv.renders[1], int(tv._lit.x), int(tv._lit.y)])
	quit(0)
