extends SceneTree
## The shock and the sink (docs/plan/08 §2.9 step 3, 06 P57), one process, the real MainLevel (Solo), the rack required:
##  - the sink: a DishStation in the kitchen corner, its prop says *Dirty dishes* to a player who owes nothing, `wash_dish` is `no_debt`;
##  - a credit buy: no Cash and a cue short, the counter's *New cue* still puts the cue in the hand, Cash untouched, the buyer owes its
##    price; the buyer is knocked limp with a ZAP! over them and, once standing, put at the sink facing it;
##  - nobody in debt shoots: `enter_cue` refuses and the host's validator says `in_debt`;
##  - washing: out of reach `too_far`, at the sink each plate takes `pay_per_plate` off (a second press inside 0.9 s is `cooldown`), the
##    clean stack grows, and once the debt is gone the prompt clears and the validator lets the cue's holder shoot;
##  - the Night's end: any debt fails `evaluate_quota` whatever the Cash; the checkpoint saves `cue_debt`, a resume puts it on the host.
##   godot --path . --headless -s tests/world/dish_probe.gd
## Prints DISH OK, or the failing checks and DISH FAIL (exit 1).

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var gl: GameLoop
var rack: CueRack
var sink: DishStation
var world: WorldInteractions
var player: Player
var _rejected: Array = []


func _init() -> void:
	create_timer(170.0).timeout.connect(func() -> void:
		if not finished:
			print("DISH FAIL (script error or hang)")
			quit(1))
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _until(cond: Callable, what: String, sec := 10.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_check(false, "timeout waiting for " + what)
			return false
	return true


func _end() -> void:
	finished = true
	print("DISH OK" if fails == 0 else "DISH FAIL: %d checks" % fails)
	quit(0 if fails == 0 else 1)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_dish"
	DirAccess.make_dir_recursive_absolute(SaveManager.root.path_join("checkpoints"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, false, false, false, false, true)
	level = current_scene
	rd = level.get_node("RoundDirector")
	gl = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	rack = level.get_node("CueRack")
	sink = level.get_node_or_null("DishStation") as DishStation
	player = level.get_node("PlayerSpawner").call(&"get_local_player") as Player
	_check(sink != null and sink.world == world, "MainLevel has a DishStation wired to WorldInteractions")
	if sink == null:
		_end()
		return
	world.interaction_rejected.connect(func(kind: StringName, reason: StringName) -> void: _rejected.append([kind, reason]))
	_sink_checks()
	await _credit_checks()
	await _debt_blocks_checks()
	await _wash_checks()
	_night_and_save_checks()
	_end()


func _prop() -> Interactable:
	return sink.get_node("Prop") as Interactable


func _sink_checks() -> void:
	_check(not sink.owes(1) and sink.total_debt() == 0 and _prop().prompt == "Dirty dishes", "nobody owes; the sink says Dirty dishes")
	_check(_prop().effective_kind() == DishStation.KIND, "the prop is `wash_dish`")
	for n in get_nodes_in_group(&"interactable"):
		var it := n as Interactable
		if it != _prop() and it.effective_kind() != Interactable.SIT:
			_check(it.global_position.distance_to(_prop().global_position) >= 1.0, "the sink's prop keeps 1 m from %s" % it.effective_kind())
	_check(absf(sink.global_position.z + 7.0) < 0.01 and sink.global_position.x < -1.6 and sink.global_position.x > -4.6, "the sink stands on the north wall left of the door")
	_rejected.clear()
	world.request(DishStation.KIND, 0, {})
	_check(_rejected.size() == 1 and _rejected[0][1] == &"no_debt", "washing with no debt: no_debt %s" % str(_rejected))


func _counter() -> Vector3:
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"bar_buy":
			return (n as Node3D).global_position
	return Vector3.INF


func _credit_checks() -> void:
	rack.reset_campaign(CueRack.SLOTS - 1)  # a cue short: one may be bought
	gl.economy.add_cash(-gl.economy.cash, &"probe")  # and no Cash for it
	player.global_position = _counter() + Vector3(-0.4, 0.0, 0.0)
	player.velocity = Vector3.ZERO
	await physics_frame
	var price := rack.price()
	rack.request_buy()
	await process_frame
	_check(rack.holds(1) and gl.economy.cash == 0, "on credit: the cue is in the hand, the Cash untouched (%d)" % gl.economy.cash)
	_check(sink.debt_of(1) == price and sink.owes(1), "the buyer owes the cue's price: %d of %d" % [sink.debt_of(1), price])
	_check(_prop().prompt.begins_with("Wash a plate"), "the sink now offers a plate: '%s'" % _prop().prompt)
	_check(sink.find_children("*", "Label3D", true, false).any(func(l: Label3D) -> bool: return l.text == "ZAP!"), "a ZAP! over the debtor")
	await _until(func() -> bool: return player.mode == Player.Mode.RAGDOLL, "the shock to knock the buyer limp", 2.0)
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, "the debtor to stand", 6.0)
	await _until(func() -> bool: return player.global_position.distance_to(sink.global_transform * DishStation.STAND_AT) < 0.3, "the debtor put at the sink", 2.0)
	var to := sink.global_position - player.global_position
	_check((-player.global_basis.z).normalized().dot(Vector3(to.x, 0.0, to.z).normalized()) > 0.95, "...facing it")


func _debt_blocks_checks() -> void:
	gl.advance()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and not rd.staging, "a live Round")
	for i in 30:
		await physics_frame
	var intent := ShotIntent.new()
	intent.power = 0.5
	intent.aim_dir = Vector2.RIGHT
	_check(rd._validate_shot(1, intent) == &"in_debt", "the host's validator: in_debt (%s)" % rd._validate_shot(1, intent))
	var ball: Ball = null
	for b in rd.get_balls():
		if b.is_cue_ball:
			ball = b
	player.global_position = Vector3(ball.global_position.x, 0.0, ball.global_position.z + 1.0)
	await physics_frame
	_check(not player.enter_cue(), "a debtor cannot enter CUE")


