extends SceneTree
## What the player is offered and when (06 P33 U6 / U7 / U8):
##   U8  a prompt needs the player facing the prop (yaw only, 40 degrees) unless it is within 0.6 m; the smallest angle wins
##   U6  hostile props (heckle, kick_stool, bump_table, throw_drink, flick_lights) are not offered unless a Round is live, nothing is
##       staged and I am not the shooter; the Shoot button shows only when I can strike; the Intermission toast is `no_round`
##   U7  stools and sofas are sittable: snap, lowered camera, SIT stance, the seated flag in the pose, a puppet that sits, and every
##       way up (jump, stick, knock, kick_stool, phase change, CUE)
##   godot --path . --headless -s tests/player/interact_probe.gd
## Prints INTERACT OK, or the failing checks and INTERACT FAIL (exit 1).

const HOSTILE: Array[StringName] = [&"heckle", &"kick_stool", &"bump_table", &"throw_drink", &"flick_lights"]

var fails := 0
var finished := false
var level: Node
var player: Player
var rd: RoundDirector
var loop: GameLoop
var controls: TouchControls
var table: Table
var me := 1


func _init() -> void:
	create_timer(150.0).timeout.connect(func() -> void:
		if not finished:
			print("INTERACT FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _until(cond: Callable, sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			return false
		await process_frame
	return true


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_interact"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	level = current_scene
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	rd = level.get_node("RoundDirector")
	loop = level.get_node("GameLoop")
	controls = level.get_node("UILayer/TouchControls")
	table = level.get_node("Table")
	me = root.multiplayer.get_unique_id()
	controls.touch = true
	player.collision_mask |= 1
	await _idle()
	loop.advance()
	for i in 30:
		await process_frame
	_check(await _until(func() -> bool: return table.sim.awake == 0, 20.0), "the rack settles")
	_facing()
	_hostile()
	await _shoot()
	await _sit()
	finished = true
	print("INTERACT OK" if fails == 0 else "INTERACT FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


## Stand at `pos`, look at `face` (level), read what the player would use.
func _target_at(pos: Vector3, face: Vector3, yaw_off := 0.0) -> Interactable:
	player.global_position = pos
	player.velocity = Vector3.ZERO
	player.rotation.y = atan2(-(face.x - pos.x), -(face.z - pos.z)) + yaw_off
	player.head.rotation.x = 0.0
	player._probe.force_shapecast_update()
	player._scan()
	return player._target


func _is_at(it: Interactable, p: Vector3) -> bool:
	return it != null and Vector2(it.global_position.x - p.x, it.global_position.z - p.z).length() < 0.05


# --- Intermission: nothing to shoot, nothing hostile ----------------------------------------------------

func _idle() -> void:
	_check(loop.phase == GameLoop.Phase.INTERMISSION, "the probe starts at the Intermission")
	rd.current_shooter_id = me
	_check(not player.can_shoot_now(), "Intermission: nothing to strike")
	player._sync_can_shoot()
	await process_frame
	_check(not controls._btn_shoot.visible, "Intermission: no Shoot button, even for the host who holds the turn")
	_check(not player.enter_cue(), "Intermission: the key does nothing")
	_check(UIRouter.instance._toast_label.text == WaitText.SHOT.no_round, "...and says no_round, not 'balls still moving': '%s'" % UIRouter.instance._toast_label.text)
	rd.current_shooter_id = 99
	for kind in HOSTILE:
		var at := _prop_at(kind)
		var t := _target_at(at + Vector3(0.4, 0.0, 0.0), at)
		_check(t == null or t.effective_kind() != kind, "Intermission: no %s prompt (got %s)" % [kind, t.effective_kind() if t != null else "none"])


func _live_prop(kind: StringName, at: Vector3) -> bool:
	for n in get_nodes_in_group(&"interactable"):
		var it := n as Interactable
		if it != null and it.effective_kind() == kind and _is_at(it, at):
			return it.collision_layer != 0
	return false


func _prop_at(kind: StringName) -> Vector3:
	for row: Array in Bar.PROPS:
		if row[0] == kind:
			return row[1]
	return Vector3.INF


# --- U8 ---------------------------------------------------------------------------------------------------

func _facing() -> void:
	rd.current_shooter_id = 99  # a live Round and not the shooter: every prop is offered
	var missing := 0
	var bad_away := 0
	for row: Array in Bar.PROPS:
		var at: Vector3 = row[1]
		if not _live_prop(row[0], at):
			continue  # an inert prop (the phone while it is not ringing has no collision layer) is not meant to be offered
		for d in [0.5, 1.0, 1.95]:
			if _target_at(at + Vector3(d, 0.0, 0.0), at) == null:
				missing += 1
				print("  no prompt at %.2f m facing %s" % [d, row[0]])
		# facing away at 1.5 m: not this prop, and nothing at all unless another prop is in reach
		var pos := at + Vector3(1.5, 0.0, 0.0)
		var away := _target_at(pos, pos + Vector3(1.0, 0.0, 0.0))
		var other_in_reach := false
		for n in get_nodes_in_group(&"interactable"):
			var it := n as Interactable
			if it != null and not _is_at(it, at) and it.global_position.distance_to(pos) <= Player.REACH_M:
				other_in_reach = true
		if _is_at(away, at) or (away != null and not other_in_reach):
			bad_away += 1
			print("  facing away from %s at 1.5 m still offers %s" % [row[0], away.effective_kind() if away != null else "?"])
	_check(missing == 0, "every PROPS entry is offered at 0.5 / 1 / 2 m looking at it (%d misses)" % missing)
	_check(bad_away == 0, "facing away at 1.5 m offers nothing (%d wrong)" % bad_away)
	# within 0.6 m it needs no facing; just past it does
	var juke := _prop_at(&"jukebox")
	_check(_is_at(_target_at(juke + Vector3(0.5, 0.0, 0.0), juke + Vector3(1.0, 0.0, 0.0)), juke), "0.5 m away with the back turned: still offered")
	_check(not _is_at(_target_at(juke + Vector3(0.7, 0.0, 0.0), juke + Vector3(1.0, 0.0, 0.0)), juke), "0.7 m away with the back turned: not")
	# the cone: 35 degrees off is fine, 50 degrees off is not (yaw only)
	var pos2 := juke + Vector3(-1.5, 0.0, 0.0)
	_check(_is_at(_target_at(pos2, juke, deg_to_rad(35.0)), juke) and _is_at(_target_at(pos2, juke, deg_to_rad(-35.0)), juke), "35 degrees off the prop on either side: offered")
	_check(not _is_at(_target_at(pos2, juke, deg_to_rad(50.0)), juke) and not _is_at(_target_at(pos2, juke, deg_to_rad(-50.0)), juke), "50 degrees off: not offered")
	player.head.rotation.x = deg_to_rad(-80.0)  # pitch does not count: looking down at the prop in front of you still selects it
	player.rotation.y = atan2(-(juke.x - pos2.x), -(juke.z - pos2.z))
	player._probe.force_shapecast_update()
	player._scan()
	_check(_is_at(player._target, juke), "looking steeply down at it: still offered (yaw only)")
	player.head.rotation.x = 0.0
	# the smallest angle wins, the nearer one on a tie: two counter props 0.5 m apart in z, one dead ahead
	var counter := _prop_at(&"bar_buy")
	var t := _target_at(counter + Vector3(-0.7, 0.0, 0.0), counter)
	_check(t != null and t.effective_kind() in Player.BAR_KINDS and player.prompt == "Bartender", "counter ahead beats the stools beside it: '%s'" % player.prompt)


# --- U6 hostile prompts ---------------------------------------------------------------------------------

func _hostile() -> void:
	for kind in HOSTILE:
		var w := FxCatalog.interaction(kind)
		_check(w != null and w.hostile, "%s is a hostile interaction" % kind)
	var staged := "staging" in rd
	for kind in HOSTILE:
		var at := _prop_at(kind)
		var from := at + Vector3(0.4, 0.0, 0.0)
		rd.current_shooter_id = 99
		var t := _target_at(from, at)
		var offered := t != null and (t.effective_kind() == kind or (kind == &"throw_drink" and t.effective_kind() in Player.BAR_KINDS))
		_check(offered, "live, not the shooter: %s is offered" % kind)
		rd.current_shooter_id = me
		t = _target_at(from, at)
		_check(t == null or t.effective_kind() != kind, "live, I am the shooter: %s is not offered" % kind)
		if staged:
			rd.current_shooter_id = 99
			rd.set(&"staging", true)
			t = _target_at(from, at)
			_check(t == null or t.effective_kind() != kind, "staging: %s is not offered" % kind)
			rd.set(&"staging", false)
	# a non-hostile prop stays on for the shooter
	rd.current_shooter_id = me
	var juke := _prop_at(&"jukebox")
	_check(_is_at(_target_at(juke + Vector3(0.4, 0.0, 0.0), juke), juke), "the shooter still gets the jukebox")


# --- U6 Shoot button -------------------------------------------------------------------------------------

func _shoot() -> void:
	player.global_position = Vector3(0.0, 0.0, 1.0)
	player.rotation.y = 0.0
	rd.current_shooter_id = me
	table.sim.awake = 0
	_check(player.can_shoot_now(), "live, my turn, all at rest: can strike")
	player._sync_can_shoot()
	await process_frame
	_check(controls._btn_shoot.visible, "...the Shoot button shows")
	rd.current_shooter_id = 99
	_check(not player.can_shoot_now(), "not my turn: cannot strike")
	player._sync_can_shoot()
	await process_frame
	_check(not controls._btn_shoot.visible, "...no Shoot button for the others")
	rd.current_shooter_id = me
	table.sim.awake = 3
	_check(not player.can_shoot_now(), "balls moving: cannot strike")
	_check(not player.enter_cue() and UIRouter.instance._toast_label.text == "Balls still moving (3)", "...the key says balls still moving: '%s'" % UIRouter.instance._toast_label.text)
	table.sim.awake = 0
	# a stale button corrects itself within a poll
	controls.set_can_shoot(false)
	await create_timer(0.4).timeout
	_check(controls._btn_shoot.visible, "the button follows the truth by itself (poll)")
	if "staging" in rd:
		rd.set(&"staging", true)
		_check(not player.can_shoot_now(), "staging: cannot strike")
		_check(not player.enter_cue() and UIRouter.instance._toast_label.text == WaitText.SHOT.staging, "...and the key says the table is being set up")
		rd.set(&"staging", false)
	# a Round that is not live hides it again
	loop.phase = GameLoop.Phase.INTERMISSION
	_check(not player.can_shoot_now(), "not ROUND_LIVE: cannot strike")
	loop.phase = GameLoop.Phase.ROUND_LIVE


# --- U7 sitting -------------------------------------------------------------------------------------------

func _seat(id: StringName) -> Interactable:
	return level.get_node("Bar/%s" % id) as Interactable


func _sit() -> void:
	rd.current_shooter_id = 99
	var seats := get_nodes_in_group(&"interactable").filter(func(n: Node) -> bool: return n is Interactable and (n as Interactable).effective_kind() == Interactable.SIT)
	_check(seats.size() == Bar.SEATS.size() and seats.size() >= 14, "one sit Interactable per Bar.SEATS row (%d)" % seats.size())
	# a stool seat sits on the baked stool (a box 0.8 high) and every sofa seat is inside its sofa's footprint
	var space := player.get_world_3d().direct_space_state
	var off_stool := 0
	for row: Array in Bar.SEATS:
		if is_equal_approx(row[3], Bar.STOOL_TOP):
			var p: Vector3 = row[1]
			var q := PhysicsRayQueryParameters3D.create(p + Vector3(0.0, 1.5, 0.0), p, 15)
			var hit := space.intersect_ray(q)
			if hit.is_empty() or absf(hit.position.y - 0.8) > 0.03:
				off_stool += 1
				print("  seat %s: no stool under it (%s)" % [row[0], hit.get("position", "no hit")])
	_check(off_stool == 0, "every stool seat is on a baked stool (%d off)" % off_stool)
	# sit on a counter stool: approach facing it
	var stool := _seat(&"stool_counter_1")
	var from := Vector3(3.6, 0.0, 1.0)
	var t := _target_at(from, stool.global_position)
	_check(t == stool and player.prompt == "Sit", "facing the stool: 'Sit' (%s)" % [player.prompt])
	player.interact()
	_check(player.seated and player.humanoid.stance == Humanoid.Stance.SIT, "interact sits")
	_check(player.global_position.is_equal_approx(stool.global_position) and absf(angle_difference(player.rotation.y, stool.seat_yaw)) < 0.01, "snapped to the seat and its facing")
	await physics_frame
	await physics_frame
	_check(player._body.disabled, "the capsule stops colliding while seated (the collision exception)")
	await create_timer(1.0).timeout
	var eye := Humanoid.sit_hip_y(Bar.STOOL_TOP) + Player.EYE_M - Humanoid.ORIGIN[Humanoid.B.PELVIS].y
	_check(absf(player.cam.global_position.y - eye) < 0.03, "the camera lowers to the seated eye (%.3f vs %.3f)" % [player.cam.global_position.y, eye])
	# the pose carries the flag; a puppet sits where the stream says
	player.head.rotation.x = -0.3
	var blob := player.pack_pose()
	_check((blob.decode_u16(14) & Player.SEATED_BIT) != 0 and (blob.decode_u16(14) >> 14) == Player.Mode.WALK, "pose: seated flag set, mode WALK")
	var puppet := load("res://src/gameplay/player/Player.tscn").instantiate() as Player
	level.add_child(puppet)
	puppet.make_puppet("Remote", Player.skin_for_seat(1))
	puppet.apply_pose(blob.duplicate())
	await process_frame
	await process_frame
	_check(puppet._puppet_seated and puppet.humanoid.stance == Humanoid.Stance.SIT and is_equal_approx(puppet.humanoid._seat_top, Bar.STOOL_TOP), "puppet: sits on the stool")
	_check(absf(puppet.head.rotation.x - (-0.3)) < 0.001, "pose: pitch survives the 13-bit field (%.5f)" % puppet.head.rotation.x)
	# every way up
	player._jump_queued = true
	await physics_frame
	await physics_frame
	_check(not player.seated and player.humanoid.stance == Humanoid.Stance.STAND, "Jump stands up")
	_check(Vector2(player.global_position.x - from.x, player.global_position.z - from.z).length() < 0.35, "...where I stood before (%s)" % player.global_position)
	await physics_frame
	_check(not player._body.disabled, "...and the capsule collides again")
	await _sit_down(&"stool_counter_1", Vector3(3.6, 0.0, 1.0))
	Input.action_press(&"move_forward")
	await physics_frame
	await physics_frame
	Input.action_release(&"move_forward")
	_check(not player.seated, "a push on the stick / key stands up")
	await _sit_down(&"stool_counter_1", Vector3(3.6, 0.0, 1.0))
	player.knock(Vector3(1.0, 1.0, 0.0), 0.3)
	_check(not player.seated, "a knock clears it")
	_check(await _until(func() -> bool: return player.mode == Player.Mode.WALK, 5.0), "...and the player gets up from the knock")
	await create_timer(0.7).timeout  # the camera eases back onto Head
	var world: WorldInteractions = level.get_node("WorldInteractions")
	_check(world.interaction_applied.is_connected(player._on_interaction_applied) and loop.phase_changed.is_connected(player._on_phase_changed), "the player listens for kick_stool and phase changes")
	await _sit_down(&"stool_counter_2", Vector3(3.6, 0.0, 2.0))
	player._on_interaction_applied(me, &"kick_stool", 0, {})  # what the signal delivers (emitting it here would run every other listener too)
	_check(not player.seated, "kick_stool clears it")
	await _sit_down(&"stool_counter_2", Vector3(3.6, 0.0, 2.0))
	player._on_phase_changed(GameLoop.Phase.ROUND_END)
	_check(not player.seated, "a phase change clears it")
	await _sit_down(&"stool_counter_3", Vector3(3.6, 0.0, 3.0))
	player._set_mode(Player.Mode.CUE)  # entering CUE (enter_cue calls stand_up first; the mode change is the backstop)
	_check(not player.seated, "CUE clears it")
	player._set_mode(Player.Mode.WALK)
	player.stand_up()
	# a sofa seat is lower: so is the camera
	await _sit_down(&"sofa_ne_1", Vector3(5.1, 0.0, -5.8))
	await create_timer(1.0).timeout
	var eye_sofa := Humanoid.sit_hip_y(Bar.SOFA_TOP) + Player.EYE_M - Humanoid.ORIGIN[Humanoid.B.PELVIS].y
	_check(absf(player.cam.global_position.y - eye_sofa) < 0.03 and player.cam.global_position.y < 1.3, "sofa: the camera lowers further (%.3f vs %.3f)" % [player.cam.global_position.y, eye_sofa])
	_check(player.prompt == "Stand up", "seated with nothing in reach: the prompt offers 'Stand up' ('%s')" % player.prompt)
	player.interact()
	_check(not player.seated, "...and Use does it")
	puppet.queue_free()


func _sit_down(id: StringName, from: Vector3) -> void:
	var seat := _seat(id)
	var t := _target_at(from, seat.global_position)
	_check(t == seat, "facing %s offers it" % id)
	player.interact()
	_check(player.seated, "sat on %s" % id)
	await physics_frame
