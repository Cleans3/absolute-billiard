extends SceneTree
# PAIR_TIMEOUT=120
## The bar slot over the network (REQ#slot, through tests/net/pair.sh). The client spins; the host rolls, charges and pays;
## both peers get the same stops, the same win, the same chaos, play the same reels, and end with the same Cash.
##   1. WILD 8-BALLS: x3 and a free drink for the client: the payload is identical on both peers, `landed` fires once on both,
##      the drums rest on the host's stops, the drink's Effects are live for the client on both peers, Cash agrees.
##   1b. a CUSTOM STAKE: the client sends {bet, cash}; the host snaps $57 to $55, charges it, and both peers read bet 55 in the payload;
##      stale cash, a float, 0 and an over-cap stake are refused to the client for free.
##   2. refusals reach the requester: a bad tier (`bad_payload`) and a second spin while the first runs (`busy`).
##   3. SHORT CIRCUIT: the zap knocks the client down, on the client and as a puppet on the host.
##   tests/net/pair.sh tests/net/slot_pair_probe.gd
## Prints `SLOT HOST OK` / `SLOT CLIENT OK`.

const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")  # the stakes read off Night 1's Quota

var role := ""
var port := 0
var nm: Node
var level: Node
var world: WorldInteractions
var machine: SlotMachine
var econ: EconomyManager
var fx: EffectManager
var client_id := 0
var applied: Array[Dictionary] = []
var landed: Array[Dictionary] = []
var rejected: Array[StringName] = []


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("SLOT %s FAIL: %s" % [role.to_upper(), msg])
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


func _put(name: String, text: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(name: String) -> String:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, 30.0)
	await create_timer(0.1).timeout  # the writer may not have closed it yet
	return FileAccess.get_file_as_string(_file(name))


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _seed_for(win: StringName) -> int:
	var r := RandomNumberGenerator.new()
	for s in range(1, 400000):
		r.seed = s
		if SlotMath.evaluate(SlotMath.roll(r)) == win:
			return s
	return -1


