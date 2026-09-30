extends SceneTree
## Two-peer ENet probe (run through tests/net/pair.sh): connect, roster = 2, both load MainLevel,
## two PlayerSlots, pose arrives. Prints `PAIR HOST OK` / `PAIR CLIENT OK`.

var role := ""
var port := 0
var nm: Node


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
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
	if role == "host":
		nm.host(nm.Transport.ENET_DIRECT)
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		assert(nm.seat_order() == PackedInt32Array([1, nm.get_roster()[1].peer_id]), "seat order")
		nm.start_game()
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
	var marker := Vector3(3.0 + me % 7, 0.0, 2.0)
	mine.player.global_position = marker
	var other_id := 1 if me != 1 else int(nm.get_roster()[1].peer_id)
	var other: PlayerSlot = slots.get_node(str(other_id))
	var want := Vector3(3.0 + other_id % 7, 0.0, 2.0)
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
