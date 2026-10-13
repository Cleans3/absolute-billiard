extends SceneTree
# PAIR_TIMEOUT=150
## The first-time coach across two peers (adhoc-1014a V2, 06 P44), run through tests/net/pair.sh. Each peer keeps its own seen flag.
##   1. Between Rounds both peers get the GO LIVE hint; the client presses, so its hint goes while the host's stays; the host presses.
##   2. The host shoots first: its coach walks WALK, AIM, SPIN, POWER on its own signals and ends on its first shot. The client's
##      coach says WAIT and its turn line names the host ("<host> is shooting").
##   3. The swap: the client's coach runs the same steps for its own first shot; the host's turn line now names the client.
##   tests/net/pair.sh tests/ui/coach_pair_probe.gd
## Prints `COACH PAIR HOST OK` / `COACH PAIR CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var gl: GameLoop
var rd: RoundDirector
var world: WorldInteractions
var hud: Control
var coach: Coach
var player: Player
var prop: Interactable
var pedestal: GoLivePedestal
var client_id := 0
var host_name := ""
var client_name := ""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("COACH PAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _flag(name: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string("1")
	f.close()


func _wait_flag(name: String, sec := 60.0) -> void:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, sec)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


func _stand_by_cue_ball() -> void:
	var b := _cue_ball()
	player.global_position = Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


func _run() -> void:
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/checkpoints")
	SaveManager.root = dir
	Coach.enabled = true
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
	gl = level.get_node("GameLoop")
	rd = level.get_node("RoundDirector")
	world = level.get_node("WorldInteractions")
	hud = level.get_node("UILayer/HUD")
	coach = hud.coach
	client_id = int(nm.get_roster()[1].peer_id)
	host_name = String(nm.get_roster()[0].name)
	client_name = String(nm.get_roster()[1].name)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen ends")
	await _until(func() -> bool: return level.get_node("PlayerSpawner").get_local_player() != null, "the local player")
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"go_live":
			prop = n
	pedestal = get_first_node_in_group(&"go_live_pedestal") as GoLivePedestal
	await _check(prop != null and pedestal != null, "the go_live prop and its pedestal exist on this peer")
	if role == "host":
		world.player_position_source = func(_id: int) -> Vector3: return Bar.GO_LIVE_AT  # the spawn row is 3 m from the pedestal
	await _go_live()
	await _first_shots()
	print("COACH PAIR %s OK" % role.to_upper())
	quit(0)


## 1: both get the hint; the client readies, its hint goes, the host's stays; the host readies and the Round starts.
func _go_live() -> void:
	await _check(Coach.enabled and not SaveManager.coach_seen(), "this peer's profile has not seen the coach")
	await _check(coach.step == Coach.Step.GO_LIVE and coach._card.visible and pedestal._hint != null and pedestal._hint.visible, "GO LIVE hint up on this peer (step %d)" % coach.step)
	if role == "client":
		prop.try_use()
		await _until(func() -> bool: return gl.ready_peers.has(client_id), "this peer's ready")
		await _until(func() -> bool: return coach.step == Coach.Step.OFF, "the client's hint goes once it is ready")
		await _check(not pedestal._hint.visible and not coach._card.visible, "client: hint and card hidden")
		_flag("c_ready")
	else:
		await _wait_flag("c_ready")
		await _until(func() -> bool: return gl.ready_peers.has(client_id), "the client's ready reaches the host")
		await _check(coach.step == Coach.Step.GO_LIVE and pedestal._hint.visible, "host: the client being ready does not hide the host's own hint")
		prop.try_use()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE, "Round 1 live", 40.0)
	await _until(func() -> bool: return not gl.is_staging() and level.get_node("Table").sim.awake == 0, "the rack at rest")
	await _check(not pedestal._hint.visible, "the hint is gone in the live Round")


## 2 and 3: the host shoots first; the client waits, then the swap.
func _first_shots() -> void:
	await _check(rd.current_shooter_id == 1, "the host shoots first")
	if role == "host":
		await _check(coach.step == Coach.Step.WALK and hud._turn.text == "Your turn", "host: step WALK and 'Your turn' ('%s')" % hud._turn.text)
		await _shoot_through_the_steps()
		await _check(coach.done and SaveManager.coach_seen(), "host: finished after its first shot")
		_flag("h_fired")
		await _until(func() -> bool: return rd.current_shooter_id == client_id, "the shot passes to the client", 60.0)
		await _check(coach.step == Coach.Step.OFF and hud._turn.text == "%s is shooting" % client_name, "host: coach done; turn line names the client ('%s')" % hud._turn.text)
		await _wait_flag("c_fired")
	else:
		await _check(coach.step == Coach.Step.WAIT and coach._body.text.contains(host_name) and coach._body.text.contains("Wait for your turn"), "client: step WAIT naming the host: %s" % coach._body.text)
		await _check(hud._turn.visible and hud._turn.text == "%s is shooting" % host_name, "client: turn line names the host ('%s')" % hud._turn.text)
		await _wait_flag("h_fired")
		await _until(func() -> bool: return rd.current_shooter_id == client_id, "the shot passes to the client", 60.0)
		await _until(func() -> bool: return level.get_node("Table").sim.awake == 0 and not rd.shot_in_progress, "the table at rest", 60.0)
		await _check(coach.step == Coach.Step.WALK and hud._turn.text == "Your turn", "client, after the swap: step WALK and 'Your turn' (step %d, '%s')" % [coach.step, hud._turn.text])
		await _check(not SaveManager.coach_seen(), "client: still not seen before its own shot")
		await _shoot_through_the_steps()
		await _check(coach.done and SaveManager.coach_seen(), "client: finished after its first shot")
		_flag("c_fired")
	await create_timer(0.5).timeout


func _shoot_through_the_steps() -> void:
	var cue := player.cue
	await _until(func() -> bool: return player.can_shoot_now(), "%s: the Shoot button is live" % role)
	_stand_by_cue_ball()
	await create_timer(0.1).timeout
	await _check(player.enter_cue(), "%s: lines up" % role)
	await create_timer(0.1).timeout
	await _check(coach.step == Coach.Step.AIM, "%s: AIM (step %d)" % [role, coach.step])
	cue.turn(0.3)
	await create_timer(0.1).timeout
	await _check(coach.step == Coach.Step.SPIN, "%s: SPIN (step %d)" % [role, coach.step])
	cue.set_elevation(0.0)
	cue.set_spin(Vector2(0.0, 0.3))
	await create_timer(0.1).timeout
	await _check(coach.step == Coach.Step.POWER, "%s: POWER (step %d)" % [role, coach.step])
	cue.fire(0.35)
	await create_timer(0.1).timeout
