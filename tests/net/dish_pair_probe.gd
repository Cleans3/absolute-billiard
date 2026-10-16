extends SceneTree
# PAIR_TIMEOUT=120
## The sink over the network (docs/plan/08 §2.9 step 3, through tests/net/pair.sh). In a live Round with the client to shoot, the client
## buys a cue it cannot pay for: both peers record the same debt, the client is knocked and put at the sink, its Turn passes to the
## host, the shooter rotation skips it while it owes, it washes the debt off at the sink (the host sees every plate), and the next
## rotation gives it the Turn again.
##   tests/net/pair.sh tests/net/dish_pair_probe.gd
## Prints `DISH HOST OK` / `DISH CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var world: WorldInteractions
var rack: CueRack
var sink: DishStation
var rd: RoundDirector
var gl: GameLoop
var client_id := 0
var stand_at := Vector3.INF  # host: where it believes the client stands (the reach tests)


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("DISH %s FAIL: %s" % [role.to_upper(), msg])
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


func _put(name: String, text := "1") -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(name: String) -> String:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, 40.0)
	await create_timer(0.1).timeout
	return FileAccess.get_file_as_string(_file(name))


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _run() -> void:
	CueRack.required = true
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
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
	level = current_scene
	gl = level.get_node("GameLoop")
	rd = level.get_node("RoundDirector")
	world = level.get_node("WorldInteractions")
	rack = level.get_node("CueRack")
	sink = level.get_node("DishStation")
	client_id = int(nm.get_roster()[1].peer_id)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen to end")
	if role == "host":
		await _host()
	else:
		await _client()


func _counter() -> Vector3:
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"bar_buy":
			return (n as Node3D).global_position
	return Vector3.INF


func _host() -> void:
	stand_at = _counter()
	world.player_position_source = func(id: int) -> Vector3: return stand_at if id == client_id else Vector3(0.0, 0.0, 0.0)
	rack.reset_campaign(CueRack.SLOTS - 1)
	gl.economy.add_cash(-gl.economy.cash, &"probe")
	gl.advance()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE, "a live Round")
	rd._set_shooter_rpc.rpc(client_id)  # the client's Turn
	await create_timer(0.3).timeout
	_put("host_ready")
	await _until(func() -> bool: return sink.owes(client_id), "the client's credit buy on the host")
	await _check(sink.debt_of(client_id) == rack.price() and rack.holds(client_id) and gl.economy.cash == 0, "host: the client owes the cue's price, holds it, Cash untouched")
	await _check(rd.current_shooter_id == 1, "host: the debtor's Turn passed to the host (shooter %d)" % rd.current_shooter_id)
	var puppet: Player = level.get_node("PlayerSpawner").call(&"get_player", client_id)
	await _until(func() -> bool: return puppet.mode == Player.Mode.RAGDOLL, "the client's puppet shocked limp", 3.0)
	rd._rotate_shooter()
	await _check(rd.current_shooter_id == 1, "host: the rotation skips a debtor")
	stand_at = sink.global_transform * DishStation.STAND_AT
	_put("host_sink_open")
	await _until(func() -> bool: return not sink.owes(client_id), "the client's plates on the host", 40.0)
	rd._rotate_shooter()
	await _check(rd.current_shooter_id == client_id, "host: paid up, the client gets the Turn again")
	_put("host_done")
	await _read("client_done")
	print("DISH HOST OK")
	quit(0)


func _client() -> void:
	await _read("host_ready")
	await _until(func() -> bool: return rd.current_shooter_id == client_id, "my Turn")
	var me: Player = level.get_node("PlayerSpawner").call(&"get_local_player")
	rack.request_buy()
	await _until(func() -> bool: return sink.owes(client_id), "my debt")
	await _check(sink.debt_of(client_id) == rack.price() and rack.holds(client_id), "client: I owe the cue's price and hold it")
	await _until(func() -> bool: return me.mode == Player.Mode.RAGDOLL, "the shock", 3.0)
	await _until(func() -> bool: return me.mode == Player.Mode.WALK, "standing again", 6.0)
	await _until(func() -> bool: return me.global_position.distance_to(sink.global_transform * DishStation.STAND_AT) < 0.3, "dragged to the sink", 3.0)
	await _until(func() -> bool: return rd.current_shooter_id == 1, "my Turn passed on")
	await _read("host_sink_open")
	var prop := sink.get_node("Prop") as Interactable
	var guard := 0
	while sink.owes(client_id) and guard < 40:
		prop.try_use({})
		await create_timer(DishStation.WASH_SEC + 0.1).timeout
		guard += 1
	await _check(not sink.owes(client_id), "client: washed it off in %d plates" % guard)
	await _read("host_done")
	await _until(func() -> bool: return rd.current_shooter_id == client_id, "my Turn back")
	_put("client_done")
	print("DISH CLIENT OK")
	quit(0)
