extends SceneTree
## Two-peer Player probe (run through tests/net/pair.sh): the client becomes shooter, walks to the cue ball and
## enters CUE (the host sees its avatar switch to the cue pose), strikes with the touch power slider, and the
## host's PhysicsSim strikes with the client's intent.
##   tests/net/pair.sh tests/player/player_pair_probe.gd
## Prints `PLAYERPAIR HOST OK` / `PLAYERPAIR CLIENT OK`.

const POWER := 0.6

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var level: Node


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("PLAYERPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


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
	rd = level.get_node("RoundDirector")
	table = level.get_node("Table")
	if role == "host":
		var gl: GameLoop = level.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	var client_id := int(nm.get_roster()[1].peer_id)
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	await _until(func() -> bool: return level.get_node("PlayerSlots").get_child_count() == 2, "both slots")
	rd._set_shooter_rpc.rpc(client_id)
	var struck: Array = []
	table.sim.shot_started.connect(func(_b: Ball, i: ShotIntent) -> void: struck.append(i))
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_in_cue")), "client in CUE", 30.0)
	var puppet: Player = level.get_node("PlayerSlots/%d/Player" % client_id)
	await _until(func() -> bool: return puppet._puppet_mode == Player.Mode.CUE, "client's avatar in the cue pose", 10.0)
	var b := _cue_ball()
	await _until(func() -> bool:
		var d := Vector2(puppet.global_position.x - b.global_position.x, puppet.global_position.z - b.global_position.z)
		return absf(d.length() - CueController.BACK_M) < 0.1, "avatar %.2f m behind the cue ball" % CueController.BACK_M, 10.0)
	_touch_file("host_saw_cue")
	await _until(func() -> bool: return not struck.is_empty(), "the client's strike", 30.0)
	var intent: ShotIntent = struck[0]
	if intent.shooter_id != client_id or absf(intent.power - POWER) > 0.02:
		_fail("host struck with shooter %d power %f, expected %d / %f" % [intent.shooter_id, intent.power, client_id, POWER])
	await table.sim.all_resting
	await _until(func() -> bool: return puppet._puppet_mode == Player.Mode.WALK, "client's avatar back in WALK", 10.0)
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("PLAYERPAIR HOST OK")
	quit(0)


func _client() -> void:
	var me := root.multiplayer.get_unique_id()
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var controls: TouchControls = level.get_node("UILayer/TouchControls")
	controls.touch = true
	await _until(func() -> bool: return rd.current_shooter_id == me, "set_shooter to me")
	await _until(func() -> bool: return table.sim.awake == 0, "client table at rest")
	var b := _cue_ball()
	player.global_position = Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	if not player.enter_cue():
		_fail("client could not enter CUE (mode %d)" % player.mode)
	_touch_file("client_in_cue")
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_saw_cue")), "host saw the cue pose", 30.0)
	var pw := controls.power
	pw.size = Vector2(72, 500)
	var e := InputEventScreenTouch.new()
	e.position = Vector2(30, 10)
	e.pressed = true
	pw._gui_input(e)
	var m := InputEventScreenDrag.new()
	m.position = Vector2(30, 500 * POWER)
	m.relative = Vector2(0, 500 * POWER - 10)
	pw._gui_input(m)
	var up := InputEventScreenTouch.new()
	up.position = m.position
	up.pressed = false
	pw._gui_input(up)
	if player.mode != Player.Mode.WALK:
		_fail("still in mode %d after the strike" % player.mode)
	await table.sim.shot_started_net
	await _until(func() -> bool: return not rd.shot_in_progress, "shot resolved on the client", 30.0)
	_touch_file("client_done")
	print("PLAYERPAIR CLIENT OK")
	quit(0)
