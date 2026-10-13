extends SceneTree

## The new hazards as wired in MainLevel.tscn (solo host), 06 P50-P53: each Event started the way a Round starts it (the scheduler's chosen Event,
## then GameLoop.advance) must reach every consumer, and leave with the Round:
##   EffectManager.hazard_state() names it with its roll, the physics has it (PhysicsSim.hazard / the pin colliders / the tilt direction at the
##   chosen pocket), the picture is up (HazardView), the Blackboard prints name + story (Sunken Ship names its corner), the rack is the one the
##   Event asks for (Double Ball: twice the balls, each paying half; Pinball: nothing on a pin), and a second peer built from the same payload
##   (apply_event, or the resync a rejoining client gets) ends with the same state.
##   godot --path . --headless -s tests/effects/hazard_level_probe.gd
## Prints HAZLEVEL OK, or the failing checks and HAZLEVEL FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		if not finished:
			print("HAZLEVEL FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_hazard_level"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	var loop: GameLoop = level.get_node("GameLoop")
	var fx: EffectManager = level.get_node("EffectManager")
	var sched: EventScheduler = level.get_node("EventScheduler")
	var rd: RoundDirector = level.get_node("RoundDirector")
	var table: Table = level.get_node("Table")
	var bb: Blackboard = level.get_node("Blackboard")
	for id in [&"sunken_ship", &"vacation", &"pinball", &"double_ball", &"ice_rink", &"shaky_hands", &"lead_ball"]:
		await _round(id, loop, fx, sched, rd, table, bb)
	_authored_racks(loop, sched)
	# a rejoining client: the resync carries the Event and its roll
	await _resync(fx, sched, loop, table)
	finished = true
	print("HAZLEVEL OK" if fails == 0 else "HAZLEVEL FAIL")
	quit(0 if fails == 0 else 1)


func _round(id: StringName, loop: GameLoop, fx: EffectManager, sched: EventScheduler, rd: RoundDirector, table: Table, bb: Blackboard) -> void:
	var e := FxCatalog.event(id)
	loop.round_index = (3 if id in [&"pinball", &"double_ball", &"lead_ball"] else 2) - 1  # Night 1's authored racks: Round 3's / 2's, the Event must live with them
	sched._offer.clear()  # the Intermission's open vote would out-rank the Event forced below
	sched._chosen = e
	loop.phase = GameLoop.Phase.INTERMISSION
	loop.advance()
	for i in 20:
		await physics_frame
	var st := fx.hazard_state()
	_check(st.get("id", "") == String(id), "%s: hazard_state() names it (%s)" % [id, st])
	_check(fx.live_events().has(e) and is_equal_approx(fx.get_reward_multiplier(), e.reward_mult), "%s: live, and Event_Mult x%.2f" % [id, e.reward_mult])
	_check(bb._hazard.text.begins_with(e.display_name) and bb._hazard_story.text != "", "%s: the Blackboard prints '%s' / '%s'" % [id, bb._hazard.text, bb._hazard_story.text])
	var views := fx.get_children().filter(func(n: Node) -> bool: return n is HazardView)
	var sim := table.sim
	match id:
		&"sunken_ship":
			var m: HazardModel = fx._events[0].model
			var corner_pos: Vector3 = table.pockets[m.corner].position
			var want := Vector2(corner_pos.x, corner_pos.z).normalized()
			_check(st.corner == String(m.corner) and sim.tilt_direction.distance_to(want) < 1e-6, "sunken_ship: the tilt points at %s's centre" % m.corner)
			_check(is_equal_approx(sim.table_tilt_deg, 4.0) and views.size() == 1, "sunken_ship: 4 degrees, one picture")
			_check(bb._hazard.text.contains("(%s)" % String(m.corner).trim_prefix("corner_").to_upper()) and bb._hazard_story.text.contains("sinking"), "sunken_ship: the Blackboard names the corner: '%s' / '%s'" % [bb._hazard.text, bb._hazard_story.text])
			_check(table.pockets.has(m.corner) and (st.params as Array).size() == 1, "sunken_ship: the corner is a pocket of the layout")
		&"vacation":
			_check(sim.hazard != null and sim.hazard.shore_n != Vector2.ZERO and views.size() == 1, "vacation: the shoreline is in the physics, and drawn")
			for b in rd.get_balls():
				_check(b.motion.hazard == sim.hazard, "vacation: ball %d models the same shoreline" % b.net_id)
		&"pinball":
			var pins := sim.get_children().filter(func(n: Node) -> bool: return n is Node3D and n.name.begins_with("Pins"))
			_check(sim.hazard != null and sim.hazard.pins.size() == 4 and pins.size() == 1 and pins[0].get_child_count() == 4 and views.size() == 1, "pinball: 4 pins, 4 colliders, one picture")
			var keep := fx.hazard_keepouts()
			var clear := true
			for b in rd.get_balls():
				var p := table.to_local(b.global_position)
				for k in keep:
					clear = clear and Vector2(p.x, p.z).distance_to(Vector2(k.x, k.y)) >= k.z - 1e-4
			_check(keep.size() == 4 and clear, "pinball: no ball of the rack stands on a pin (%d balls)" % rd.get_balls().size())
			for b in rd.get_balls():
				_check(b.motion.hazard == sim.hazard, "pinball: ball %d models the pins" % b.net_id)
		&"double_ball":
			var n := rd.get_balls().size() - 1
			var plain := RackDropper.authored(table.spec, loop.current_night().authored_racks[loop.round_index - 1]).size()
			_check(n == mini(2 * plain, RackDropper.object_cap(2.0)) and n <= 24, "double_ball: %d object balls (the authored rack has %d)" % [n, plain])
			_check(rd.ball_mult() == 2.0 and rd.value_of(load("res://src/resources/ball_types/red_basic.tres")) == 50 and sim.hazard == null and views.is_empty(), "double_ball: each pot pays half (red %d), nothing else on the table" % rd.value_of(load("res://src/resources/ball_types/red_basic.tres")))
			_check(st.get("object_ball_mult", 0.0) == 2.0, "double_ball: hazard_state() carries the multiplier")
			var ids := {}
			for b in rd.get_balls():
				ids[b.net_id] = true
			_check(ids.size() == rd.get_balls().size() and ids.keys().max() < BallEventCodec.MAX_BALLS, "double_ball: net ids unique and under %d" % BallEventCodec.MAX_BALLS)
		&"ice_rink":
			_check(is_equal_approx(sim.cloth_friction_mult, 0.45), "ice_rink: the cloth drag is x0.45 in the physics")
		&"shaky_hands":
			_check(is_equal_approx(fx.get_stat(&"cue_aim_wobble_deg", 1, 0.0), 1.5), "shaky_hands: +1.5 degrees of aim wobble")
		&"lead_ball":
			_check(is_equal_approx(sim.cue_ball_mass_mult, 2.2), "lead_ball: the cue ball weighs x2.2")
	# a second peer from the same payload: the same state
	if st.has("params"):
		var other_table: Table = load("res://src/gameplay/table/Table.tscn").instantiate()
		root.add_child(other_table)
		var other := EffectManager.new()
		other.sim = other_table.sim
		root.add_child(other)
		await physics_frame
		other.begin_event(e, &"", PackedInt32Array(st.params))
		_check(other.hazard_state() == st, "%s: a client built from the payload has the same hazard_state()" % id)
		other.queue_free()
		other_table.queue_free()
	# it leaves with the Round
	loop.round_ended.emit(&"timer", 0)
	for i in 20:
		await physics_frame
	_check(fx.hazard_state().is_empty() and sim.hazard == null and fx.get_children().all(func(n: Node) -> bool: return not (n is HazardView) or n.is_queued_for_deletion()), "%s: gone with the Round" % id)
	_check(bb._hazard.text == "none" and is_equal_approx(sim.table_tilt_deg, 0.0) and is_equal_approx(sim.cloth_friction_mult, 1.0), "%s: the board and the physics are plain again" % id)
	if id == &"pinball":
		_check(sim.get_children().all(func(n: Node) -> bool: return not (n is Node3D) or n.is_queued_for_deletion()), "pinball: the pin colliders are freed")


## Double Ball is never offered for a Round whose rack is authored (Night 1's three, the finale's three) and is offered for a generated one.
func _authored_racks(loop: GameLoop, sched: EventScheduler) -> void:
	var saved_night := loop.night_index
	var saved_seed := loop.campaign_seed
	var seen := {}  # "night" -> offers that held double_ball
	var pool := {}  # "night" -> offers made
	for night in [0, 1, 2]:  # Night 1 (authored), Night 2 (generated), Night 3 = the Campaign finale (authored)
		loop.night_index = night
		var cfg := loop.current_night()
		for s in 60:
			loop.campaign_seed = 1000 + s
			sched._used.clear()
			for e in FxCatalog.EVENTS:
				sched._seen[e.id] = true  # a scripted_first Event the crew has met is a plain choice, not a forced announcement
			var ids := sched.offer(3, 2, cfg.night_number)
			pool[night] = int(pool.get(night, 0)) + 1
			if ids.has(&"double_ball"):
				seen[night] = int(seen.get(night, 0)) + 1
			sched._offer.clear()
	_check(int(seen.get(0, 0)) == 0 and int(seen.get(2, 0)) == 0, "double_ball is never offered for an authored rack (Night 1 round 3: %d of %d offers, the finale: %d of %d)" % [int(seen.get(0, 0)), pool[0], int(seen.get(2, 0)), pool[2]])
	print("hazlevel: double_ball in round-3 offers of 60 campaign seeds: Night 1 (authored) %d, Night 2 (generated) %d, Night 3 (finale, authored) %d" % [int(seen.get(0, 0)), int(seen.get(1, 0)), int(seen.get(2, 0))])
	_check(int(seen.get(1, 0)) > 0, "... and still is for a generated rack (Night 2 round 3: %d of %d offers)" % [int(seen.get(1, 0)), pool[1]])
	loop.night_index = saved_night
	loop.campaign_seed = saved_seed
	sched._used.clear()
	sched._seen.clear()


## The resync a returning client gets (EffectManager.resync_peer): a second EffectManager restores the Event, its roll and its picture.
func _resync(fx: EffectManager, sched: EventScheduler, loop: GameLoop, table: Table) -> void:
	sched._offer.clear()
	sched._chosen = FxCatalog.event(&"pinball")
	loop.round_index = 0
	loop.phase = GameLoop.Phase.INTERMISSION
	loop.advance()
	for i in 10:
		await physics_frame
	var st := fx.hazard_state()
	var ids := PackedStringArray()
	var owners := PackedInt32Array()
	var targets := PackedInt32Array()
	var durations := PackedInt32Array()
	var remaining := PackedFloat32Array()
	for le in fx._live:
		ids.append(le.effect.id)
		owners.append(le.owner_peer_id)
		targets.append(le.target_id)
		durations.append(le.duration_ms)
		remaining.append(le.remaining)
	var other_table: Table = load("res://src/gameplay/table/Table.tscn").instantiate()
	root.add_child(other_table)
	var other := EffectManager.new()
	other.sim = other_table.sim
	root.add_child(other)
	await physics_frame
	other._resync_effects_rpc(ids, owners, targets, durations, remaining, fx._events[0].event.id, fx._events[0].pocket, fx._events[0].params)
	_check(not st.is_empty() and other.hazard_state() == st, "resync: a rejoining client restores the Event and its pins (%s)" % [other.hazard_state()])
	_check(other_table.sim.hazard != null and other_table.sim.hazard.pins_local == table.sim.hazard.pins_local, "resync: its physics has the same pins")
	other.queue_free()
	other_table.queue_free()
	loop.round_ended.emit(&"timer", 0)
	await physics_frame
