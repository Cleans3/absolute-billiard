extends SceneTree
## The cue rack and the held cue (docs/plan/08 §2.9, 06 P57), one process, the real MainLevel (Solo), the rack required:
##  - the rack: five cues on the wall, the prompt says what the local player would do, the prop keeps 1 m from every other prop;
##  - no cue, no shot: `enter_cue` refuses and the host's validator says `no_cue`;
##  - take: a slot empties, the player holds that cue, the stick is in the right hand, upright; a second take is `has_cue`; out of reach
##    is `too_far`; in CUE the walking stick hides and the shot goes; put back: the slot fills, the hand is free;
##  - the stock: `reset_campaign(n)` racks n, a checkpoint saves `cues_left`, a v3 file migrates to five;
##  - step 2: a swing at nobody plays and wears nothing, a second one inside its cooldown is refused; a throw leaves the hand, flies,
##    lands inside the room with a pickup prop (refused before it lands, too far, or with a cue in hand), and is picked up; the third
##    throw of one cue breaks it on landing: the crew pays the scratch fine, four cues are left; a new cue at the counter: refused while
##    holding one or with all five around, then bought (Cash down by its price, straight into the hand).
##   godot --path . --headless -s tests/world/cue_rack_probe.gd
## Prints CUE RACK OK, or the failing checks and CUE RACK FAIL (exit 1).

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var gl: GameLoop
var rack: CueRack
var world: WorldInteractions
var player: Player
var _rejected: Array = []  # [kind, reason]


