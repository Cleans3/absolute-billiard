extends SceneTree
## The bar slot, solo (docs/plan/02 §3.9): Lobby → Solo → MainLevel. The machine stands at its contract spot with a prop, a
## collision body and its screen; the host takes the stake once, rolls, pays once at the reveal and fires the chaos as real
## Effects; every refusal names its reason and costs nothing; the reels land on the host's stops; the screen follows.
## `godot --path . --headless -s tests/slot/slot_probe.gd`

const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")  # the stakes read off Night 1's Quota

var _fails := 0
var level: Node
var world: WorldInteractions
var house: SlotHouse
var econ: EconomyManager
var fx: EffectManager
var stream: StreamManager
var loop: GameLoop
var player: Player
var machine: SlotMachine
var screen: SlotScreen
var applied: Array[Dictionary] = []
var refused: Array[StringName] = []
var landed: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		push_error("FAIL: " + what)
		print("FAIL: ", what)


func _until(cond: Callable, what: String, sec := 30.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_check(false, "timeout waiting for " + what)
			return


## A seed whose first roll lands on `win` (the house rolls the reels first, so it is the next spin's outcome).
func _seed_for(win: StringName) -> int:
	var r := RandomNumberGenerator.new()
	for s in range(1, 400000):
		r.seed = s
		if SlotMath.evaluate(SlotMath.roll(r)) == win:
			return s
	return -1


## One spin through the real path: the host validates, charges, rolls; `flush` pays at once. Returns the broadcast payload.
func _spin(win: StringName, tier := 1, flush := true) -> Dictionary:
	house.rng.seed = _seed_for(win)
	var before := applied.size()
	world.request(&"slot_spin", 0, {&"tier": tier})
	if applied.size() == before:
		return {}
	var payload: Dictionary = applied.back()
	if flush:
		house.flush()
	return payload


func _close_modals() -> void:
	while UIRouter.instance.current != null and UIRouter.instance.is_modal_open():
		UIRouter.instance.current.call(&"close")


## A zap throws the spinner back out of reach: wait for them to stand, then put them in front of the machine again.
func _stand_at_machine() -> void:
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, "the player stands", 6.0)
	player.global_position = Vector3(-5.0, 0.05, 1.5)
	player.velocity = Vector3.ZERO


func _run() -> void:
	SaveManager.root = "user://probe_slot/"  # ending a Round writes a checkpoint: not into the real profile
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	level = current_scene
	loop = level.get_node("GameLoop")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	world = level.get_node("WorldInteractions")
	house = world.slot_house
	econ = level.get_node("EconomyManager")
	fx = level.get_node("EffectManager")
	stream = level.get_node("StreamManager")
	player = level.get_node("PlayerSpawner").get_local_player()
	machine = get_first_node_in_group(&"slot_machine")
	screen = level.get_node("UILayer/SlotScreen")
	world.interaction_applied.connect(func(_p: int, k: StringName, _t: int, pl: Dictionary) -> void:
		if k == &"slot_spin":
			applied.append(pl.duplicate(true)))
	world.interaction_rejected.connect(func(k: StringName, why: StringName) -> void:
		if k == &"slot_spin":
			refused.append(why))
	_check(machine != null, "a SlotMachine is in the bar")
	machine.landed.connect(func(_p: int, pl: Dictionary) -> void: landed.append(pl))
	await _contract()
	await _rules()
	await _chaos()
	await _live_round()
	await _animation()
	await _screen()
	print("SLOT %s" % ("OK" if _fails == 0 else "FAILED (%d)" % _fails))
	quit(0 if _fails == 0 else 1)


# --- the contract spot, the prop, the prompt ---------------------------------------------------------------------

