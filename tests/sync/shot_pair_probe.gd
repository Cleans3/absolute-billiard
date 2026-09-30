extends SceneTree
## Two-peer shot probe (run through tests/net/pair.sh): the client is made the shooter, requests a
## shot, the host strikes, and the client's reconstructed rest positions match the host's ≤ 5 mm.
## Also: a request out of turn is rejected, the shot is presented on the client, the Turn rotates.
##   tests/net/pair.sh tests/sync/shot_pair_probe.gd
## Prints `SHOTPAIR HOST OK` / `SHOTPAIR CLIENT OK`.

const GATE_M := 0.005

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var _rejected: StringName = &""
var _started := 0
var _ended := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("SHOTPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _rest_dump() -> String:
	var lines := PackedStringArray()
	for b in rd.get_balls():
		var p := table.to_local(b.global_position)
		lines.append("%d %f %f" % [b.net_id, p.x, p.z])
	return "\n".join(lines)


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
	rd = current_scene.get_node("RoundDirector")
	table = current_scene.get_node("Table")
	table.sim.shot_rejected.connect(func(r: StringName) -> void: _rejected = r)
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _started += 1)
	rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], _f: bool) -> void: _ended += 1)
	if role == "host":
		var gl: GameLoop = current_scene.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()  # Round 1 starts: RoundDirector spawns the rack and push_racks it
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	var client_id := int(nm.get_roster()[1].peer_id)
	for i in 120:  # let the rack settle, and give the client time to spawn it
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	assert(rd.current_shooter_id == 1, "host shoots first")
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_rejected")), "client's out-of-turn request", 30.0)
	rd._set_shooter_rpc.rpc(client_id)
	await table.sim.shot_started_net
	await table.sim.all_resting
	await create_timer(0.5).timeout
	var f := FileAccess.open(_file("host_rest"), FileAccess.WRITE)
	f.store_string(_rest_dump())
	f.close()
	assert(rd.current_shooter_id == 1, "Turn rotated back to the host after the shot")
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("SHOTPAIR HOST OK")
	quit(0)


func _client() -> void:
	var me := root.multiplayer.get_unique_id()
	await _until(func() -> bool: return table.sim.get_balls().size() > 5, "client balls registered")
	assert(rd.current_shooter_id != me, "not the shooter yet")
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 0.8
	table.sim.request_shot(intent)
	await _until(func() -> bool: return _rejected != &"", "shot_rejected")
	assert(_rejected == &"not_your_turn", "out-of-turn reason was %s" % _rejected)
	var f := FileAccess.open(_file("client_rejected"), FileAccess.WRITE)
	f.store_string("1")
	f.close()
	await _until(func() -> bool: return rd.current_shooter_id == me, "set_shooter to me")
	# aim at the nearest object ball so the shot has contacts
	var cue: Ball = null
	var nearest: Ball = null
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	for b in rd.get_balls():
		if not b.is_cue_ball and (nearest == null or b.global_position.distance_to(cue.global_position) < nearest.global_position.distance_to(cue.global_position)):
			nearest = b
	var d := nearest.global_position - cue.global_position
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 0.8
	table.sim.request_shot(intent)
	await _until(func() -> bool: return _started == 1, "shot_started_net")
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_rest")), "host rest dump", 30.0)
	await create_timer(1.0).timeout  # playback trails the host by ~100 ms + latency
	assert(_ended == 1, "shot_ended re-emitted on the client (got %d)" % _ended)
	var worst := 0.0
	var seen := 0
	for line in FileAccess.get_file_as_string(_file("host_rest")).split("\n"):
		var p := line.split(" ")
		var b: Ball = table.sim._by_id[int(p[0])]
		if b == null or b.retired:
			continue
		var l := table.to_local(b.global_position)
		worst = maxf(worst, Vector2(l.x - float(p[1]), l.z - float(p[2])).length())
		seen += 1
	print("shotpair: %d balls, worst rest error %.2f mm" % [seen, worst * 1000.0])
	assert(worst <= GATE_M, "client rest positions off by %.2f mm" % (worst * 1000.0))
	assert(rd.current_shooter_id == 1, "Turn rotated back to the host")
	var d2 := FileAccess.open(_file("client_done"), FileAccess.WRITE)
	d2.store_string("1")
	d2.close()
	print("SHOTPAIR CLIENT OK")
	quit(0)
