extends SceneTree
# PAIR_TIMEOUT=120
## Two-peer wire meter (06 P49, run through tests/net/pair.sh): the bytes the host really sends to its one client (ENet
## totals, rpc overhead included) while the table idles and across three shots. It asserts nothing about the code under
## test beyond "the client gets the shots": it exists so the same file can be run on a tree before and after a change to the
## net code and the two printed lines compared. Idle includes everything else the host sends (poses, the Round clock).
##   tests/net/pair.sh tests/sync/wire_pair_probe.gd
## Prints `wire: idle ... B/s` and `wire: shot ... B` lines, then `WIREPAIR HOST OK` / `WIREPAIR CLIENT OK`.

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


func _until(cond: Callable, what: String, sec := 30.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			printerr("WIREPAIR %s FAIL: timeout waiting for %s" % [role.to_upper(), what])
			quit(1)
			await create_timer(60).timeout


func _sent() -> float:
	var peer := root.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	return peer.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)


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
		await _until(func() -> bool: return FileAccess.file_exists(OS.get_environment("PAIR_DIR") + "/host_done"), "host", 100.0)
		print("WIREPAIR CLIENT OK")
		quit(0)


func _host() -> void:
	for i in 180:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	await create_timer(2.0).timeout
	_sent()
	var t0 := Time.get_ticks_msec()
	await create_timer(10.0).timeout
	var idle := _sent()
	print("wire: idle %.0f B/s (%d s)" % [idle / ((Time.get_ticks_msec() - t0) / 1000.0), roundi((Time.get_ticks_msec() - t0) / 1000.0)])
	for k in 3:
		await _until(func() -> bool: return table.sim.awake == 0 and not rd.shot_in_progress, "table at rest")
		rd._set_shooter_rpc.rpc(1)
		await create_timer(0.3).timeout
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
		intent.power = 0.9
		intent.shooter_id = 1
		_sent()
		var s0 := Time.get_ticks_msec()
		table.sim.request_shot(intent)
		await _until(func() -> bool: return table.sim.awake == 0 and not rd.shot_in_progress, "shot resolved", 60.0)
		await create_timer(1.0).timeout
		var el := (Time.get_ticks_msec() - s0) / 1000.0
		var b := _sent()
		print("wire: shot %d  %.0f B in %.1f s (incl. %.0f B/s idle) -> %.0f B net of idle" % [k + 1, b, el, idle / 10.0, b - idle / 10.0 * el])
	var f := FileAccess.open(OS.get_environment("PAIR_DIR") + "/host_done", FileAccess.WRITE)
	f.store_string("1")
	f.close()
	print("WIREPAIR HOST OK")
	quit(0)
