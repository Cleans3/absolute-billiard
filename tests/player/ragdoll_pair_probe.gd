extends SceneTree
## Two-peer ragdoll probe (run through tests/net/pair.sh, docs/plan/08 §2.7): the host knocks the client's player
## through PlayerSpawner.knock → the client's own body and the host's puppet of it both go limp and both stand
## again; then the client falls hard (owner-side trigger) → the host's puppet of the client goes limp too.
##   tests/net/pair.sh tests/player/ragdoll_pair_probe.gd
## Prints `RAGDOLLPAIR HOST OK` / `RAGDOLLPAIR CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("RAGDOLLPAIR %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 20.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _file(name: String) -> String:
	return OS.get_environment("PAIR_DIR") + "/" + name


func _touch_file(name: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string("1")
	f.close()


func _has(name: String) -> bool:
	return FileAccess.file_exists(_file(name))


func _run() -> void:
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
	level = current_scene
	await _until(func() -> bool: return level.get_node("PlayerSlots").get_child_count() == 2, "both slots")
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	var client_id := int(nm.get_roster()[1].peer_id)
	var puppet := level.get_node("PlayerSlots/%d/Player" % client_id) as Player
	await create_timer(1.0).timeout  # a few poses first, so the puppet has somewhere to stand
	if puppet.is_ragdoll():
		_fail("the client's puppet starts limp")
	level.get_node("PlayerSpawner").knock(client_id, Vector3(2.0, 1.0, 0.0), 1.0)
	await _until(func() -> bool: return puppet.is_ragdoll(), "the client's puppet goes limp (knock RPC)", 5.0)
	_touch_file("host_saw_knock")
	await _until(func() -> bool: return not puppet.is_ragdoll(), "the client's puppet stands again", 10.0)
	await _until(func() -> bool: return _has("client_stood"), "client stood", 10.0)
	_touch_file("host_saw_stand")
	# the owner's own fall: the client tells everyone
	await _until(func() -> bool: return _has("client_falling"), "client falling", 10.0)
	await _until(func() -> bool: return puppet.is_ragdoll(), "the puppet goes limp when the owner falls hard", 5.0)
	_touch_file("host_saw_fall")
	await _until(func() -> bool: return not puppet.is_ragdoll(), "the puppet stands after the fall", 10.0)
	await _until(func() -> bool: return _has("client_done"), "client verdict", 15.0)
	print("RAGDOLLPAIR HOST OK")
	quit(0)


func _client() -> void:
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var up := [0]
	player.got_up.connect(func() -> void: up[0] += 1)
	await _until(func() -> bool: return player.is_ragdoll(), "the host's knock reaches the client's own body", 10.0)
	if player.mode != Player.Mode.RAGDOLL:
		_fail("limp but mode %d" % player.mode)
	await _until(func() -> bool: return _has("host_saw_knock"), "host saw the knock", 10.0)
	await _until(func() -> bool: return not player.is_ragdoll() and player.mode == Player.Mode.WALK, "the client stands again", 10.0)
	var at := player.humanoid.pelvis_at_getup
	if Vector2(player.global_position.x - at.x, player.global_position.z - at.z).length() > 0.2:
		_fail("stood at %s, pelvis lay at %s" % [player.global_position, at])
	_touch_file("client_stood")
	await _until(func() -> bool: return _has("host_saw_stand"), "host saw both stand", 10.0)
	# hard landing, owner side
	player.global_position = Vector3(player.global_position.x, 0.6, player.global_position.z)
	player.velocity = Vector3(0.0, -9.0, 0.0)
	await _until(func() -> bool: return player.is_ragdoll(), "the client falls hard and goes limp", 5.0)
	_touch_file("client_falling")
	await _until(func() -> bool: return _has("host_saw_fall"), "host saw the fall", 10.0)
	await _until(func() -> bool: return up[0] == 2 and player.mode == Player.Mode.WALK, "the client stands after the fall", 10.0)
	_touch_file("client_done")
	print("RAGDOLLPAIR CLIENT OK")
	quit(0)