func _run() -> void:
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	SaveManager.root = dir
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
	var gl: GameLoop = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	econ = level.get_node("EconomyManager")
	fx = level.get_node("EffectManager")
	client_id = int(nm.get_roster()[1].peer_id)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen to end")
	machine = get_first_node_in_group(&"slot_machine")
	await _check(machine != null, "the machine exists on this peer")
	world.interaction_applied.connect(func(_p: int, k: StringName, _t: int, pl: Dictionary) -> void:
		if k == &"slot_spin":
			applied.append(pl.duplicate(true)))
	world.interaction_rejected.connect(func(k: StringName, why: StringName) -> void:
		if k == &"slot_spin":
			rejected.append(why))
	machine.landed.connect(func(_p: int, pl: Dictionary) -> void: landed.append(pl))
	var house := world.slot_house
	if role == "host":
		world.player_position_source = func(_id: int) -> Vector3: return Bar.SLOT_AT + Vector3(1.0, 0.0, 0.0)  # everyone stands at the machine
		econ.add_cash(2000 - econ.cash, &"probe")
		_put("host_ready", "1")
	else:
		await _read("host_ready")
	await _until(func() -> bool: return econ.cash == 2000, "the mirrored Cash to read $2000")
	var bet := SlotMath.bets(NIGHT_1.quota)[1]

	# 1. WILD 8-BALLS
	if role == "host":
		house.rng.seed = _seed_for(&"wild")
		_put("go_wild", "1")
	else:
		await _read("go_wild")
		world.request(&"slot_spin", 0, {&"tier": 1})
	await _until(func() -> bool: return landed.size() == 1, "the reels to land", 15.0)
	await create_timer(0.4).timeout  # the host's reveal timer and the Cash mirror
	await _check(applied.size() == 1 and applied[0][&"win"] == &"wild", "one spin, a wild: %s" % [applied])
	_put("payload_" + role, var_to_str(applied[0]))
	var other := "client" if role == "host" else "host"
	await _check(await _read("payload_" + other) == var_to_str(applied[0]), "both peers hold the identical payload")
	await _check(landed[0][&"stops"] == applied[0][&"stops"], "the machine played the payload's stops")
	var stops: PackedInt32Array = applied[0][&"stops"]
	for i in SlotMath.REELS:
		var face := roundi(fposmod(machine._drums[i].rotation.x, TAU) / (TAU / SlotCabinet.FACES)) % SlotCabinet.FACES
		await _check(face == stops[i], "drum %d rests on the host's stop %d (shows %d)" % [i, stops[i], face])
	var drink := FxCatalog.drink(applied[0][&"chaos"][0].id)
	await _check(drink != null and fx.is_live(drink.effects[0].id, client_id), "the free drink '%s' is live for the client here" % drink.id)
	await _check(econ.cash == 2000 - bet + 3 * bet, "Cash is $%d (%d) after stake and win" % [2000 - bet + 3 * bet, econ.cash])
	await create_timer(SlotMath.SETTLE_SEC + 0.3).timeout

	# 1b. a custom stake over the wire
	if role == "host":
		house.rng.seed = _seed_for(&"miss")
		_put("go_custom", "1")
	else:
		await _read("go_custom")
		world.request(&"slot_spin", 0, {&"bet": 57, &"cash": econ.cash})  # snaps down to $55
	await _until(func() -> bool: return landed.size() == 2, "the custom spin to land", 15.0)
	await create_timer(0.4).timeout
	await _check(applied.size() == 2 and int(applied[1][&"bet"]) == 55 and int(applied[1][&"tier"]) == -1, "the payload carries the snapped stake $55 and no preset: %s" % [applied.back()])
	var cash_custom := 2000 - bet + 3 * bet - 55
	await _check(econ.cash == cash_custom, "Cash is $%d after the custom stake (%d)" % [cash_custom, econ.cash])
	await create_timer(SlotMath.SETTLE_SEC + 0.3).timeout
	if role == "client":
		rejected.clear()
		world.request(&"slot_spin", 0, {&"bet": 20, &"cash": econ.cash + 1})
		world.request(&"slot_spin", 0, {&"bet": 20.0, &"cash": econ.cash})
		world.request(&"slot_spin", 0, {&"bet": 0, &"cash": econ.cash})
		world.request(&"slot_spin", 0, {&"bet": 100000, &"cash": econ.cash})
		await _until(func() -> bool: return rejected.size() == 4, "four refusals to reach the client")
		await _check(rejected == [&"stale_cash", &"bad_payload", &"bad_bet", &"bad_bet"], "stale cash, a float, zero, over the cap: %s" % [rejected])
		rejected.clear()
		_put("custom_refused", "1")
	else:
		await _read("custom_refused")
		await _check(econ.cash == cash_custom and applied.size() == 2, "four refused stakes cost nothing and ran nothing")

	# 2. refusals come back to whoever asked
	if role == "client":
		world.request(&"slot_spin", 0, {&"tier": 9})
		await _until(func() -> bool: return rejected == [&"bad_payload"], "bad_payload to reach the client")
		_put("bad_done", "1")
	else:
		await _read("bad_done")
		await _check(econ.cash == cash_custom, "a refusal cost nothing")
		house.rng.seed = _seed_for(&"miss")
		_put("go_busy", "1")
	if role == "client":
		await _read("go_busy")
		rejected.clear()
		world.request(&"slot_spin", 0, {&"tier": 0})
		world.request(&"slot_spin", 0, {&"tier": 0})
		await _until(func() -> bool: return rejected == [&"busy"], "busy to reach the client")
	await _until(func() -> bool: return landed.size() == 3, "the second spin to land", 15.0)
	await create_timer(0.5).timeout
	await _check(applied.size() == 3 and applied[2][&"win"] == &"miss", "exactly one more spin ran: %d" % applied.size())
	var cash_now := cash_custom - SlotMath.bets(NIGHT_1.quota)[0]
	await _check(econ.cash == cash_now, "one more stake taken, nothing paid (cash %d vs %d)" % [econ.cash, cash_now])
	await create_timer(SlotMath.SETTLE_SEC + 0.3).timeout

	# 3. SHORT CIRCUIT: the spinner is knocked down
	if role == "host":
		house.rng.seed = _seed_for(&"zap")
		_put("go_zap", "1")
	else:
		await _read("go_zap")
		world.request(&"slot_spin", 0, {&"tier": 0})
	var spawner: Node = level.get_node("PlayerSpawner")
	var victim: Player = spawner.call(&"get_player", client_id)
	await _check(victim != null, "the spinner's Player exists on this peer")
	await _until(func() -> bool: return victim.mode == Player.Mode.RAGDOLL, "the zap to knock the spinner down", 15.0)
	await _until(func() -> bool: return landed.size() == 4, "the third spin's drums to land")  # the knock fires at the host's reveal, this peer's drums a frame or two later
	await _check(applied[3][&"win"] == &"zap", "the third spin was the short circuit")
	_put("done_" + role, "1")
	await _read("done_" + other)
	print("SLOT %s OK" % role.to_upper())
	quit()
