extends SceneTree
## Two-peer tuning probe (run through tests/net/pair.sh): the host edits physics numbers through DebugSession, and they
## reach the client before the next strike (`motion_stats` between Shots, 06 P49; the `shot_started` stats carry them too),
## again when changed mid-Shot (`motion_stats`), and the client's reconstruction of the shot, modelled from those numbers,
## ends within 1 mm of the host's (the host's rest frame, 06 P49; it was 5 mm and failed one run in three on racked balls).
##   tests/net/pair.sh tests/debug/tuning_pair_probe.gd
## Prints `TUNEPAIR HOST OK` / `TUNEPAIR CLIENT OK`.

const GATE_M := 0.001
const BEFORE := {&"rolling_resistance": 0.012, &"ball_linear_damp": 0.05, &"ball_restitution": 0.9}
const MID_SHOT := 0.03

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var _started := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("TUNEPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _close(a: float, b: float) -> bool:
	return absf(a - b) < 1e-5


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
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _started += 1)
	if role == "host":
		var gl: GameLoop = current_scene.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	var session: DebugSession = current_scene.get_node("Debug").session
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	for f: StringName in BEFORE:
		session.set_field(f, BEFORE[f])
	await physics_frame
	await physics_frame
	assert(_close(table.spec.rolling_resistance, 0.012), "the host applied the edit")
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_has_edit")), "the edit reaching the client between Shots")
	assert(session.fire(session.aim_at_nearest(), 0.8), "the host's shot goes")  # shot_started_net fires inside this call
	await create_timer(0.25).timeout
	session.set_field(&"rolling_resistance", MID_SHOT)  # while the balls roll
	await table.sim.all_resting
	await create_timer(0.5).timeout
	var f := FileAccess.open(_file("host_rest"), FileAccess.WRITE)
	f.store_string(_rest_dump())
	f.close()
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("TUNEPAIR HOST OK")
	quit(0)


func _client() -> void:
	await _until(func() -> bool: return table.sim.get_balls().size() > 5, "client balls registered")
	assert(not _close(table.spec.rolling_resistance, 0.012), "this client has the default numbers before the edit")
	await _until(func() -> bool: return _close(table.spec.rolling_resistance, 0.012), "the host's edit, sent at rest")
	assert(_started == 0, "the edit reached this client before any strike")
	var h := FileAccess.open(_file("client_has_edit"), FileAccess.WRITE)
	h.store_string("1")
	h.close()
	await _until(func() -> bool: return _started == 1, "shot_started_net")
	var s := table.spec
	assert(_close(s.rolling_resistance, 0.012) or _close(s.rolling_resistance, MID_SHOT), "the shot-start stats carried the host's rolling resistance (%f)" % s.rolling_resistance)
	assert(_close(s.ball_linear_damp, 0.05) and _close(s.ball_restitution, 0.9), "and every other live number")
	var ball: Ball = table.sim.get_balls()[0]
	assert(_close(ball.motion.roll_mu, s.rolling_resistance) and _close(ball.motion.damp * 1.4, 0.05), "the model the client replays with follows them")
	await _until(func() -> bool: return _close(table.spec.rolling_resistance, MID_SHOT), "the mid-Shot change (motion_stats)")
	assert(_close(ball.motion.roll_mu, MID_SHOT), "applied to the model too")
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_rest")), "host rest dump", 30.0)
	await create_timer(1.0).timeout
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
	print("tunepair: %d balls, worst rest error %.2f mm" % [seen, worst * 1000.0])
	assert(worst <= GATE_M, "client rest positions off by %.2f mm under tuned numbers" % (worst * 1000.0))
	var d := FileAccess.open(_file("client_done"), FileAccess.WRITE)
	d.store_string("1")
	d.close()
	print("TUNEPAIR CLIENT OK")
	quit(0)
