extends SceneTree
# PAIR_TIMEOUT=300
## Two-peer table-sync probe (06 P49, run through tests/net/pair.sh): after every step the client's table must be the host's:
## every ball within 1 mm in 3D (height too), the same balls in play, and the same table digest (`RoundDirector.table_check`).
##   1. the rack at rest, 2. a healthy shot, 3. a shot whose whole event stream the client drops (the rest frame carries it),
##   4. a shot whose stream AND rest frame it drops (the digest finds it, the full state mends it), 5. a pot and retire it never hears,
##   6. a late join (the client's table wiped: no balls, no Round), 7. healthy shots again with no desync counted,
##   9. a frozen host ball nudged 4 mm behind the net's back (whatever moves a resting ball): the host's guard sends a new rest
##   frame within a beat, the client matches with no desync counted.
##   tests/net/pair.sh tests/sync/rest_pair_probe.gd
## Prints `RESTPAIR HOST OK` / `RESTPAIR CLIENT OK`.

const GATE_M := 0.001
const MEND_WITHIN_SEC := 8.0

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("RESTPAIR %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 30.0) -> void:
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


func _text(name: String) -> String:
	return FileAccess.get_file_as_string(_file(name))


## The host's table as text: digest and shot count, then one row per ball.
func _dump() -> String:
	var lines := PackedStringArray(["%d %d" % [rd.table_check(), rd.get("_shot_index")]])
	for b in rd.get_balls():
		lines.append("%d %d %.5f %.5f %.5f" % [b.net_id, 1 if b.retired else 0, b.global_position.x, b.global_position.y, b.global_position.z])
	return "\n".join(lines)


## Worst 3D error of this peer's table against a host dump; INF when a ball or its lifecycle differs, -1 when the digest differs.
func _worst_vs(dump: String) -> float:
	var lines := dump.split("\n")
	var worst := 0.0
	for k in range(1, lines.size()):
		var p := lines[k].split(" ")
		var id := int(p[0])
		var b: Ball = table.sim._by_id[id] if id < table.sim._by_id.size() else null
		if b == null or (1 if b.retired else 0) != int(p[1]):
			return INF
		if not b.retired:
			worst = maxf(worst, b.global_position.distance_to(Vector3(float(p[2]), float(p[3]), float(p[4]))))
	if table.sim._by_id.filter(func(x: Ball) -> bool: return x != null).size() != lines.size() - 1:
		return INF
	return -1.0 if rd.table_check() != int(lines[0].split(" ")[0]) else worst


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
	if role == "host":
		var gl: GameLoop = current_scene.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	if role == "host":
		await _host()
	else:
		await _client()


# ------------------------------------------------------------------ host

## Publishes the host's table as step `n` once it has been at rest a while, then waits for the client's verdict on it.
func _publish(n: int) -> void:
	await _until(func() -> bool: return table.sim.awake == 0 and not rd.shot_in_progress, "table at rest")
	await create_timer(0.7).timeout
	_touch("host_%d" % n, _dump())
	await _until(func() -> bool: return _has("client_%d" % n), "client verdict %d" % n, 40.0)
	print("restpair host step %d: %s" % [n, _text("client_%d" % n)])


func _shot(power: float) -> void:
	await _until(func() -> bool: return table.sim.awake == 0 and not rd.shot_in_progress, "table at rest before a shot")
	rd._set_shooter_rpc.rpc(1)  # the host's Turn, whatever the rotation says
	await create_timer(0.1).timeout
	var cue: Ball = null
	var nearest: Ball = null
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.retired and (nearest == null or b.global_position.distance_to(cue.global_position) < nearest.global_position.distance_to(cue.global_position)):
			nearest = b
	var d := nearest.global_position - cue.global_position
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = power
	intent.shooter_id = 1
	table.sim.request_shot(intent)  # the strike, shot_started_net and shot_in_progress all happen inside this call on the host
	assert(rd.shot_in_progress, "the host's shot was refused")
	await _until(func() -> bool: return not rd.shot_in_progress and table.sim.awake == 0, "shot resolved", 60.0)


func _host() -> void:
	for i in 120:
		await physics_frame
	await _publish(1)  # the rack, at rest on both
	await _shot(0.9)
	await _publish(2)  # a healthy shot
	await _until(func() -> bool: return _has("armed_3"), "client dropping the stream", 40.0)
	await _shot(0.7)
	await _publish(3)  # stream lost, rest frame kept
	await _until(func() -> bool: return _has("armed_4"), "client dropping stream and rest frame", 40.0)
	await _shot(0.9)
	await _publish(4)  # everything lost: the digest and a full state
	await _until(func() -> bool: return _has("armed_5"), "client dropping a flag", 40.0)
	var victim: Ball = null
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.retired:
			victim = b
	victim.pocket(table.pockets.keys()[0])  # a pot (and, 0.4 s later, the retire) the client never heard of
	await _publish(5)
	await _until(func() -> bool: return _has("armed_6"), "client wiped", 40.0)
	await _publish(6)  # a client with no table at all
	await _shot(0.6)
	await _publish(7)
	await _shot(0.9)
	await _publish(8)
	var r0: int = table.sim.reannounced
	var moved: Ball = null
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.retired and b.freeze:
			moved = b
	assert(moved != null, "a frozen ball to nudge")
	moved.global_position += Vector3(0.004, 0.0, -0.003)  # a static body moved by something the net knows nothing about
	await _publish(9)
	assert(table.sim.reannounced > r0, "the host noticed the ball had moved and sent a new rest frame")
	await _until(func() -> bool: return _has("client_done"), "client verdict", 40.0)
	print("RESTPAIR HOST OK")
	quit(0)


# ------------------------------------------------------------------ client

## Waits for the host's step `n` and for this peer's table to equal it; returns how long that took (s), or -1 on a timeout.
func _converge(n: int, within: float) -> float:
	await _until(func() -> bool: return _has("host_%d" % n), "host step %d" % n, 60.0)
	var dump := _text("host_%d" % n)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < within * 1000.0:
		var w := _worst_vs(dump)
		if w >= 0.0 and w <= GATE_M:
			return (Time.get_ticks_msec() - t0) / 1000.0
		await process_frame
	var w2 := _worst_vs(dump)
	printerr("restpair client step %d: worst %s (-1 = digest differs)" % [n, "inf" if is_inf(w2) else "%.3f mm" % (w2 * 1000.0)])
	return -1.0


func _step(n: int, within: float, expect_desync: bool) -> void:
	var d0: int = table.sim.desyncs
	var took := await _converge(n, within)
	var desyncs: int = table.sim.desyncs - d0
	assert(took >= 0.0, "step %d: the client never matched the host" % n)
	if expect_desync:
		assert(desyncs >= 1, "step %d: a table this wrong must be found by the digest (desyncs %d)" % [n, desyncs])
	_touch("client_%d" % n, "matched after %.2f s, desyncs %d" % [took, desyncs])
	print("restpair client step %d: matched after %.2f s, desyncs %d" % [n, took, desyncs])
	assert(took >= 0.0 and took <= within, "step %d took %.2f s" % [n, took])


func _client() -> void:
	await _until(func() -> bool: return table.sim.get_balls().size() > 5, "client balls registered")
	await _step(1, 4.0, false)
	await _step(2, 4.0, false)
	assert(table.sim.desyncs == 0, "a healthy shot is no desync (%d)" % table.sim.desyncs)
	table.sim.debug_drop_events = 100000
	_touch("armed_3")
	await _step(3, 4.0, false)  # the rest frame alone sets the table right (a pot in it would be found by the digest instead)
	table.sim.debug_drop_events = 100000
	table.sim.debug_drop_rest = 1
	_touch("armed_4")
	await _step(4, MEND_WITHIN_SEC, false)  # usually the digest finds it; a later settle frame can mend it first
	table.sim.debug_drop_events = 2  # the POCKETED frame and the RETIRED one
	_touch("armed_5")
	await _step(5, MEND_WITHIN_SEC, true)
	table.sim.debug_drop_events = 0
	rd._clear_balls()  # a late join: no balls, no Round
	rd.set("_round_id", "")
	rd.set("_round_active", false)
	_touch("armed_6")
	await _step(6, MEND_WITHIN_SEC, true)
	var before: int = table.sim.desyncs
	await _step(7, 4.0, false)
	await _step(8, 4.0, false)
	await _step(9, 4.0, false)
	assert(table.sim.desyncs == before, "healthy shots after a mend, and a moved resting ball, are no desync")
	_touch("client_done")
	print("RESTPAIR CLIENT OK")
	quit(0)
