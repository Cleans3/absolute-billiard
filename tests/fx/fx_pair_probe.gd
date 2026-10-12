extends SceneTree
# PAIR_TIMEOUT=120

## Two-peer chaos FX probe (run through tests/net/pair.sh): the host places the combo shot of round_probe (cue ball splits two
## touching balls, both go in opposite corners), the client shoots it, and both peers must pop the same FX: one cue strike,
## the splitting hits, two pots, a COMBO x2 and one trick celebration. The client gets no contacts, only the host's event
## stream through PhysicsSim.frame_received, so its FX land late by the playback delay (04 §2.4) and not before.
##   flock /tmp/ab-pair.lock bash tests/net/pair.sh tests/fx/fx_pair_probe.gd
## Prints `FXPAIR HOST OK` / `FXPAIR CLIENT OK`.

const MIN_PLAYBACK_LAG := 0.05  # s: the client's strike pop trails the shot start by about INTERP_DELAY_SEC

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var fx: ImpactFx
var counts := {}
var _started_msec := 0
var _kick_msec := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("FXPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _world(spot: Vector2, b: Ball) -> Vector3:
	return table.to_global(Vector3(spot.x, table.cloth_y() + b.radius, spot.y))


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
	fx = current_scene.get_node("ImpactFx")
	fx.fx_fired.connect(func(kind: StringName, _s: float) -> void:
		counts[kind] = int(counts.get(kind, 0)) + 1
		if kind == &"kick" and _kick_msec == 0:
			_kick_msec = Time.get_ticks_msec())
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _started_msec = Time.get_ticks_msec())
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
	if not table.sim.has_signal(&"frame_received"):
		print("note: PhysicsSim.frame_received is missing on the host; only the client needs it")
	var client_id := int(nm.get_roster()[1].peer_id)
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	var cue: Ball = null
	var pair: Array[Ball] = []
	var rest: Array[Ball] = []
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
		elif rd.value_of(b.ball_type) > 0 and pair.size() < 2:
			pair.append(b)
		else:
			rest.append(b)
	var r := table.spec.ball_radius_m
	cue.restore(_world(Vector2(-1.4, 0.0), cue))
	pair[0].restore(_world(Vector2(1.0, r + 0.002), pair[0]))
	pair[1].restore(_world(Vector2(1.0, -(r + 0.002)), pair[1]))
	for b in rest:
		b.retire()
		b.global_position = _world(Vector2.ZERO, b)
	for i in 240:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "placed table at rest")
	_touch("placed")
	await create_timer(1.0).timeout  # the client applies the lifecycle events
	rd._set_shooter_rpc.rpc(client_id)
	await table.sim.shot_started_net
	await rd.shot_ended
	await create_timer(1.5).timeout
	_touch("host_fx", JSON.stringify(counts))
	print("fxpair: host fired %s" % str(counts))
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict")
	if int(counts.get(&"pot", 0)) != 2 or int(counts.get(&"combo", 0)) != 1 or int(counts.get(&"trick", 0)) != 1:
		_fail("host FX: want 2 pots, 1 combo, 1 trick, got %s" % str(counts))
	print("FXPAIR HOST OK")
	quit(0)


func _client() -> void:
	var me := root.multiplayer.get_unique_id()
	if not table.sim.has_signal(&"frame_received"):
		_fail("PhysicsSim.frame_received is missing: ImpactFx has no client contact stream (Q#fx-1)")
		return
	await _until(func() -> bool: return FileAccess.file_exists(_file("placed")), "host placed the shot")
	await _until(func() -> bool: return rd.current_shooter_id == me, "set_shooter to me")
	await create_timer(0.3).timeout
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 0.7
	table.sim.request_shot(intent)
	await _until(func() -> bool: return _started_msec > 0, "shot_started_net")
	await rd.shot_ended
	await create_timer(1.5).timeout
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_fx")), "host's FX counts")
	var host: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_file("host_fx")))
	print("fxpair: client fired %s | host fired %s" % [str(counts), str(host)])
	for kind in [&"pot", &"combo", &"trick", &"kick"]:
		if int(counts.get(kind, 0)) != int(host.get(String(kind), 0)):
			_fail("%s: client %d vs host %d" % [kind, int(counts.get(kind, 0)), int(host.get(String(kind), 0))])
			return
	if int(counts.get(&"pot", 0)) != 2 or int(counts.get(&"combo", 0)) != 1 or int(counts.get(&"trick", 0)) != 1 or int(counts.get(&"kick", 0)) != 1:
		_fail("client FX: want 2 pots, 1 combo, 1 trick, 1 kick, got %s" % str(counts))
		return
	if absi(int(counts.get(&"ball", 0)) - int(host.get("ball", 0))) > 2 or int(counts.get(&"ball", 0)) < 2:
		_fail("ball hits: client %d vs host %d" % [int(counts.get(&"ball", 0)), int(host.get("ball", 0))])
		return
	var lag := (_kick_msec - _started_msec) / 1000.0
	print("fxpair: the client's strike pop trailed the shot start by %.0f ms" % (lag * 1000.0))
	if lag < MIN_PLAYBACK_LAG:
		_fail("the strike pop fired %.0f ms after shot start: not gated on the playback clock" % (lag * 1000.0))
		return
	_touch("client_done")
	print("FXPAIR CLIENT OK")
	quit(0)
