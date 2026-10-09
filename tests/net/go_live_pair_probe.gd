extends SceneTree
# PAIR_TIMEOUT=150
## GO LIVE over the network (REQ#adhoc-1010a:flow A1, run through tests/net/pair.sh). Between Rounds nobody has a Start
## button; the Round starts when the crew has pressed the pedestal.
##   1. the client presses: 1/2 ready on both peers and the pedestal says so, the Round does not start; a second press
##      un-readies; pressed again, then the host presses and Round 1 starts on both peers with the set cleared.
##      In the live Round a press is refused (`not_intermission`) and a cooling-down interaction names its seconds.
##   2. Intermission 2: the client's app goes to the background; the host's press alone starts Round 2 (nobody waits on a
##      frozen phone); the client resumes and its mirror matches the host's.
##   3. Intermission 3: the host presses, the client leaves: the departure alone starts Round 3.
## Also (A4): both peers saw the host's load count go 1 → 2 under the loading screen, which is gone once they stand in the bar.
##   tests/net/pair.sh tests/net/go_live_pair_probe.gd
## Prints `GOLIVE HOST OK` / `GOLIVE CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var gl: GameLoop
var world: WorldInteractions
var prop: Interactable
var pedestal: GoLivePedestal
var client_id := 0
var _at := Bar.GO_LIVE_AT  # host: where the host's reach test thinks every player stands
var _rejected: Array = []  # [kind, reason, wait_sec]
var _loads: Array = []  # per loading_state: [peers loaded, the loading screen is up]


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("GOLIVE %s FAIL: %s" % [role.to_upper(), msg])
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


func _flag(name: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string("1")
	f.close()


func _wait_flag(name: String, sec := 30.0) -> void:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, sec)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


## ready / waiting as this peer sees them, as sorted arrays.
func _sets() -> Array:
	var r := Array(gl.ready_peers)
	var w := Array(gl.waiting_peers)
	r.sort()
	w.sort()
	return [r, w]


func _sees(ready_ids: Array, waiting_ids: Array) -> bool:
	return _sets() == [ready_ids, waiting_ids]


func _run() -> void:
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	SaveManager.root = dir
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	nm.loading_changed.connect(func() -> void: _loads.append([nm.loading_done.size(), root.get_node_or_null("LoadingScreen") != null]))
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
	gl = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	client_id = int(nm.get_roster()[1].peer_id)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _check(_loads == [[1, true], [2, true]], "the load count went 1 → 2 under the loading screen: %s" % [_loads])
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen ends once the local player stands in the bar")
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"go_live":
			prop = n
	for n in level.get_node("Bar").get_children():
		if n is GoLivePedestal:
			pedestal = n
	await _check(prop != null and pedestal != null, "the go_live prop and its pedestal exist on this peer")
	await _check(prop.global_position.is_equal_approx(Bar.GO_LIVE_AT), "the prop sits at the contract spot")
	world.interaction_rejected.connect(func(k: StringName, r: StringName) -> void: _rejected.append([k, r, world.last_wait_sec]))
	if role == "host":
		world.player_position_source = func(_id: int) -> Vector3: return _at  # the spawn row is 3 m from the pedestal
		level.get_node("EconomyManager").add_cash(200, &"probe")  # chalk_the_cue costs $10
	await _cycle_toggle()
	await _cycle_away()
	await _cycle_drop()


func _status() -> String:
	return pedestal.get_node("Status").text


