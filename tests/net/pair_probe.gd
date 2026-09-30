extends SceneTree
## Two-peer ENet probe (run through tests/net/pair.sh): connect, roster = 2, both load MainLevel,
## two PlayerSlots, pose arrives. Prints `PAIR HOST OK` / `PAIR CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var noray := false
var relay := ""
var relay_only := false


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
		elif a == "--noray":
			noray = true
		elif a.begins_with("--relay="):  # relay_host override, e.g. 127.0.0.1 for a local noray
			relay = a.substr(8)
		elif a == "--relay-only":  # skip the direct attempt so the relay path is what gets tested
			relay_only = true
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("PAIR %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 15.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _run() -> void:
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	if relay != "":
		nm.config.relay_host = relay
	if relay_only:
		nm.config.direct_try_sec = 0.0
	var code_file := OS.get_environment("PAIR_DIR") + "/code"
	if role == "host":
		nm.host(nm.Transport.ENET_NORAY if noray else nm.Transport.ENET_DIRECT)
		if noray:
			await _until(func() -> bool: return nm.lobby_code != "", "lobby code")
			var f := FileAccess.open(code_file, FileAccess.WRITE)
			f.store_string(nm.lobby_code)
			f.close()
			print("code %s" % nm.lobby_code)
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		assert(nm.seat_order() == PackedInt32Array([1, nm.get_roster()[1].peer_id]), "seat order")
		nm.start_game()
	else:
		if noray:
			await _until(func() -> bool: return FileAccess.file_exists(code_file), "code file")
			await create_timer(0.2).timeout
			nm.join_code(FileAccess.get_file_as_string(code_file).to_lower())  # codes are case-insensitive
		else:
			nm.join_direct("127.0.0.1", port)
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
	await _until(func() -> bool: return current_scene != null and current_scene.name == "MainLevel", "MainLevel")
	var slots := current_scene.get_node("PlayerSlots")
	await _until(func() -> bool: return slots.get_child_count() == 2, "2 PlayerSlots")
	var me := root.multiplayer.get_unique_id()
	var mine: PlayerSlot = slots.get_node(str(me))
	assert(mine.is_local(), "own slot must be local")
	# Marker pose: each peer parks its walker somewhere unique; the other peer must see it.
	var marker := Vector3(2.0 if me == 1 else 4.5, 0.0, 6.0)  # free floor in BarRoom (a teleport into a prop/wall/other walker gets depenetrated)
	mine.player.global_position = marker
	var other_id := 1 if me != 1 else int(nm.get_roster()[1].peer_id)
	var other: PlayerSlot = slots.get_node(str(other_id))
	var want := Vector3(2.0 if other_id == 1 else 4.5, 0.0, 6.0)
	await _until(func() -> bool: return absf(other.player_position().x - want.x) < 0.2 and absf(other.player_position().z - want.z) < 0.2, "pose from peer %d" % other_id)
	assert(not other.is_local(), "remote slot must not be local")
	assert(current_scene.get_node("PlayerSpawner").get_player_position(other_id).x > 0.0, "get_player_position")
	print("PAIR %s OK" % role.to_upper())
	if role == "host":
		await create_timer(1.5).timeout  # let the client read the host's pose before we drop it
		quit(0)
	else:
		nm.session_ended.connect(func(_r: StringName) -> void: quit(0))
		await create_timer(20).timeout
		_fail("host never ended the session")