func _contract() -> void:
	var prop: Interactable
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"slot_spin":
			prop = n
	_check(prop is SlotProp and prop.global_position.is_equal_approx(Bar.SLOT_AT) and prop.prompt == "Play the slots", "the prop is a SlotProp at the contract spot")
	_check(machine.global_position.is_equal_approx(Bar.SLOT_AT), "the machine stands on the footprint centre (-6.3, 0, 1.5)")
	var front := machine.global_transform.basis.z  # its +Z is the front
	_check(front.is_equal_approx(Vector3.RIGHT), "yaw 90: the front faces +X into the room (%s)" % front)
	var body := machine.find_children("*", "StaticBody3D", false, false)
	_check(body.size() == 1 and (body[0] as StaticBody3D).collision_layer == 8, "a layer-4 collision body: the cabinet is a wall")
	var bb := SlotCabinet.body_mesh().get_aabb()
	_check(bb.size.x <= SlotCabinet.WIDTH + 0.001 and bb.size.z <= SlotCabinet.DEPTH + 0.01 and bb.size.y > 1.8 and bb.size.y < 1.95, "the body stays inside the 0.9 x 0.8 m footprint, under 1.95 m: %s" % bb.size)
	_check(machine.find_children("*", "MeshInstance3D", true, false).size() == 5 and machine.find_children("*", "Label3D", true, false).size() == 3, "5 meshes (body, 3 drums, lever) and 3 labels")
	var materials := {}
	for m in machine.find_children("*", "MeshInstance3D", true, false):
		materials[(m as MeshInstance3D).material_override] = true
	_check(materials.size() == 1, "one shared material (07 budget)")
	# tris stay small: the whole machine is a few thousand triangles
	var tris := 0
	for m in machine.find_children("*", "MeshInstance3D", true, false):
		var mesh := (m as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			tris += mesh.surface_get_array_len(s) / 3
	_check(tris < 6000, "triangle budget: %d (the drums are instanced: counted once per use)" % tris)

	player.global_position = Vector3(-4.6, 0.05, 1.5)
	player.rotation.y = PI / 2.0  # facing the machine (-X): a prompt needs facing beyond 0.6 m (06 P33 U8)
	player.velocity = Vector3.ZERO
	await _until(func() -> bool: return player.prompt == "Play the slots", "the slot prompt in reach", 5.0)
	player.interact()
	_check(screen.is_open() and UIRouter.blocking(), "Interact opens the SlotScreen (a modal: the player is blocked)")
	_check(screen.priority == 5 and screen.get_node("Panel").get_global_rect().size.x >= 600.0, "priority 5, a bottom strip")
	await create_timer(FACE_WAIT).timeout
	var to_machine := (machine.global_position + Vector3(0.0, SlotCabinet.DRUM_Y, 0.0) - player.cam.global_position).normalized()
	_check((-player.cam.global_basis.z).dot(to_machine) > 0.98, "the camera turned to the reels (dot %.3f)" % (-player.cam.global_basis.z).dot(to_machine))
	screen.close()
	_check(not UIRouter.blocking(), "closing frees the player")
	player.global_position = Vector3(-5.0, 0.05, 1.5)


const FACE_WAIT := 0.5


# --- host rules: charge once, pay once, refuse without cost -------------------------------------------------------------

func _rules() -> void:
	var bets := SlotMath.bets(NIGHT_1.quota)
	econ.add_cash(1000 - econ.cash, &"test")
	# a miss: the stake goes at the spin, nothing comes back
	var cash0 := econ.cash
	var p := _spin(&"miss", 1, false)
	_check(p.get(&"win") == &"miss" and econ.cash == cash0 - bets[1], "a miss costs the stake at the spin ($%d): cash %d -> %d" % [bets[1], cash0, econ.cash])
	_check(int(p.get(&"bet", 0)) == bets[1] and int(p.get(&"payout", -1)) == 0 and p.get(&"stops") is PackedInt32Array, "the broadcast carries bet, payout and the stops")
	house.flush()
	_check(econ.cash == cash0 - bets[1], "a miss pays nothing at the reveal")
	house.flush()
	machine._finish()
	# the bet back: refunded exactly once, at the reveal
	cash0 = econ.cash
	p = _spin(&"cherry1", 1, false)
	_check(econ.cash == cash0 - bets[1], "cherry back: the stake is gone while the reels run")
	house.flush()
	_check(econ.cash == cash0, "and returns at the reveal (cash %d)" % econ.cash)
	house.flush()
	house.flush()
	_check(econ.cash == cash0, "the payout is applied once however often the reveal is flushed")
	machine._finish()
	# a bigger stake pays more
	cash0 = econ.cash
	p = _spin(&"bells", 2, true)
	_check(int(p[&"bet"]) == bets[2] and econ.cash == cash0 - bets[2] + 7 * bets[2], "bells x7 on the top stake: +$%d" % (6 * bets[2]))
	machine._finish()
	# the client's own keys never reach the others: the payload is rebuilt by the host
	house.rng.seed = _seed_for(&"miss")
	var n := applied.size()
	world.request(&"slot_spin", 0, {&"tier": 0, &"payout": 99999, &"stops": PackedInt32Array([7, 7, 7]), &"win": &"jackpot", &"chaos": [{&"kind": &"zap"}]})
	_check(applied.size() == n + 1 and int(applied.back()[&"payout"]) == 0 and applied.back()[&"win"] == &"miss", "extra keys in the request are dropped: the host's roll stands")
	house.flush()
	machine._finish()

	# refusals: reason named, nothing charged
	refused.clear()
	cash0 = econ.cash
	n = applied.size()
	world.request(&"slot_spin", 0, {&"tier": 9})
	world.request(&"slot_spin", 0, {&"tier": "1"})
	world.request(&"slot_spin", 0, {})
	_check(refused == [&"bad_payload", &"bad_payload", &"bad_payload"] and econ.cash == cash0, "a bad tier is refused, free: %s" % [refused])
	refused.clear()
	player.global_position = Vector3(-1.0, 0.05, 1.5)
	world.request(&"slot_spin", 0, {&"tier": 1})
	_check(refused == [&"too_far"] and econ.cash == cash0 and applied.size() == n, "out of reach: refused, free: %s" % [refused])
	player.global_position = Vector3(-5.0, 0.05, 1.5)
	refused.clear()
	econ.add_cash(5 - econ.cash, &"test")
	world.request(&"slot_spin", 0, {&"tier": 0})
	_check(refused == [&"cant_afford"] and econ.cash == 5 and applied.size() == n, "$5 cannot stake $%d: refused, free" % bets[0])
	econ.add_cash(-50, &"test")  # in debt
	refused.clear()
	world.request(&"slot_spin", 0, {&"tier": 0})
	_check(refused == [&"cant_afford"] and econ.cash == -45, "in debt nothing is affordable")
	econ.add_cash(1000 - econ.cash, &"test")
	refused.clear()
	house.rng.seed = _seed_for(&"miss")
	world.request(&"slot_spin", 0, {&"tier": 0})
	world.request(&"slot_spin", 0, {&"tier": 0})
	_check(refused == [&"busy"] and house.is_busy(), "one spin at a time: the second is `busy` and free")
	_check(econ.cash == 1000 - bets[0], "only one stake was taken (cash %d)" % econ.cash)
	house.flush()
	_check(not house.is_busy(), "a flush frees the machine")
	machine._finish()
	for reason in [&"busy", &"slot_closed", &"shooter_busy", &"cant_afford", &"too_far", &"bad_payload"]:
		_check(WaitText.INTERACTION.has(reason), "'%s' has its own sentence: %s" % [reason, WaitText.interaction(&"slot_spin", reason)])
	var phase := loop.phase
	loop.phase = GameLoop.Phase.RECKONING
	refused.clear()
	world.request(&"slot_spin", 0, {&"tier": 0})
	loop.phase = phase
	_check(refused == [&"slot_closed"], "dark between Nights: %s" % [refused])


# --- chaos: real Effects, decided with the spin, fired at the reveal ---------------------------------------------------

func _chaos() -> void:
	econ.add_cash(5000 - econ.cash, &"test")
	var bet := SlotMath.bets(NIGHT_1.quota)[1]  # the middle stake, tier 1, which _spin defaults to
	# WILD: x3 and a free drink for the spinner
	var cash0 := econ.cash
	var live0 := fx.live_drinks().size()
	var p := _spin(&"wild", 1, false)
	var chaos: Array = p[&"chaos"]
	_check(chaos.size() == 1 and chaos[0].kind == &"drink" and FxCatalog.drink(chaos[0].id) != null, "wild plans a free drink and names it: %s" % [chaos])
	_check(fx.live_drinks().size() == live0, "the drink waits for the reveal")
	house.flush()
	var served: Array = fx.live_drinks().filter(func(d: Dictionary) -> bool: return d.peer_id == 1 and d.drink.id == chaos[0].id)
	_check(served.size() == 1 and econ.cash == cash0 - bet + 3 * bet, "the free drink is in effect and wild paid x3")
	_check(fx.live_count() > 0, "the drink's Effects are live (the only modifier path)")
	_check(SlotScreen.chaos_text(chaos).begins_with("On the house: "), "the screen words it: %s" % SlotScreen.chaos_text(chaos))
	machine._finish()
	# JACKPOT in the Intermission: a round for the crew + the chat goes wild, no hazard (it would outlast its Round)
	var hype0 := stream.hype
	var viewers0 := stream.viewers
	p = _spin(&"jackpot", 1, true)
	var kinds := (p[&"chaos"] as Array).map(func(c: Dictionary) -> StringName: return c.kind)
	_check(kinds == [&"crew_round", &"hype"] and int(p[&"payout"]) == 120 * bet, "jackpot: x120, a crew round, hype: %s" % [kinds])
	_check(stream.hype > hype0 or hype0 >= 1.0 - SlotHouse.HYPE_KICK, "hype kicked (%.2f -> %.2f)" % [hype0, stream.hype])
	_check(stream.viewers >= viewers0 + SlotHouse.VIEWERS_KICK, "viewers +%d" % SlotHouse.VIEWERS_KICK)
	machine._finish()
	# CURSED: pays, zaps the spinner (a real knock) and hands them a Mystery drink
	econ.add_cash(5000 - econ.cash, &"test")
	p = _spin(&"cursed", 0, false)
	kinds = (p[&"chaos"] as Array).map(func(c: Dictionary) -> StringName: return c.kind)
	_check(&"zap" in kinds and &"mystery" in kinds, "cursed: zap + mystery drink: %s" % [kinds])
	house.flush()
	await create_timer(0.3).timeout
	_check(player.mode == Player.Mode.RAGDOLL, "the zap knocked the spinner down")
	var mystery: Array = fx.live_drinks().filter(func(d: Dictionary) -> bool: return d.drink.tier == DrinkTier.Tier.MYSTERY)
	_check(mystery.size() == 1, "the Mystery drink (buff and debuff on its card) is live")
	await _stand_at_machine()
	machine._finish()
	# ZAP alone: no cash, still bites
	p = _spin(&"zap", 0, true)
	await create_timer(0.3).timeout
	_check(int(p[&"payout"]) == 0 and player.mode == Player.Mode.RAGDOLL, "short circuit: nothing paid, the spinner is down")
	await _stand_at_machine()
	machine._finish()
	# a full hand: the plan never offers a drink the spinner has no slot for (only a refresh of one they hold)
	for d in FxCatalog.DRINKS:
		if fx.serve_drink(d.id, 1) == &"drink_cap":
			break
	var own: Array = fx.live_drinks().filter(func(d: Dictionary) -> bool: return d.peer_id == 1 and not d.gift).map(func(d: Dictionary) -> StringName: return d.drink.id)
	_check(own.size() == EffectManager.MAX_LIVE_DRINKS, "the hand is full: %s" % [own])
	var full := _spin(&"wild", 1, true)
	var offered: Array = (full[&"chaos"] as Array).filter(func(c: Dictionary) -> bool: return c.kind == &"drink")
	var held := fx.live_drinks().filter(func(d: Dictionary) -> bool: return d.peer_id == 1 and not d.gift)
	_check(held.size() <= EffectManager.MAX_LIVE_DRINKS, "never more than %d live drinks (%d)" % [EffectManager.MAX_LIVE_DRINKS, held.size()])
	_check(offered.is_empty() or own.has(offered[0].id), "with a full hand only a refresh is offered: %s of %s" % [offered, own])
	machine._finish()


# --- a live Round: the hazard event, the shooter rule -------------------------------------------------------------------

func _live_round() -> void:
	var gl := loop
	gl.toggle_ready(1)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE, "Round 1 live")
	econ.add_cash(5000 - econ.cash, &"test")
	var events0 := fx.live_events().size()
	var p := _spin(&"jackpot", 1, true)
	var kinds := (p[&"chaos"] as Array).map(func(c: Dictionary) -> StringName: return c.kind)
	_check(kinds == [&"crew_round", &"hype", &"event"], "live Round: jackpot adds a hazard: %s" % [kinds])
	var ev: Array = (p[&"chaos"] as Array).filter(func(c: Dictionary) -> bool: return c.kind == &"event")
	_check(fx.live_events().size() == events0 + 1 and fx.live_events().any(func(e: Event) -> bool: return e.id == ev[0].id), "the hazard '%s' is running with its reward multiplier (x%.2f)" % [ev[0].id, fx.get_reward_multiplier()])
	machine._finish()
	# a second jackpot while the hazard runs: the scheduler holds one at a time, the machine plans another or none
	var p2 := _spin(&"jackpot", 1, true)
	_check(fx.live_events().size() <= 2, "events never pile up unbounded (%d)" % fx.live_events().size())
	machine._finish()
	# the shooter, mid-shot, is at the table, not the machine
	var rd: Node = level.get_node("RoundDirector")
	rd.set(&"shot_in_progress", true)
	refused.clear()
	var cash0 := econ.cash
	world.request(&"slot_spin", 0, {&"tier": 0})
	_check(refused == [&"shooter_busy"] and econ.cash == cash0, "the shooter with a shot in flight is refused, free: %s" % [refused])
	rd.set(&"shot_in_progress", false)
	var p3 := _spin(&"cherry1", 0, true)
	_check(not p3.is_empty(), "between shots the shooter may gamble")
	machine._finish()
	# a phase change pays a pending spin at once: the win is never lost to the Round ending
	cash0 = econ.cash
	_spin(&"cherries", 0, false)
	var bet := SlotMath.bets(NIGHT_1.quota)[0]
	_check(econ.cash == cash0 - bet, "stake taken")
	loop.call(&"_end_round", &"timer")
	_check(econ.cash == cash0 - bet + 4 * bet, "ending the Round flushed the reveal: the win is paid (%d)" % econ.cash)
	machine._finish()
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION or loop.phase == GameLoop.Phase.RECKONING, "the Round over")


