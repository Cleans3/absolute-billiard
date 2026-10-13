extends SceneTree
# PAIR_TIMEOUT=150
## The Round's set-up and clean-up on two peers (docs/plan/01 §3, 04 §5: no new rpc; 06 P33 A4, adhoc-1013c W5), run through tests/net/pair.sh.
## Both peers stage (RoundDirector.skip_staging off). The host starts Round 1: the client's pushed rack arrives hidden, every ball is shown by its
## own clock in net_id order within 0.3 s of when the host shows it, both finish inside the 5 s budget, the Round clock stood still on both, and
## nothing could be struck meanwhile. The host then ends the Round: both clear the table inside the 3 s budget, the client starting within half a
## second of the host, and both are left with no balls.
##   tests/net/pair.sh tests/world/staging_pair_probe.gd
## Prints `STAGINGPAIR HOST OK` / `STAGINGPAIR CLIENT OK`.

const SKEW_SEC := 0.3        ## how far apart the two peers' picture of the same ball may be
const START_SKEW_SEC := 0.6  ## a client starts after the host by network latency + the playback delay, never before it by much

var role := ""
var port := 0
var nm: Node
var level: Node
var rd: RoundDirector
var gl: GameLoop
var _cycles: Array[Dictionary] = []   # one per staging_changed(true) .. (false)
var _open: Dictionary = {}


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("STAGINGPAIR %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fail(what)
		await create_timer(60).timeout


func _until(cond: Callable, what: String, sec := 30.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _file(name: String) -> String:
	return OS.get_environment("PAIR_DIR") + "/" + name


func _write(name: String, text: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _on_staging(on: bool) -> void:
	if on:
		var all_hidden := true
		for b in rd.get_balls():
			all_hidden = all_hidden and not b.visible
		var stager := level.get_node("Staging") as RoundStaging
		_open = {kind = stager.kind, unix = Time.get_unix_time_from_system(), ms = Time.get_ticks_msec(), seen = {}, hidden = all_hidden,
				time_left = gl.time_left, struck = not rd.can_strike(_cue()), balls = rd.get_balls().size()}
	elif not _open.is_empty():
		_open.end_ms = Time.get_ticks_msec()
		_open.time_left_end = gl.time_left
		_cycles.append(_open)
		_open = {}


func _sample() -> void:
	if _open.is_empty():
		return
	var rel := (Time.get_ticks_msec() - int(_open.ms)) / 1000.0
	for b in rd.get_balls():
		if b.visible and not _open.seen.has(b.net_id):
			_open.seen[b.net_id] = rel


func _cue() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


func _dump(c: Dictionary) -> String:
	var lines := PackedStringArray(["%s %.4f %.3f" % [c.kind, c.unix, (int(c.end_ms) - int(c.ms)) / 1000.0]])
	for id in c.seen:
		lines.append("%d %.3f" % [id, c.seen[id]])
	return "\n".join(lines)


func _run() -> void:
	RoundDirector.skip_staging = false  # the headless default is to skip: this probe is about the pictures
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
	gl = level.get_node("GameLoop")
	rd.staging_changed.connect(_on_staging)
	process_frame.connect(_sample)
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_ready")), "the client in the bar")
	await create_timer(0.5).timeout
	gl.advance()  # Round 1: the rack is pushed, hidden, and the saucer beams it in
	await _until(func() -> bool: return _cycles.size() == 1, "the host's set-up to play", 12.0)
	var c := _cycles[0]
	await _check(c.kind == RoundStaging.KIND_SETUP and c.hidden and c.struck, "host: a staged start, every ball hidden, nothing strikable")
	await _check(absf(float(c.time_left) - float(c.time_left_end)) < 0.001, "host: the Round clock stood still during the set-up")
	await _check(float(c.end_ms - c.ms) / 1000.0 <= StagingPlan.SETUP_MAX_SEC + 0.4, "host: set-up inside the budget")
	await _check(c.seen.size() == int(c.balls), "host: every ball was shown (%d of %d)" % [c.seen.size(), c.balls])
	_write("host_setup", _dump(c))
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_setup_done")), "the client's set-up verdict", 30.0)
	await create_timer(0.3).timeout
	gl._end_round(&"timer")  # the Round ends: the host clears the table, the client is told by round_state
	await _until(func() -> bool: return _cycles.size() == 2, "the host's clean-up to play", 12.0)
	var k := _cycles[1]
	await _check(k.kind == RoundStaging.KIND_CLEANUP and k.hidden and k.struck, "host: the clean-up hides the real balls and nothing can be struck")
	await _check(float(k.end_ms - k.ms) / 1000.0 <= StagingPlan.CLEANUP_MAX_SEC + 0.4, "host: clean-up inside the budget")
	await _check(rd.get_balls().is_empty() and not rd.staging, "host: the table is clear after the clean-up")
	_write("host_cleanup", _dump(k))
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "the client's verdict", 30.0)
	print("STAGINGPAIR HOST OK")
	quit(0)


func _client() -> void:
	_write("client_ready", "1")
	await _until(func() -> bool: return _cycles.size() == 1, "the client's set-up to play", 20.0)
	var c := _cycles[0]
	await _check(c.kind == RoundStaging.KIND_SETUP and c.hidden and c.struck, "client: the pushed rack arrives hidden, staging, nothing strikable")
	await _check(absf(float(c.time_left) - float(c.time_left_end)) < 0.001, "client: the Round clock stood still during the set-up")
	await _check(float(c.end_ms - c.ms) / 1000.0 <= StagingPlan.SETUP_MAX_SEC + 0.4, "client: set-up inside the budget")
	await _check(c.seen.size() == int(c.balls), "client: every ball was shown (%d of %d)" % [c.seen.size(), c.balls])
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_setup")), "the host's set-up record")
	var lines := FileAccess.get_file_as_string(_file("host_setup")).split("\n")
	var head := lines[0].split(" ")
	var host_dur := float(head[2])
	var client_dur := float(c.end_ms - c.ms) / 1000.0
	await _check(absf(host_dur - client_dur) < SKEW_SEC, "the two set-ups last about the same: host %.2f s, client %.2f s" % [host_dur, client_dur])
	var worst := 0.0
	var matched := 0
	for i in range(1, lines.size()):
		var p := lines[i].split(" ")
		if p.size() < 2 or not c.seen.has(int(p[0])):
			continue
		worst = maxf(worst, absf(float(p[1]) - float(c.seen[int(p[0])])))
		matched += 1
	print("stagingpair: %d balls matched, worst reveal skew %.3f s, durations %.2f / %.2f" % [matched, worst, host_dur, client_dur])
	await _check(matched == int(c.balls), "every ball is on both records (%d of %d)" % [matched, c.balls])
	await _check(worst < SKEW_SEC, "each ball is shown within %.1f s of the host's showing it: worst %.3f s" % [SKEW_SEC, worst])
	var ids: Array = c.seen.keys()
	ids.sort()
	var ordered := true
	for i in range(1, ids.size()):
		ordered = ordered and float(c.seen[ids[i]]) >= float(c.seen[ids[i - 1]]) - 0.05
	await _check(ordered, "the client shows the rack in net_id order")
	await _check(float(c.unix) - float(head[1]) > -0.1 and float(c.unix) - float(head[1]) < START_SKEW_SEC, "the client's set-up started with the host's: %.3f s later" % (float(c.unix) - float(head[1])))
	_write("client_setup_done", "1")
	await _until(func() -> bool: return _cycles.size() == 2, "the client's clean-up to play", 20.0)
	var k := _cycles[1]
	await _check(k.kind == RoundStaging.KIND_CLEANUP and k.hidden, "client: the clean-up hides the real balls")
	await _check(float(k.end_ms - k.ms) / 1000.0 <= StagingPlan.CLEANUP_MAX_SEC + 0.4, "client: clean-up inside the budget")
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_cleanup")), "the host's clean-up record")
	var hk := FileAccess.get_file_as_string(_file("host_cleanup")).split("\n")[0].split(" ")
	var late := float(k.unix) - float(hk[1])
	await _check(late > -0.1 and late < START_SKEW_SEC, "the client cleared the table within %.1f s of the host: %.3f s later" % [START_SKEW_SEC, late])
	await _check(rd.get_balls().is_empty() and not rd.staging, "client: the table is clear after the clean-up")
	_write("client_done", "1")
	print("STAGINGPAIR CLIENT OK")
	quit(0)