func _init() -> void:
	create_timer(150.0).timeout.connect(func() -> void:
		if not finished:
			print("CUE RACK FAIL (script error or hang)")
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


func _run() -> void:
	_check(not CueRack.required, "the rack is not required in a headless run by default (no older probe fetches a cue)")
	_save_checks()
	await process_frame
	SaveManager.root = "user://test_cue_rack"
	DirAccess.make_dir_recursive_absolute(SaveManager.root.path_join("checkpoints"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, false, false, false, false, true)
	_check(CueRack.required, "SoloSupport(keep_cues) leaves the rack required")
	level = current_scene
	rd = level.get_node("RoundDirector")
	gl = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	rack = level.get_node_or_null("CueRack") as CueRack
	player = level.get_node("PlayerSpawner").call(&"get_local_player") as Player
	_check(rack != null and rack.world == world, "MainLevel has a CueRack wired to WorldInteractions")
	_check(player != null, "a local player")
	if rack == null or player == null:
		_end()
		return
	world.interaction_rejected.connect(func(kind: StringName, reason: StringName) -> void: _rejected.append([kind, reason]))
	_rack_checks()
	await _no_cue_checks()
	await _take_checks()
	await _shoot_checks()
	await _put_checks()
	_stock_checks()
	await _swing_checks()
	await _throw_checks()
	await _buy_checks()
	_end()


func _end() -> void:
	finished = true
	if fails == 0:
		print("CUE RACK OK")
		quit(0)
	else:
		print("CUE RACK FAIL: %d checks" % fails)
		quit(1)


# ---------------------------------------------------------------- the save layer, pure

func _save_checks() -> void:
	_check(SaveManager.SAVE_VERSION == 4, "SaveProfile is v4")
	var v3 := {"save_version": 3, "crew_cash": 100, "current_night": 2, "mode": "campaign", "run": {}}
	var m := SaveManager.migrate(v3.duplicate(true))
	_check(int(m.get("save_version")) == 4 and int(m.get("cues_left", -1)) == CueRack.SLOTS, "a v3 file migrates to v4 with all five cues: %s" % str(m.get("cues_left")))
	var p := SaveProfile.new()
	p.cues_left = 3
	var back := SaveProfile.from_dict(p.to_dict())
	_check(back.cues_left == 3, "cues_left survives a round trip")
	_check(SaveProfile.from_dict({"cues_left": 99}).cues_left == CueRack.SLOTS and SaveProfile.from_dict({"cues_left": -2}).cues_left == 0, "a hand-edited count is clamped to 0..5")
	_check(SaveProfile.CUES == CueRack.SLOTS, "the save layer's count is the rack's")


# ---------------------------------------------------------------- the level

func _rack_checks() -> void:
	_check(rack.cues_on_rack() == CueRack.SLOTS and rack.intact_count() == CueRack.SLOTS and rack.held.is_empty(), "five cues on the rack, nobody holding one")
	var shown := 0
	for i in CueRack.SLOTS:
		shown += 1 if rack.get_node("Cue%d" % (i + 1)).visible else 0
	_check(shown == CueRack.SLOTS, "five sticks stand on the wall")
	var prop := rack.get_node("Prop") as Interactable
	_check(prop.effective_kind() == CueRack.KIND and prop.prompt == "Take a cue", "the prop is `cue_rack` and says Take a cue: '%s'" % prop.prompt)
	for n in get_nodes_in_group(&"interactable"):
		var it := n as Interactable
		if it == prop or it.effective_kind() == Interactable.SIT:
			continue
		_check(it.global_position.distance_to(prop.global_position) >= 1.0, "the rack's prop keeps 1 m from %s" % it.effective_kind())
	_check(absf(rack.global_position.z + 7.0) < 0.01 and rack.global_position.y == 0.0, "the rack hangs on the north wall")


func _go_live() -> void:
	gl.advance()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and not rd.staging, "a live Round")
	for i in 60:
		await physics_frame


func _cue() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


## Stands the local player beside the cue ball, facing it.
func _to_cue_ball() -> void:
	var ball := _cue()
	var spot := ball.global_position + Vector3(0.0, 0.0, 1.0)
	player.global_position = Vector3(spot.x, 0.0, spot.z)
	player.velocity = Vector3.ZERO
	await physics_frame
	await physics_frame


func _no_cue_checks() -> void:
	await _go_live()
	await _to_cue_ball()
	_check(not player.enter_cue(), "no cue in hand: enter_cue refuses")
	_check(player.mode == Player.Mode.WALK, "...and the player still walks")
	var intent := ShotIntent.new()
	intent.power = 0.5
	intent.aim_dir = Vector2.RIGHT
	_check(rd._validate_shot(1, intent) == &"no_cue", "the host's validator says no_cue: %s" % rd._validate_shot(1, intent))
	_check(WaitText.shot(&"no_cue") != "" and WaitText.INTERACTION.has(&"has_cue") and WaitText.INTERACTION.has(&"rack_empty"), "every refusal has its sentence")


func _to_rack() -> void:
	var prop := rack.get_node("Prop") as Node3D
	player.global_position = prop.global_position + Vector3(0.0, 0.0, 0.6)
	player.velocity = Vector3.ZERO
	await physics_frame
	await physics_frame


func _take_checks() -> void:
	player.global_position = Vector3(0.0, 0.0, 5.0)  # far from the rack
	await physics_frame
	_rejected.clear()
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	await process_frame
	_check(not rack.holds(1) and _rejected.size() == 1 and _rejected[0][1] == &"too_far", "out of reach: too_far %s" % str(_rejected))
	await _to_rack()
	_rejected.clear()
	(rack.get_node("Prop") as Interactable).try_use({})
	await process_frame
	_check(rack.holds(1) and rack.held[1] == 1, "taken: the player holds cue 1")
	_check(rack.cues_on_rack() == CueRack.SLOTS - 1 and rack.slot_cue[0] == 0 and not rack.get_node("Cue1").visible, "slot 1 is empty on the wall")
	_check((rack.get_node("Prop") as Interactable).prompt == "Put the cue back", "the prompt now offers to put it back")
	_check(rack.intact_count() == CueRack.SLOTS, "still five intact cues")
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"has_cue", "a second take: has_cue %s" % str(_rejected))
	for i in 10:
		await process_frame
	var stick := rack.get_node_or_null("Held1") as MeshInstance3D
	_check(stick != null and stick.visible, "the held stick is drawn")
	if stick != null:
		var axis := stick.global_basis.y.normalized()
		_check(axis.dot(Vector3.UP) > 0.96, "...upright (lean %.1f deg)" % rad_to_deg(acos(clampf(axis.dot(Vector3.UP), -1.0, 1.0))))
		var hand := player.humanoid.hand_world(0)
		var butt := stick.global_position - axis * CueController.CUE_LEN_M * 0.5
		_check(absf((hand - butt).dot(axis) - CueRack.HOLD_FROM_BUTT) < 0.02 and (hand - butt - axis * (hand - butt).dot(axis)).length() < 0.02, "...in the right hand, gripped %.2f m up from the butt" % (hand - butt).dot(axis))
		_check(butt.y > player.global_position.y - 0.05 and butt.y < player.global_position.y + 0.3, "...its butt just off the floor: %.2f" % (butt.y - player.global_position.y))
		var right := player.global_basis.x.normalized()
		_check((hand - player.global_position).dot(right) > 0.1, "...on the body's right")


