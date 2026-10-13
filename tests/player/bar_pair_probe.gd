extends SceneTree
## Two-peer bar probe (run through tests/net/pair.sh): the client serves the host a drink from the Bartender's
## shelf (the host sees the Effect, the Cash and one stock unit leave; the client sees the stock mirror), the host's
## scratch fine reaches the client as `fined` and a negative Cash balance, then the client tries to grab a camera rig
## the host is carrying and stays in WALK (mirrored held_by), and grabs it once the host has placed it.
##   tests/net/pair.sh tests/player/bar_pair_probe.gd
## Prints `BARPAIR HOST OK` / `BARPAIR CLIENT OK`.

const COUNTER := Vector3(3.5, 0.05, 2.5)  # customer side of the counter (bar props at (4.2, 0, 2.5))

var role := ""
var port := 0
var nm: Node
var level: Node
var rd: RoundDirector
var player: Player
var cams: CameraRigs
var world: WorldInteractions
var econ: EconomyManager
var fx: EffectManager
var _fake_ms := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("BARPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _stand_at(pos: Vector3) -> void:
	player.collision_mask |= 1  # the level floor is still on layer 1 (PERF moves it to 4); without it the walker falls through
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0


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
	level = current_scene
	rd = level.get_node("RoundDirector")
	cams = level.get_node("Cameras")
	world = level.get_node("WorldInteractions")
	econ = level.get_node("EconomyManager")
	fx = level.get_node("EffectManager")
	if role == "host":
		var gl: GameLoop = level.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	await _until(func() -> bool: return level.get_node("PlayerSlots").get_child_count() == 2, "both slots")
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	level.get_node("UILayer/StoryCards").close()  # Night 1's intro is not under test: an open modal blocks grabbing
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	var client_id := int(nm.get_roster()[1].peer_id)
	var spawner = level.get_node("PlayerSpawner")
	econ.add_cash(1000, &"test")
	econ.set_stock(econ.stock_key, [&"beer", &"bar_nuts", &"house_special"] as Array[StringName], [3, 3, 1] as Array[int])
	var beer := FxCatalog.drink(&"beer")
	var seen: Array[Vector2i] = []  # [target, owner]
	fx.effect_applied.connect(func(id: StringName, target: int, owner_id: int, _d: float) -> void:
		if beer.effects.any(func(e: Effect) -> bool: return e.id == id):
			seen.append(Vector2i(target, owner_id)))
	_flag("host_ready")
	await _wait_flag("client_at_bar")
	await _until(func() -> bool: return spawner.get_player_position(client_id).distance_to(COUNTER) < 1.5, "client's avatar at the counter", 10.0)
	_flag("host_saw_bar")
	await _until(func() -> bool: return not seen.is_empty(), "the served drink's Effect", 20.0)
	if not seen.has(Vector2i(1, client_id)):
		_fail("beer Effect landed as %s, expected target 1 owner %d" % [seen, client_id])
	if econ.cash != 1000 - ShopCatalog.item(&"beer").cost_cash:
		_fail("host Cash %d after the serve" % econ.cash)
	if econ.stock_left(0) != 2:
		_fail("beer has %d units left on the host's shelf, expected 2" % econ.stock_left(0))
	# scratch fine (06 P16, P37): Night 1's own rate, taken from a thin purse so Cash goes negative everywhere
	var fine := EconomyManager.fine_for(econ.game_loop.current_night())
	var fines: Array = []
	econ.fined.connect(func(reason: StringName, amount: int) -> void: fines.append([reason, amount]))
	econ.add_cash(-940, &"test")
	rd.cue_respawned.emit(&"scratch")
	if econ.cash != 10 - fine or fines != [[&"scratch", fine]]:
		_fail("host fine: cash %d, fined %s" % [econ.cash, fines])
	_flag("host_fined")
	# camera rig: the host carries it, the client cannot take it, then it is placed and the client can
	world.clock = func() -> int: return _fake_ms
	var rig := cams.rigs[0]
	_stand_at(rig.global_position + Vector3(-0.1, 0.05, -0.4))
	await _until(func() -> bool: return player.prompt == "Grab camera", "host sees the grab prompt", 5.0)
	player.interact()
	await _until(func() -> bool: return player.mode == Player.Mode.CARRY and rig.held_by == 1, "host CARRY", 5.0)
	_flag("host_carrying")
	await _wait_flag("client_tried")
	if rig.held_by != 1:
		_fail("host lost the rig to the client's request (held_by %d)" % rig.held_by)
	_fake_ms += 6000
	player.place_camera(true)
	await _until(func() -> bool: return rig.held_by == 0 and player.mode == Player.Mode.WALK, "host placed the rig", 5.0)
	_flag("host_placed")
	await _until(func() -> bool: return rig.held_by == client_id, "client grabbed the placed rig", 20.0)
	await _wait_flag("client_done")
	print("BARPAIR HOST OK")
	quit(0)


func _client() -> void:
	var menu: BartenderMenu = level.get_node("UILayer/BartenderMenu")
	var controls: TouchControls = level.get_node("UILayer/TouchControls")
	controls.touch = true
	var fines: Array = []
	econ.fined.connect(func(reason: StringName, amount: int) -> void: fines.append([reason, amount]))
	await _wait_flag("host_ready")
	await _until(func() -> bool: return econ.cash >= 1000, "mirrored Cash", 10.0)
	await _until(func() -> bool: return econ.stock_size() == 3 and econ.stock_left(2) == 1, "the host's shelf mirrored", 10.0)
	_stand_at(COUNTER)
	await _until(func() -> bool: return player.prompt == "Bartender", "Bartender prompt", 5.0)
	_flag("client_at_bar")
	await _wait_flag("host_saw_bar")
	player.interact()
	if not menu.is_open():
		_fail("the Bartender menu did not open")
	menu.target_peer = 1
	menu.drink_button(&"beer").pressed.emit()
	await _until(func() -> bool: return econ.stock_left(0) == 2, "the sale mirrored to this shelf", 10.0)
	await _wait_flag("host_fined")
	var fine := EconomyManager.fine_for(econ.game_loop.current_night())
	await _until(func() -> bool: return econ.cash == 10 - fine, "the negative balance mirrored", 10.0)
	if fines != [[&"scratch", fine]]:
		_fail("client fined signals %s, expected one $%d scratch" % [fines, fine])
	menu.close()
	# rig: the host is carrying rig 1; ours is a request the host ignores
	await _wait_flag("host_carrying")
	var rig := cams.rigs[0]
	await _until(func() -> bool: return rig.held_by == 1, "mirrored held_by == host", 5.0)
	_stand_at(rig.global_position + Vector3(0.5, 0.05, 0.0))
	await create_timer(0.3).timeout
	if player.prompt == "Grab camera":
		_fail("a carried rig is still offered")
	world.request(&"move_camera", 1, {})
	await create_timer(1.5).timeout
	if player.mode != Player.Mode.WALK or rig.held_by != 1:
		_fail("mode %d / held_by %d after grabbing a carried rig" % [player.mode, rig.held_by])
	_flag("client_tried")
	await _wait_flag("host_placed")
	await _until(func() -> bool: return rig.held_by == 0, "mirrored: rig free", 5.0)
	_stand_at(rig.global_position + Vector3(-0.1, 0.05, -0.4))
	await _until(func() -> bool: return player.prompt == "Grab camera", "grab prompt on the placed rig", 5.0)
	# The host judges reach from this peer's streamed pose, and ENet throttles unreliable packets for seconds once the
	# idle 30 fps downclock raises the round trip: ask again until the host has seen us (a refusal is `too_far`).
	var t_ask := Time.get_ticks_msec()
	while player.mode != Player.Mode.CARRY and Time.get_ticks_msec() - t_ask < 12000:
		player.interact()
		await create_timer(0.5).timeout
	await _until(func() -> bool: return player.mode == Player.Mode.CARRY, "client CARRY from the mirrored holder", 5.0)
	_flag("client_done")
	await create_timer(1.0).timeout
	print("BARPAIR CLIENT OK")
	quit(0)
