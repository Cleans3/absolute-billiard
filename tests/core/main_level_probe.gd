extends SceneTree
## Integration: Lobby → Solo → MainLevel → campaign starts → advance() drops a rack.
## `godot --path . --headless -s tests/core/main_level_probe.gd`


func _init() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	var t0 := Time.get_ticks_msec()  # the load is threaded behind the loading screen: no fixed frame count
	while (current_scene == null or current_scene.name != "MainLevel") and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
	assert(current_scene != null and current_scene.name == "MainLevel", "MainLevel not loaded")
	var loop: GameLoop = current_scene.get_node("GameLoop")
	var rd: RoundDirector = current_scene.get_node("RoundDirector")
	await _frames(5)
	var walker: Player = current_scene.get_node("PlayerSpawner").get_local_player()
	assert(walker != null and root.get_viewport().get_camera_3d() == walker.cam, "local headCam must be the view, got %s" % root.get_viewport().get_camera_3d())
	assert(loop.phase == GameLoop.Phase.INTERMISSION, "expected INTERMISSION, got %s" % loop.phase)
	assert(loop.nights.size() == 5, "5 NightConfigs expected")
	loop.advance()
	await _frames(30)
	assert(loop.phase == GameLoop.Phase.ROUND_LIVE, "expected ROUND_LIVE, got %s" % loop.phase)
	var balls := rd.get_balls()
	assert(balls.size() == 11, "11 balls expected, got %d" % balls.size())
	assert(current_scene.get_node("DemoRack").get_child_count() == 0, "DemoRack must not spawn in MainLevel")
	assert(loop.shots_left == 10, "shots_left 10, got %d" % loop.shots_left)
	print("MAIN OK")
	quit()