func _shoot_checks() -> void:
	await _to_cue_ball()
	_check(player.enter_cue(), "with a cue in hand: CUE")
	for i in 3:
		await process_frame
	var stick := rack.get_node_or_null("Held1") as MeshInstance3D
	_check(stick != null and not stick.visible, "in CUE the walking stick hides (the aim stick takes over)")
	var intent := ShotIntent.new()
	intent.power = 0.5
	intent.aim_dir = Vector2.RIGHT
	_check(rd._validate_shot(1, intent) == &"", "the validator lets the cue's holder shoot: '%s'" % rd._validate_shot(1, intent))
	player.exit_cue()
	for i in 3:
		await process_frame
	_check(stick != null and stick.visible and player.mode == Player.Mode.WALK, "out of CUE the stick is back in the hand")


func _put_checks() -> void:
	await _to_rack()
	(rack.get_node("Prop") as Interactable).try_use({})
	await process_frame
	_check(not rack.holds(1) and rack.cues_on_rack() == CueRack.SLOTS and rack.slot_cue[0] == 1, "put back: cue 1 is in the first empty slot again")
	await process_frame
	_check(rack.get_node_or_null("Held1") == null or rack.get_node("Held1").is_queued_for_deletion(), "the held stick is gone")
	_check((rack.get_node("Prop") as Interactable).prompt == "Take a cue", "the prompt offers a cue again")


func _stock_checks() -> void:
	rack.reset_campaign(3)
	_check(rack.cues_on_rack() == 3 and rack.slot_cue[3] == 0 and rack.slot_cue[4] == 0 and not rack.get_node("Cue5").visible, "reset_campaign(3): three cues, two empty slots")
	_check(gl.build_profile().cues_left == 3, "the checkpoint saves cues_left = 3")
	rack.reset_campaign(0)
	_check((rack.get_node("Prop") as Interactable).prompt == "No cues on the rack", "an empty rack says so")
	_rejected.clear()
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	_check(_rejected.size() == 1 and _rejected[0][1] == &"rack_empty", "taking from an empty rack: rack_empty %s" % str(_rejected))
	rack.reset_campaign(CueRack.SLOTS)


# ---------------------------------------------------------------- step 2: swing, throw, break, buy

func _take() -> void:
	await _to_rack()
	(rack.get_node("Prop") as Interactable).try_use({})
	await process_frame


func _face_open_floor() -> void:
	player.global_position = Vector3(0.0, 0.0, 2.5)
	player.rotation.y = PI  # facing +z: the open floor toward the south wall
	player.head.rotation.x = -0.2
	player.velocity = Vector3.ZERO
	for i in 3:
		await physics_frame


func _swing_checks() -> void:
	await _take()
	_check(rack.holds(1), "a cue for the swing")
	await _face_open_floor()
	_rejected.clear()
	var applied := []
	var on_apply := func(_p: int, k: StringName, _t: int, pl: Dictionary) -> void:
		if k == CueRack.SWING_KIND:
			applied.append(pl.duplicate())
	world.interaction_applied.connect(on_apply)
	player.swing_cue()
	await process_frame
	_check(applied.size() == 1 and int(applied[0].hit) == 0 and not bool(applied[0].breaks), "a swing at nobody: applied, no hit, no break %s" % str(applied))
	_check(rack._wear.get(rack.held[1], Vector2i.ZERO) == Vector2i.ZERO, "...and it wears nothing")
	var stick := rack.get_node("Held1") as MeshInstance3D
	var lowest := 1.0  # the stick's most tipped moment through the swing (1 = straight up)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(CueRack.SWING_SEC * 1000.0):
		await process_frame
		lowest = minf(lowest, stick.global_basis.y.normalized().dot(Vector3.UP))
	_check(stick.visible and lowest < 0.0, "the swing brings the stick past horizontal (lowest up-dot %.2f)" % lowest)
	await create_timer(0.1).timeout
	player.swing_cue()
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"cooldown", "a second swing inside 0.8 s: cooldown %s" % str(_rejected))
	_check(CueRack.SWING_COOLDOWN_MSEC > int((CueRack.SWING_SEC + 0.1) * 1000.0), "(the probe's second swing is inside the cooldown)")
	world.interaction_applied.disconnect(on_apply)
	await create_timer(0.5).timeout
	_check(stick.global_basis.y.normalized().dot(Vector3.UP) > 0.96, "after the swing the stick is held upright again")


func _throw_once() -> Dictionary:
	await _face_open_floor()
	var got := {}
	var on_apply := func(_p: int, k: StringName, _t: int, pl: Dictionary) -> void:
		if k == CueRack.THROW_KIND:
			got.merge(pl)
	world.interaction_applied.connect(on_apply)
	player.throw_cue()
	await process_frame
	world.interaction_applied.disconnect(on_apply)
	return got