# --- the drums land on the host's stops --------------------------------------------------------------------------------

func _animation() -> void:
	if loop.phase != GameLoop.Phase.INTERMISSION:
		return
	_close_modals()  # the Intermission's hazard vote opens over everything below priority 20
	econ.add_cash(5000 - econ.cash, &"test")
	landed.clear()
	var p := _spin(&"lemons", 1, false)
	_check(machine.is_playing(), "the machine is playing")
	var stops: PackedInt32Array = p[&"stops"]
	var t0 := Time.get_ticks_msec()
	await _until(func() -> bool: return not landed.is_empty(), "the last drum to land", 10.0)
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	_check(absf(took - SlotMath.reveal_sec(stops)) < 0.5, "the drums land at the host's reveal time (%.2f s vs %.2f s)" % [took, SlotMath.reveal_sec(stops)])
	_check(landed.size() == 1 and landed[0][&"win"] == &"lemons", "`landed` fired once with the payload")
	await create_timer(SlotMath.SETTLE_SEC + 0.2).timeout
	for i in SlotMath.REELS:
		var face := roundi(fposmod(machine._drums[i].rotation.x, TAU) / (TAU / SlotCabinet.FACES)) % SlotCabinet.FACES
		_check(face == stops[i], "drum %d rests on stop %d (shows %s)" % [i, stops[i], SlotMath.SYMBOL_NAMES[SlotMath.STRIP[stops[i]]]])
	house.flush()
	machine._finish()
	_check(not machine.is_playing() and machine._led.text == SlotMachine.IDLE_TEXT, "afterwards the machine idles")
	# two spins back to back from the machine's side: the second finishes the first and plays from where it rests
	var a := _spin(&"miss", 0, true)
	var b := _spin(&"cherry1", 0, true)
	_check(not a.is_empty() and not b.is_empty() and machine.is_playing(), "a second spin takes over cleanly")
	machine._finish()