func _wash_checks() -> void:
	player.global_position = Vector3(0.0, 0.0, 2.0)
	await physics_frame
	_rejected.clear()
	world.request(DishStation.KIND, 0, {})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"too_far", "washing from across the room: too_far %s" % str(_rejected))
	player.global_position = sink.global_transform * DishStation.STAND_AT
	await physics_frame
	var pay := sink.pay_per_plate()
	var before := sink.debt_of(1)
	_prop().try_use({})
	await process_frame
	_check(sink.debt_of(1) == before - mini(pay, before), "one plate: -$%d (%d -> %d)" % [pay, before, sink.debt_of(1)])
	_check(sink._washed == 1 and sink._clean[0].visible, "the clean stack has a plate")
	_rejected.clear()
	world.request(DishStation.KIND, 0, {})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"cooldown", "a second plate inside 0.9 s: cooldown %s" % str(_rejected))
	var plates := 1
	while sink.owes(1) and plates < 40:
		await create_timer(DishStation.WASH_SEC + 0.05).timeout
		_prop().try_use({})
		await process_frame
		plates += 1
	_check(not sink.owes(1) and plates == ceili(float(before) / pay), "the debt is washed off in %d plates (expected %d)" % [plates, ceili(float(before) / pay)])
	_check(_prop().prompt == "Dirty dishes", "the sink's prompt clears")
	var intent := ShotIntent.new()
	intent.power = 0.5
	intent.aim_dir = Vector2.RIGHT
	_check(rd._validate_shot(1, intent) == &"", "paid up, the cue's holder may shoot again ('%s')" % rd._validate_shot(1, intent))


func _night_and_save_checks() -> void:
	var cfg := gl.current_night()
	gl.economy.add_cash(cfg.quota * 10, &"probe")
	var cash0 := gl.economy.cash
	_check(not gl.economy.evaluate_quota(cfg, false, 5), "a debt left fails the Night whatever the Cash")
	_check(gl.economy.cash == cash0, "...and nothing is paid")
	sink.reset_campaign(7)
	_check(sink.debt_of(1) == 7 and sink.total_debt() == 7, "a resume's debt goes on the host's seat")
	_check(gl.build_profile().cue_debt == 7, "the checkpoint saves cue_debt")
	var p := SaveProfile.new()
	p.cue_debt = 12
	_check(SaveProfile.from_dict(p.to_dict()).cue_debt == 12 and SaveProfile.from_dict({"cue_debt": -3}).cue_debt == 0, "cue_debt round-trips and never goes negative")
	sink.reset_campaign(0)
	_check(sink.total_debt() == 0, "a new campaign owes nothing")