func _throw_checks() -> void:
	var cash0 := gl.economy.cash
	var pl := await _throw_once()
	_check(not pl.is_empty() and not rack.holds(1), "thrown: the cue left the hand")
	if pl.is_empty():
		return
	var cue := int(pl.cue)
	var land: Vector3 = pl.land
	_check(float(pl.t_land) > 0.05 and float(pl.t_land) <= CueRack.FLIGHT_MAX_SEC, "a flight of %.2f s" % float(pl.t_land))
	_check(absf(land.x) <= CueRack.ROOM_HALF and absf(land.z) <= CueRack.ROOM_HALF and land.y > -0.05 and land.y < 1.2, "it lands inside the room: %s" % str(land))
	_check(rack.on_floor.has(cue) and rack.intact_count() == CueRack.SLOTS, "a loose cue is still one of the five")
	_rejected.clear()
	player.global_position = land + Vector3(0.0, 0.0, -0.5)
	await physics_frame
	world.request(CueRack.PICKUP_KIND, cue, {})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"not_landed", "picking it up mid-air: not_landed %s" % str(_rejected))
	await create_timer(float(pl.t_land) + 0.2).timeout
	var loose := rack.get_node_or_null("Loose%d" % cue) as MeshInstance3D
	_check(loose != null and loose.global_position.distance_to(land) < 0.05 and absf(loose.global_basis.y.normalized().y) < 0.05, "it lies flat where it landed")
	var prop := rack.get_node_or_null("Pickup%d" % cue) as Interactable
	_check(prop != null and prop.prompt == "Pick up the cue", "with a pickup prop")
	player.global_position = land + Vector3(0.0, 0.0, 4.0)
	await physics_frame
	_rejected.clear()
	world.request(CueRack.PICKUP_KIND, cue, {})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"too_far", "from 4 m: too_far %s" % str(_rejected))
	player.global_position = land + Vector3(0.0, 0.0, -0.5)
	await physics_frame
	prop.try_use({})
	await process_frame
	_check(rack.holds(1) and rack.held[1] == cue and not rack.on_floor.has(cue), "picked up: the same cue is in the hand again")
	for n in 2:  # throws two and three of the same cue
		await create_timer(1.1).timeout
		var again := await _throw_once()
		if again.is_empty():
			_check(false, "throw %d applied" % (n + 2))
			return
		await create_timer(float(again.t_land) + 0.2).timeout
		if n == 0:
			_check(not bool(again.breaks) and rack.on_floor.has(cue), "the second throw does not break it")
			player.global_position = (again.land as Vector3) + Vector3(0.0, 0.0, -0.5)
			await physics_frame
			world.request(CueRack.PICKUP_KIND, cue, {})
			await process_frame
		else:
			_check(bool(again.breaks), "the third throw breaks it")
	await create_timer(0.3).timeout
	var fine := EconomyManager.fine_for(gl.current_night())
	_check(not rack.on_floor.has(cue) and not rack.holds(1) and rack.intact_count() == CueRack.SLOTS - 1, "the broken cue is gone: %d left" % rack.intact_count())
	_check(gl.economy.cash == cash0 - fine, "the crew paid the fine: %d -> %d (fine %d)" % [cash0, gl.economy.cash, fine])


func _buy_checks() -> void:
	var bar_at := Vector3.INF
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"bar_buy":
			bar_at = (n as Node3D).global_position
	_check(bar_at.is_finite(), "the counter has a bar_buy prop")
	player.global_position = bar_at + Vector3(-0.4, 0.0, 0.0)
	await physics_frame
	gl.economy.add_cash(1000, &"probe")
	_check(not rack.holds(1) and rack.intact_count() == CueRack.SLOTS - 1, "nothing in hand, one cue short")
	var cost := rack.price()
	var cash0 := gl.economy.cash
	rack.request_buy()
	await process_frame
	_check(rack.holds(1) and gl.economy.cash == cash0 - cost and rack.intact_count() == CueRack.SLOTS, "bought: a cue in hand, Cash down by %d, five again" % cost)
	_rejected.clear()
	rack.request_buy()
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"has_cue", "buying with a cue in hand: has_cue %s" % str(_rejected))
	await _to_rack()
	(rack.get_node("Prop") as Interactable).try_use({})  # put it back: five on the wall and in hands
	await process_frame
	player.global_position = bar_at + Vector3(-0.4, 0.0, 0.0)
	await physics_frame
	_rejected.clear()
	rack.request_buy()
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"cues_full", "with all five around: cues_full %s" % str(_rejected))
