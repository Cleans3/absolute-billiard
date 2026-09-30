extends SceneTree
## Two-peer foul probe (tests/net/pair.sh): the client scratches the cue ball into a corner pocket.
## The host pots it, fouls, respawns it in the kitchen (RESTORED frame); the client must see the pot
## presented, `shot_ended` with foul = true, the cue ball visible again at the host's spot ≤ 5 mm,
## and the Turn handed on.
##   tests/net/pair.sh tests/sync/foul_pair_probe.gd
## Prints `FOULPAIR HOST OK` / `FOULPAIR CLIENT OK`.

const GATE_M := 0.005

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var _rejected: StringName = &""
var _started := 0
var _ended := 0
var _foul := false
var _potted := 0
var _respawned := &""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("FOULPAIR %s FAIL: %s" % [role.to_upper(), msg])
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
	rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], f: bool) -> void:
		_ended += 1
		_foul = f)
	rd.cue_respawned.connect(func(r: StringName) -> void: _respawned = r)
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
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	rd._set_shooter_rpc.rpc(client_id)
	await table.sim.shot_started_net
	await table.sim.all_resting
	await create_timer(0.5).timeout
	print("host: shot_ended foul=%s ended=%d; balls: %s" % [_foul, _ended, rd.get_balls().map(func(b: Ball) -> String: return "%s@%s%s" % [b.id, table.to_local(b.global_position).snappedf(0.01), "P" if b.is_pocketed else ""])])
	assert(_respawned != &"", "host did not respawn the cue ball (path blocked? reason %s)" % _respawned)
	var f := FileAccess.open(_file("host_rest"), FileAccess.WRITE)
	f.store_string(_rest_dump())
	f.close()
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("FOULPAIR HOST OK")
	quit(0)


func _client() -> void:
	var me := root.multiplayer.get_unique_id()
	await _until(func() -> bool: return table.sim.get_balls().size() > 5, "client balls registered")
	await _until(func() -> bool: return rd.current_shooter_id == me, "set_shooter to me")
	var cue: Ball = null
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	# the corner pocket whose line from the cue ball stays furthest from every other ball
	var best_dir := Vector2.RIGHT
	var best_clear := -1.0
	for id in table.pockets:
		if not String(id).begins_with("corner"):
			continue
		var a := cue.global_position
		var seg: Vector3 = table.to_global(table.pockets[id].position) - a
		seg.y = 0.0
		var clear := INF
		for b in rd.get_balls():
			if b.is_cue_ball:
				continue
			var rel := b.global_position - a
			rel.y = 0.0
			var t := clampf(rel.dot(seg) / seg.length_squared(), 0.0, 1.0)
			clear = minf(clear, (rel - seg * t).length())
		if clear > best_clear:
			best_clear = clear
			best_dir = Vector2(seg.x, seg.z).normalized()
	var intent := ShotIntent.new()
	intent.aim_dir = best_dir
	print("client: dir %s clear %.3f cue %s" % [best_dir, best_clear, table.to_local(cue.global_position)])
	intent.power = 0.5
	table.sim.request_shot(intent)
	await _until(func() -> bool: return _started == 1, "shot_started_net")
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_rest")), "host rest dump", 30.0)
	await create_timer(1.5).timeout
	assert(_ended == 1, "shot_ended re-emitted on the client (got %d)" % _ended)
	assert(_foul, "a scratch is a foul")
	assert(cue.visible and not cue.retired and not cue.is_pocketed, "cue ball back in play on the client (RESTORED applied)")
	var worst := 0.0
	for line in FileAccess.get_file_as_string(_file("host_rest")).split("\n"):
		var p := line.split(" ")
		var b: Ball = table.sim._by_id[int(p[0])]
		if b == null or b.retired:
			continue
		var l := table.to_local(b.global_position)
		worst = maxf(worst, Vector2(l.x - float(p[1]), l.z - float(p[2])).length())
	print("foulpair: worst rest error %.2f mm, cue at %s" % [worst * 1000.0, table.to_local(cue.global_position)])
	assert(worst <= GATE_M, "client rest positions off by %.2f mm" % (worst * 1000.0))
	assert(rd.current_shooter_id == 1, "Turn rotated back to the host")
	var d2 := FileAccess.open(_file("client_done"), FileAccess.WRITE)
	d2.store_string("1")
	d2.close()
	print("FOULPAIR CLIENT OK")
	quit(0)
