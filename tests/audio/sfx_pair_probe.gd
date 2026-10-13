extends SceneTree
# PAIR_TIMEOUT=150
## Sound and music across two peers (docs/plan/07 §8, 06 P54-P55), through tests/net/pair.sh.
##   1. Music: the host starts it, the client hears the same track at the same second; the CLIENT presses the jukebox and the host's
##      skip reaches both; the 3 s gate holds (a second press does nothing); a client that missed the state asks and lands on the
##      host's second (the resume path); the host skipping reaches the client.
##   2. Table sounds on a CLIENT come from playback events: the client takes a shot, each peer makes exactly one sound per ImpactFx
##      event it fired, the strike sound trails the shot start by the playback delay on the client, and the two peers' counts agree.
##   tests/net/pair.sh tests/audio/sfx_pair_probe.gd        prints SFXPAIR HOST OK / SFXPAIR CLIENT OK
## NetManager is an autoload, which a `-s` script cannot name at compile time: it is read from the root.

const MIN_PLAYBACK_LAG := 0.06
const AT_JUKEBOX := Vector3(6.3, 0.05, 5.8)

var role := ""
var port := 0
var nm: Node
var sfx: Node
var level: Node
var box: JukeboxPlayer
var rd: RoundDirector
var table: Table
var fx: ImpactFx
var counts := {}
var _kick_msec := 0
var _started_msec := 0
var _sound_at_kick := -1


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("SFXPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _put(name: String, text := "1") -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(name: String) -> String:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, 60.0)
	await create_timer(0.1).timeout
	return FileAccess.get_file_as_string(_file(name))


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _count(prefix: String) -> int:
	var n := 0
	for k: StringName in sfx.stats:
		if String(k).begins_with(prefix):
			n += int(sfx.stats[k])
	return n


## Both peers write their playhead at a rendezvous and compare: the same track, within `tol` seconds.
func _agree(tag: String, tol := 0.7) -> void:
	_put("go_" + tag + "_" + role)
	await _read("go_" + tag + "_" + ("client" if role == "host" else "host"))
	var p := box.playhead()
	_put("ph_" + tag + "_" + role, JSON.stringify({track = p.track, offset = p.offset}))
	var other: Dictionary = JSON.parse_string(await _read("ph_" + tag + "_" + ("client" if role == "host" else "host")))
	await _check(int(p.track) == int(other.track) and absf(float(p.offset) - float(other.offset)) < tol, "%s: the peers are on the same track and second (here %d at %.2f, there %d at %.2f)" % [tag, int(p.track), float(p.offset), int(other.track), float(other.offset)])


func _run() -> void:
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	SaveManager.root = dir
	nm = root.get_node("NetManager")
	sfx = root.get_node("Sfx")
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
	var gl: GameLoop = level.get_node("GameLoop")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	rd = level.get_node("RoundDirector")
	table = level.get_node("Table")
	fx = level.get_node("ImpactFx")
	box = level.get_node("Bar/Jukebox")
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen to end")
	if role == "host":
		world.player_position_source = func(_id: int) -> Vector3: return AT_JUKEBOX  # everyone stands at the jukebox
	await _music()
	await _table(gl)
	_put("done_" + role)
	await _read("done_" + ("client" if role == "host" else "host"))
	print("SFXPAIR %s OK" % role.to_upper())
	quit()


func _music() -> void:
	var n := JukeboxPlayer.TRACKS.size()
	await _until(func() -> bool: return box.track >= 0, "the music to start on this peer", 40.0)
	await _agree("start")
	if role == "host":
		_put("t0", str(box.track))
	var t0 := int(await _read("t0"))
	if role == "client":  # (the host's own track moves the moment the client presses: only the client can check it here)
		await _check(box.track == t0, "both peers start on the host's track %d (here %d)" % [t0, box.track])
		box.press()
	# the client presses: the host skips for everyone
	await _until(func() -> bool: return box.track == (t0 + 1) % n, "the client's press to skip the track on this peer")
	await _agree("skip")
	var near: AudioStreamPlayer3D = box.get(&"_near")
	await create_timer(0.5).timeout
	await _check(near.playing and near.stream == (load(JukeboxPlayer.TRACKS[box.track].path) as AudioStream), "the new track is playing here")
	# the gate: a press inside 3 s changes nothing
	if role == "client":
		box.set(&"_next_press_msec", 0)  # the client's own gate is off: it is the host's that must hold
		box.press()
	await create_timer(1.0).timeout
	await _check(box.track == (t0 + 1) % n, "a second press inside 3 s did nothing (track %d)" % box.track)
	# a client that missed the state asks (the resume path) and lands on the host's second
	if role == "client":
		box.jukebox_state((t0 + 3) % n, 40.0)
		await _check(int(box.playhead().track) == (t0 + 3) % n, "the client is now deliberately wrong")
		box.call(&"_ask_host")
	await _until(func() -> bool: return box.track == (t0 + 1) % n, "the answer to a state request", 10.0)
	await _agree("resume")
	# the host skips (past its gate): the client follows
	await create_timer(3.0).timeout
	if role == "host":
		await _check(box.skip(1), "the host's own press skips past its gate")
	await _until(func() -> bool: return box.track == (t0 + 2) % n, "the host's skip to reach this peer")
	await _agree("hostskip")


func _table(gl: GameLoop) -> void:
	fx.fx_fired.connect(func(kind: StringName, _s: float) -> void:
		counts[kind] = int(counts.get(kind, 0)) + 1
		if kind == &"kick" and _kick_msec == 0:
			_kick_msec = Time.get_ticks_msec()
			_sound_at_kick = int(sfx.stats.get(&"cue_tip", 0)))  # Sfx connected first: its sound has been requested by now
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _started_msec = Time.get_ticks_msec())
	if role == "host":
		gl.advance()
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	await _until(func() -> bool: return not rd.staging, "staging to end", 30.0)
	if role == "host":
		var client_id := int(nm.get_roster()[1].peer_id)
		await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
		table.sim.stat_source = func(_stat: StringName, _peer: int, base: float) -> float: return base
		rd._set_shooter_rpc.rpc(client_id)
		_put("ready")
		await table.sim.shot_started_net
		await rd.shot_ended
	else:
		await _read("ready")
		var me := root.multiplayer.get_unique_id()
		await _until(func() -> bool: return rd.current_shooter_id == me, "set_shooter to me")
		await create_timer(0.3).timeout
		var cue: Ball = null
		var target: Ball = null
		for b in rd.get_balls():
			if b.is_cue_ball:
				cue = b
		for b in rd.get_balls():
			if not b.is_cue_ball and (target == null or b.global_position.distance_to(cue.global_position) < target.global_position.distance_to(cue.global_position)):
				target = b
		var d := target.global_position - cue.global_position
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2(d.x, d.z).normalized()
		intent.power = 0.8
		table.sim.request_shot(intent)
		await _until(func() -> bool: return _started_msec > 0, "shot_started_net")
		await rd.shot_ended
	await create_timer(1.5).timeout
	# one sound per ImpactFx event, on this peer
	await _check(int(counts.get(&"kick", 0)) == 1 and _count("cue_tip") == 1, "one strike, one cue sound: %s" % str(counts))
	await _check(_count("clack_") == int(counts.get(&"ball", 0)) and int(counts.get(&"ball", 0)) >= 1, "every ball hit made exactly one clack here (%d of %d)" % [_count("clack_"), int(counts.get(&"ball", 0))])
	await _check(_count("rail_") == int(counts.get(&"rail", 0)), "every cushion hit made exactly one rail sound here (%d of %d)" % [_count("rail_"), int(counts.get(&"rail", 0))])
	await _check(_count("pocket_drop") == int(counts.get(&"pot", 0)) + int(counts.get(&"scratch", 0)) + int(counts.get(&"penalty", 0)), "every pocketed ball dropped once here")
	_put("fx_" + role, JSON.stringify(counts))
	var other: Dictionary = JSON.parse_string(await _read("fx_" + ("client" if role == "host" else "host")))
	var tol := maxi(3, int(0.25 * float(counts.get(&"ball", 0))))
	await _check(absi(int(counts.get(&"ball", 0)) - int(other.get("ball", 0))) <= tol and absi(int(counts.get(&"rail", 0)) - int(other.get("rail", 0))) <= tol + 2, "the peers heard about the same shot: here %s there %s" % [str(counts), str(other)])
	if role == "client":
		var lag := float(_kick_msec - _started_msec) / 1000.0
		await _check(lag >= MIN_PLAYBACK_LAG and _sound_at_kick == 1, "the strike sound trailed the shot start by %.0f ms: gated on the playback clock" % (lag * 1000.0))
		print("sfxpair: the client's strike sound trailed the shot start by %.0f ms; client %s host %s" % [lag * 1000.0, str(counts), str(other)])
