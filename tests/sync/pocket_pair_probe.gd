extends SceneTree
## Two-peer pocket-drop probe (tests/net/pair.sh, adhoc-1011a T4 / 06 P30): the client scratches the cue ball into a corner
## pocket. On the CLIENT the cue ball must visibly drop into the hole: its y falls below the cloth before the pot is
## flagged, the pot flag arrives with the ball down in the cup, it is hidden (RETIRED) only once it is well below the
## cloth, and it never teleports between frames. The host agrees (pot + foul).
##   tests/net/pair.sh tests/sync/pocket_pair_probe.gd
## Prints `POCKETPAIR HOST OK` / `POCKETPAIR CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var _rejected: StringName = &""
var _started := 0
var _ended := 0
var _foul := false
var _host_pot_y := INF


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("POCKETPAIR %s FAIL: %s" % [role.to_upper(), msg])
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
	var cue: Ball
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	cue.net_flag.connect(func(_b: Ball, flag: int) -> void:
		if flag == BallEventCodec.Flag.POCKETED:
			_host_pot_y = table.to_local(cue.global_position).y)
	await table.sim.shot_started_net
	await table.sim.all_resting
	await create_timer(0.5).timeout
	print("host: shot_ended foul=%s ended=%d cue pocketed=%s pot_y=%.3f" % [_foul, _ended, cue.is_pocketed, _host_pot_y])
	assert(_host_pot_y <= table.spec.bed_height_m - table.spec.pot_depth_m + 0.03, "host potted the cue ball before it was down in the cup (y %.3f)" % _host_pot_y)
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("POCKETPAIR HOST OK")
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
	intent.power = 0.5
	table.sim.request_shot(intent)
	await _until(func() -> bool: return _started == 1, "shot_started_net")
	# every frame of the cue ball on this client: [y rel. table, visible, pocketed, retired]
	var trace: Array[Array] = []
	var t0 := Time.get_ticks_msec()
	while not cue.retired and Time.get_ticks_msec() - t0 < 25000:
		await process_frame
		trace.append([table.to_local(cue.global_position).y, cue.visible, cue.is_pocketed, cue.retired])
	assert(cue.retired, "the potted cue ball must be retired on the client")
	await create_timer(0.5).timeout
	var cloth := table.spec.bed_height_m
	var r := table.spec.ball_radius_m
	var i_pot := -1
	var i_ret := trace.size() - 1
	for i in trace.size():
		if i_pot < 0 and trace[i][2]:
			i_pot = i
	assert(i_pot >= 0, "the client never saw the pot flag")
	var min_before := INF
	var max_step := 0.0
	for i in trace.size():
		if i < i_pot:
			min_before = minf(min_before, float(trace[i][0]))
		if i > 0:
			max_step = maxf(max_step, absf(float(trace[i][0]) - float(trace[i - 1][0])))
		if not trace[i][1]:  # hidden
			assert(float(trace[i][0]) <= cloth - r, "ball hidden above the cloth (y %.3f)" % float(trace[i][0]))
	print("pocketpair: client frames=%d pot at #%d y=%.3f, retired at #%d y=%.3f, lowest y before the flag %.3f, max step %.3f" % [trace.size(), i_pot, float(trace[i_pot][0]), i_ret, float(trace[i_ret][0]), min_before, max_step])
	assert(float(trace[i_pot][0]) <= cloth - r, "client flagged the pot with the ball still near the cloth (y %.3f)" % float(trace[i_pot][0]))
	assert(min_before <= cloth + r - 0.02, "the ball never visibly dropped before the pot flag (lowest y %.3f)" % min_before)
	assert(float(trace[i_ret][0]) <= cloth - r, "retired above the cloth (y %.3f)" % float(trace[i_ret][0]))
	assert(max_step <= 0.25, "ball teleported %.3f m in one frame" % max_step)
	var d2 := FileAccess.open(_file("client_done"), FileAccess.WRITE)
	d2.store_string("1")
	d2.close()
	print("POCKETPAIR CLIENT OK")
	quit(0)
