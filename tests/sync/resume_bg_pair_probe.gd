extends SceneTree
## Two-peer backgrounding probe (REQ#rules-2, run through tests/net/pair.sh): the client's app is paused
## (faked through NetManager.set_backgrounded) for a whole host shot, so it misses the entire stream. On
## resume it asks the host for full state and must land within 5 mm of the host inside 1 s, with the same
## Turn / shooter / Cash. Then the host backgrounds: the client shows "host away", and both re-converge.
##   tests/net/pair.sh tests/sync/resume_bg_pair_probe.gd
## Prints `RESUMEBG HOST OK` / `RESUMEBG CLIENT OK`.

const GATE_M := 0.005
const RESUME_WITHIN_SEC := 1.0
const CASH_MARK := 250

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var econ: Node


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("RESUMEBG %s FAIL: %s" % [role.to_upper(), msg])
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


func _touch(name: String, text := "1") -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _has(name: String) -> bool:
	return FileAccess.file_exists(_file(name))


func _dump() -> String:
	var lines := PackedStringArray()
	for b in rd.get_balls():
		var p := table.to_local(b.global_position)
		lines.append("%d %f %f %d" % [b.net_id, p.x, p.z, 1 if b.retired else 0])
	return "\n".join(lines)


## Worst table-local error (m) of this peer's balls against a host dump; retired balls must match too.
func _worst_vs(dump: String) -> float:
	var worst := 0.0
	for line in dump.split("\n"):
		var p := line.split(" ")
		var b: Ball = table.sim._by_id[int(p[0])] if int(p[0]) < table.sim._by_id.size() else null
		if b == null:
			return INF
		if (1 if b.retired else 0) != int(p[3]):
			return INF
		if b.retired:
			continue
		var l := table.to_local(b.global_position)
		worst = maxf(worst, Vector2(l.x - float(p[1]), l.z - float(p[2])).length())
	return worst


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
	econ = current_scene.get_node("EconomyManager")
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
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	await _until(func() -> bool: return _has("client_paused"), "client paused", 30.0)
	# the whole shot happens while the client is blind
	var cue: Ball = null
	var nearest: Ball = null
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	for b in rd.get_balls():
		if not b.is_cue_ball and (nearest == null or b.global_position.distance_to(cue.global_position) < nearest.global_position.distance_to(cue.global_position)):
			nearest = b
	var d := nearest.global_position - cue.global_position
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 0.9
	intent.shooter_id = 1
	table.sim.request_shot(intent)  # shot_started_net fires synchronously inside it on the host
	await table.sim.all_resting
	await create_timer(0.5).timeout
	econ.add_cash(CASH_MARK, &"probe")
	_touch("host_state", "%d %d\n%s" % [rd.current_shooter_id, econ.cash, _dump()])
	await _until(func() -> bool: return _has("client_resumed"), "client resumed", 30.0)
	# host away: the client is told, then everything re-converges on the host's return
	nm.set_backgrounded(true)
	await _until(func() -> bool: return _has("client_saw_away"), "client saw host away", 30.0)
	nm.set_backgrounded(false)
	await _until(func() -> bool: return _has("client_done"), "client verdict", 30.0)
	print("RESUMEBG HOST OK")
	quit(0)


func _client() -> void:
	var me := root.multiplayer.get_unique_id()
	await _until(func() -> bool: return table.sim.get_balls().size() > 5, "client balls registered")
	for i in 180:  # the rack has settled on both peers
		await physics_frame
	nm.set_backgrounded(true)
	_touch("client_paused")
	await _until(func() -> bool: return _has("host_state"), "host shot done", 30.0)
	await create_timer(1.0).timeout  # the reliable rows have long landed; the ball stream was dropped
	var lines := FileAccess.get_file_as_string(_file("host_state")).split("\n", true, 1)
	var head := lines[0].split(" ")
	var stale := _worst_vs(lines[1])
	print("resumebg: before resume worst error %s mm" % ("inf" if is_inf(stale) else "%.1f" % (stale * 1000.0)))
	assert(stale > 0.05, "the blind client must have missed the shot (worst %.3f m)" % stale)
	var t0 := Time.get_ticks_msec()
	nm.set_backgrounded(false)
	await _until(func() -> bool: return _worst_vs(lines[1]) <= GATE_M, "positions within 5 mm", 5.0)
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	print("resumebg: within %.1f mm after %.2f s (%d balls)" % [_worst_vs(lines[1]) * 1000.0, took, table.sim.get_balls().size()])
	assert(took <= RESUME_WITHIN_SEC, "resume took %.2f s" % took)
	await _until(func() -> bool: return econ.cash == int(head[1]), "cash == host", 5.0)
	assert(rd.current_shooter_id == int(head[0]) and rd.current_shooter_id == me, "Turn/shooter matches the host (host says %s)" % head[0])
	assert(not rd.shot_in_progress, "no phantom shot in progress")
	assert(not table.sim._blind, "client leaves the blind state")
	_touch("client_resumed")
	# host away
	await _until(func() -> bool: return nm.host_away, "host away shown", 10.0)
	_touch("client_saw_away")
	await _until(func() -> bool: return not nm.host_away, "host returned", 10.0)
	await create_timer(0.5).timeout
	assert(_worst_vs(lines[1]) <= GATE_M, "still in sync after the host's return")
	_touch("client_done")
	print("RESUMEBG CLIENT OK")
	quit(0)
