extends SceneTree
## Re-host drill (run through tests/net/pair.sh; docs/plan/04 §2.6): the host plays to a Round end, both peers hold
## the checkpoint, both leave, the CLIENT re-hosts from its own copy, the old host joins, and the resumed
## campaign's Night/Round/Cash/Shop match the checkpoint. Prints `RESUME HOST OK` / `RESUME CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var dir := ""
var flags := ""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("RESUME %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 20.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _flag(name: String) -> String:
	return flags.path_join("%s_%d" % [name, port])


func _raise(name: String) -> void:
	FileAccess.open(_flag(name), FileAccess.WRITE).close()


func _wait_flag(name: String) -> void:
	await _until(func() -> bool: return FileAccess.file_exists(_flag(name)), "flag " + name)


func _in_level() -> bool:
	return current_scene != null and current_scene.name == "MainLevel"


func _run() -> void:
	dir = "user://resume_%s_%d" % [role, port]
	flags = "user://resume_flags"
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.make_dir_recursive_absolute(flags)
	SaveManager.root = dir
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	# --- phase 1: the original host plays one Round --------------------------------------------------
	if role == "host":
		nm.host(nm.Transport.ENET_DIRECT)
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		nm.start_game()
	else:
		nm.join_direct("127.0.0.1", port)
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
	await _until(_in_level, "MainLevel")
	var level := current_scene
	var loop: GameLoop = level.get_node("GameLoop")
	var eco: EconomyManager = level.get_node("EconomyManager")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	if role == "host":
		eco.add_cash(1000, &"test")
		eco.try_purchase(&"heavy_shaft", 1)
		await create_timer(0.5).timeout
		loop.advance()
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.ROUND_LIVE, "Round 1 live")
	if role == "host":
		await create_timer(1.0).timeout
		loop.call(&"_end_round", &"timer")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION and loop.round_index == 1, "Round 1 over")
	var listed := SaveManager.list_checkpoints()
	await _until(func() -> bool: return not SaveManager.list_checkpoints().is_empty(), "own checkpoint file")
	listed = SaveManager.list_checkpoints()
	var saved := SaveManager.load_checkpoint(listed[0].path)
	if saved.round_index != 1 or saved.crew_cash != 700 or saved.owned_items.get(&"heavy_shaft") != 1 or saved.crew_size != 2:
		_fail("checkpoint content %s" % [saved.to_dict()])
	# --- phase 2: both leave; the client re-hosts from its copy --------------------------------------
	if role == "host":
		await create_timer(1.0).timeout  # the client is holding its copy too
		nm.leave()
		_raise("host_left")
		await _wait_flag("client_hosting")
		await _until(func() -> bool: return current_scene != null and current_scene.name == "Lobby", "back in the Lobby")
		nm.join_direct("127.0.0.1", port)
	else:
		await _wait_flag("host_left")
		nm.leave()
		await create_timer(1.0).timeout
		SaveManager.pending_resume = saved
		nm.host(nm.Transport.ENET_DIRECT)
		await _until(func() -> bool: return nm.is_host() and nm.in_session == false and nm.get_roster().size() == 1, "re-hosting")
		_raise("client_hosting")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "old host rejoined")
		nm.start_game()
	# --- phase 3: the resumed campaign matches the checkpoint on both peers --------------------------
	await create_timer(0.5).timeout
	await _until(_in_level, "resumed MainLevel")
	level = current_scene
	loop = level.get_node("GameLoop")
	eco = level.get_node("EconomyManager")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION and loop.round_index == saved.round_index, "resumed Intermission")
	if loop.night_index != saved.current_night - 1 or eco.cash != saved.crew_cash or eco.count_of(&"heavy_shaft") != 1 or level.get_node("StreamManager").viewers != saved.viewers:
		_fail("resumed state night=%d round=%d cash=%d" % [loop.night_index, loop.round_index, eco.cash])
	print("RESUME %s OK" % role.to_upper())
	await create_timer(2.0).timeout
	for f in DirAccess.get_files_at(dir.path_join("checkpoints")):
		DirAccess.remove_absolute(dir.path_join("checkpoints").path_join(f))
	DirAccess.remove_absolute(dir.path_join("checkpoints"))
	DirAccess.remove_absolute(dir)
	for f in DirAccess.get_files_at(flags):
		if f.ends_with("_%d" % port):
			DirAccess.remove_absolute(flags.path_join(f))
	quit(0)