## 1: press, un-press, press, host press → Round 1.
func _cycle_toggle() -> void:
	await _check(gl.round_index == 0 and _sees([], [1, client_id]), "Intermission 1 starts with nobody ready (%s)" % [_sets()])
	await _check("Ready 0/2" in _status() and "Waiting on" in _status(), "the pedestal shows 0/2 and who it waits on: " + _status())
	if role == "client":
		prop.try_use()
	await _until(func() -> bool: return _sees([client_id], [1]), "1/2 ready: the client alone")
	await _check("Ready 1/2" in _status(), "pedestal text on this peer: " + _status())
	await create_timer(0.8).timeout
	await _check(gl.phase == GameLoop.Phase.INTERMISSION and gl.round_index == 0, "one of two pressed: the Round did not start")
	if role == "host":
		_flag("c1_seen_ready")
	else:
		await _wait_flag("c1_seen_ready")
		await _check(prop.prompt.begins_with("Ready 1/2"), "the presser's prompt says it can be cancelled: " + prop.prompt)
		prop.try_use()  # un-ready
	await _until(func() -> bool: return _sees([], [1, client_id]), "the second press un-readies")
	if role == "host":
		_flag("c1_seen_unready")
	else:
		await _wait_flag("c1_seen_unready")
		prop.try_use()
	if role == "host":  # the client's third press: the host presses the moment it sees it, so only the host can catch 1/2
		await _until(func() -> bool: return _sees([client_id], [1]), "the client is ready again")
		prop.try_use()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and gl.round_index == 1, "Round 1 live on this peer", 20.0)
	await _until(func() -> bool: return _sees([], []), "the ready set is cleared when the Round starts")
	# a press in the live Round is refused, and says why
	if role == "client":
		prop.try_use()
		await _until(func() -> bool: return _rejected.size() >= 1, "the refusal")
		await _check(_rejected[0][0] == &"go_live" and _rejected[0][1] == &"not_intermission", "refusal: %s" % [_rejected[0]])
		await _check(WaitText.interaction(_rejected[0][0], _rejected[0][1]) == "GO LIVE only works between Rounds", "refusal text")
		# a cooling-down interaction names its seconds (the host reads our reach from the override, not the spawn row)
	if role == "host":
		_at = Vector3(2.4, 0.0, -1.2)  # next to chalk_the_cue
		_flag("c1_round_live")
	else:
		await _wait_flag("c1_round_live")
		world.request(&"chalk_the_cue", 0, {})
		await create_timer(0.6).timeout
		world.request(&"chalk_the_cue", 0, {})
		await _until(func() -> bool: return _rejected.size() >= 2, "the cooldown refusal")
		var cool: Array = _rejected[1]
		await _check(cool[1] == &"cooldown" and cool[2] > 15.0 and cool[2] <= 20.0, "cooldown refusal carries the remaining seconds: %s" % [cool])
		await _check("s left" in WaitText.interaction(cool[0], cool[1], cool[2]) and "Chalk the cue" in WaitText.interaction(cool[0], cool[1], cool[2]), "text: " + WaitText.interaction(cool[0], cool[1], cool[2]))
		_flag("c1_cooldown_seen")
	if role == "host":
		await _wait_flag("c1_cooldown_seen")
		_at = Bar.GO_LIVE_AT
		gl._end_round(&"timer")


## 2: the client's app is in the background; the host alone starts Round 2.
func _cycle_away() -> void:
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION and gl.round_index == 1, "Intermission 2", 20.0)
	await _until(func() -> bool: return _sees([], [1, client_id]), "Intermission 2 waits on both")
	if role == "client":
		nm.set_backgrounded(true)  # what NOTIFICATION_APPLICATION_PAUSED does
		_flag("c2_client_away")
	else:
		await _wait_flag("c2_client_away")
		await _until(func() -> bool: return nm.is_peer_away(client_id), "the host knows the client is in the background")
		await _until(func() -> bool: return _sees([], [1]), "nobody waits on the backgrounded client")
		prop.try_use()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and gl.round_index == 2, "Round 2 live (this peer)", 20.0)
	if role == "client":
		nm.set_backgrounded(false)
		await _until(func() -> bool: return _sees([], []), "back from the background: the mirror matches")
	else:
		await _until(func() -> bool: return not nm.is_peer_away(client_id), "the host knows the client is back")
		_flag("c2_done")
		gl._end_round(&"timer")


## 3: the host presses, the client leaves: the departure starts Round 3.
func _cycle_drop() -> void:
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION and gl.round_index == 2, "Intermission 3", 20.0)
	await _until(func() -> bool: return _sees([], [1, client_id]), "Intermission 3 waits on both")
	if role == "host":
		await _wait_flag("c2_done")
		await _wait_flag("c3_client_saw")  # the host's press would clear the client's chance to see "waiting on both"
		prop.try_use()
		await _until(func() -> bool: return _sees([1], [client_id]), "the host is ready, the client is not")
		await create_timer(0.8).timeout
		await _check(gl.phase == GameLoop.Phase.INTERMISSION, "waiting on the client: the Round did not start")
		_flag("c3_host_pressed")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and gl.round_index == 3, "the client's departure starts Round 3", 20.0)
		print("GOLIVE HOST OK")
		quit(0)
	else:
		_flag("c3_client_saw")
		await _wait_flag("c3_host_pressed")
		await _until(func() -> bool: return _sees([1], [client_id]), "the mirror shows the host ready")
		print("GOLIVE CLIENT OK")
		nm.leave()
		await create_timer(0.3).timeout
		quit(0)