# --- the screen --------------------------------------------------------------------------------------------------------

func _screen() -> void:
	if loop.phase != GameLoop.Phase.INTERMISSION:
		return
	_close_modals()
	player.global_position = Vector3(-5.0, 0.05, 1.5)
	econ.add_cash(1000 - econ.cash, &"test")
	screen.open()
	await process_frame
	var bets := SlotMath.bets(NIGHT_1.quota)
	_check(screen._tier_buttons.size() == 3 and screen._tier_buttons[0].text == "$%d" % bets[0] and screen._tier_buttons[2].text == "$%d" % bets[2], "the three stakes read off the Night's Quota")
	_check(screen._tier_buttons[1].button_pressed and screen._spin.text == "PULL THE LEVER  $%d" % bets[1], "the middle stake is picked: %s" % screen._spin.text)
	for b in screen._tier_buttons:
		_check(b.size.y >= 48.0, "stake buttons are thumb-sized (%.0f px)" % b.size.y)
	_check(screen._spin.size.y >= 48.0 and screen._cash.text == "Cash $1000", "the spin button is thumb-sized; the Cash shows")
	screen._tier_buttons[2].pressed.emit()
	_check(screen._spin.text == "PULL THE LEVER  $%d" % bets[2], "picking a stake re-words the button")
	var rect: Rect2 = screen.get_node("Panel").get_global_rect()
	var view := Rect2(Vector2.ZERO, screen.get_viewport_rect().size)
	_check(view.encloses(rect), "the strip is on screen %s in %s" % [rect, view])
	econ.add_cash(30 - econ.cash, &"test")
	screen._refresh()
	_check(screen._spin.disabled and screen._spin.text == "Need $%d" % bets[2], "short of cash the button says what it needs")
	econ.add_cash(1000 - econ.cash, &"test")
	screen._tier_buttons[0].pressed.emit()
	house.rng.seed = _seed_for(&"cherry2")
	applied.clear()
	landed.clear()
	screen._spin.pressed.emit()
	_check(applied.size() == 1 and screen._spin.disabled and screen._spin.text == "Spinning…", "Pull sends the spin; the button waits")
	await _until(func() -> bool: return not landed.is_empty(), "the reels to land", 10.0)
	await process_frame
	_check(screen._status.text == "TWO CHERRIES  +$%d" % (2 * bets[0]), "the strip names the win: %s" % screen._status.text)
	await _until(func() -> bool: return not machine.is_spinning(), "the machine to settle", 3.0)
	await process_frame
	await process_frame
	_check(not screen._spin.disabled and screen._spin.text.begins_with("PULL"), "the button comes back by itself once the drums settle (the celebration is still on: %s)" % machine.is_playing())
	_check(machine.is_playing(), "the celebration outlasts the spin")
	house.flush()
	machine._finish()
	# a refusal reads on the strip
	refused.clear()
	screen._on_rejected(&"slot_spin", &"busy")
	_check(screen._status.text == "The reels are still turning" and not screen._spinning, "a refusal is worded on the strip")
	_check("TRIPLE SEVEN" in SlotScreen.pays_text() and "8-BALL JACKPOT   x120" in SlotScreen.pays_text(), "the pay table lists the wins")
	# a knock closes it
	player.knock(Vector3(1.0, 1.0, 0.0), 1.0)
	await process_frame
	await process_frame
	_check(not screen.is_open(), "a knock closes the strip")
	await _stand_at_machine()
	# Esc / Back closes it
	screen.open()
	UIRouter.instance.escape()
	_check(not screen.is_open(), "Esc closes the strip")
