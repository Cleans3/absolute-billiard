extends SceneTree
## Two-peer session probe (run through tests/net/pair.sh; M5, docs/plan/04 §5): the client mirrors phase, Cash,
## Shop, viewers and a moved camera rig after the host plays a Round, buys through request_purchase, and both
## peers hold the Round-end checkpoint. Prints `SESSION HOST OK` / `SESSION CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var dir := ""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("SESSION %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 20.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _cleanup() -> void:
	for f in DirAccess.get_files_at(dir.path_join("checkpoints")):
		DirAccess.remove_absolute(dir.path_join("checkpoints").path_join(f))
	DirAccess.remove_absolute(dir.path_join("checkpoints"))
	DirAccess.remove_absolute(dir)


func _run() -> void:
	dir = "user://pair_%s_%d" % [role, port]
	DirAccess.make_dir_recursive_absolute(dir)
	SaveManager.root = dir
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	if role == "host":
		nm.host(nm.Transport.ENET_DIRECT)
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		nm.start_game()
	else:
		nm.join_direct("127.0.0.1", port)
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
	await _until(func() -> bool: return current_scene != null and current_scene.name == "MainLevel", "MainLevel")
	var level := current_scene
	var loop: GameLoop = level.get_node("GameLoop")
	var eco: EconomyManager = level.get_node("EconomyManager")
	var stream: StreamManager = level.get_node("StreamManager")
	var cams: CameraRigs = level.get_node("Cameras")
	var is_host: bool = role == "host"
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	if is_host:
		assert(loop.nights.size() == 3)
		eco.add_cash(1000, &"test")
	await _until(func() -> bool: return eco.cash == 1000, "cash 1000 mirrored")
	if not is_host:
		eco.request_purchase.rpc_id(1, &"heavy_shaft")  # the client buys; the host decides
	await _until(func() -> bool: return eco.cash == 700 and eco.count_of(&"heavy_shaft") == 1, "purchase mirrored (cash 700, heavy_shaft)")
	if is_host:
		await create_timer(0.5).timeout  # let the client read the state before the Round starts
		loop.advance()
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.ROUND_LIVE and loop.round_index == 1, "Round 1 live")
	if is_host:
		stream.add_viewers(400)
		cams.rigs[0].global_position = Vector3(2, 0, 2)
	await _until(func() -> bool: return stream.viewers == 500, "viewers 500 mirrored")
	await _until(func() -> bool: return cams.rigs[0].global_position.distance_to(Vector3(2, 0, 2)) < 0.05, "camera rig pose")
	if is_host:
		assert(loop.shots_left == 10)
		await create_timer(1.5).timeout  # the client checks the live Round before it ends
		loop.call(&"_end_round", &"timer")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION and loop.round_index == 1, "Round 1 over")
	var path := SaveManager.checkpoint_path(SaveManager.checkpoint_key(nm.lobby_code, nm.get_roster().size(), nm.session_seed))
	await _until(func() -> bool: return FileAccess.file_exists(path), "checkpoint file " + path)
	await _until(func() -> bool: return eco.cash >= 700 and eco.cash == SaveManager.load_checkpoint(path).crew_cash, "checkpoint cash == mirrored cash")  # +tip: 500 viewers crossed a milestone
	var p := SaveManager.load_checkpoint(path)
	if p == null or p.round_index != 1 or p.round_index != 1 or p.current_night != 1 or p.owned_items.get(&"heavy_shaft") != 1:
		_fail("checkpoint content: %s" % [p.to_dict() if p != null else "null"])
	print("SESSION %s OK" % role.to_upper())
	if is_host:
		await create_timer(2.0).timeout
		_cleanup()
		quit(0)
	else:
		nm.session_ended.connect(func(_r: StringName) -> void:
			_cleanup()
			quit(0))
		await create_timer(20).timeout
		_fail("host never ended the session")
