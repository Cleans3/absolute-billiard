extends SceneTree

## One-shot: the real MainLevel (Solo), a camera looking at the wall mirror, to a PNG. Needs a window.
##   godot --path . -s src/tools/screenshot_mirror.gd -- <out.png> [eye_x eye_y eye_z] [blood=<0..1>]
##   godot --path . -s src/tools/screenshot_mirror.gd -- <out.png> cue [blood=<0..1>]
## The second form puts the local player in CUE aiming at the mirror (west) and shoots through their own camera: the body they cannot
## see is in the glass behind them (06 P33 U1). 1 m / 4 m / 10 m from the glass: eye x -5.9 / -2.9 / 3.1 (the glass is at x -6.9).


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: Array[String] = []
	var blood := 0.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("blood="):
			blood = float(a.substr(6))
		else:
			args.append(a)
	var out := args[0] if args.size() > 0 else "res://mirror.png"
	var cue_shot := args.size() > 1 and args[1] == "cue"
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
	if blood > 0.0:
		(level.get_node("Mirror") as Mirror).set_blood(blood)
	var cam: Camera3D = null
	if cue_shot:
		await _enter_cue(level)
	else:
		cam = Camera3D.new()
		cam.fov = 70.0
		level.add_child(cam)
		cam.global_position = eye
		cam.look_at(Vector3(-6.9, 1.4, -3.8))
	for i in 90:
		if cam != null:
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


## A live Round, the cue ball at rest, the local player 2 m east of it aiming west: the camera is pinned 1.2 m behind the ball, the body
## stands outside the table's outline further back and is reflected in the glass.
func _enter_cue(level: Node) -> void:
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var rd: RoundDirector = level.get_node("RoundDirector")
	var table: Table = level.get_node("Table")
	level.get_node("GameLoop").advance()
	for i in 30:
		await process_frame
	var guard := 0
	while table.sim.awake > 0 and guard < 1200:
		guard += 1
		await process_frame
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	var ball: Ball
	for b in rd.get_balls():
		if b.is_cue_ball:
			ball = b
	player.global_position = Vector3(ball.global_position.x + 2.0, 0.0, ball.global_position.z)
	player.velocity = Vector3.ZERO
	player.rotation.y = PI / 2.0
	await process_frame
	if not player.enter_cue():
		push_error("screenshot_mirror: could not enter CUE")
