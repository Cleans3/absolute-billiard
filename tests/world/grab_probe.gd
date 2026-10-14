extends SceneTree
## Step 4 of the held cue (docs/plan/08 §2.9, 06 P57), one process, the real MainLevel (Solo):
##  - grab a ball: the moving prompt sits on the object ball in front of the player; the grab hides the real ball (frozen, no collider),
##    shows a replica in the hand, charges the scratch fine, and no Shot starts while it is out (`ball_out`); thrown, the replica flies,
##    and once it lands the real ball is back on the cloth, collider on; a second grab of the Night also shocks the grabber limp; held
##    too long it slips back by itself; out of reach is `too_far`, the host toggle off is `hostile_off`;
##  - footprints: walking on the table leaves prints on the dirt image; the towel (take it, wipe, hang it back) clears them.
##   godot --path . --headless -s tests/world/grab_probe.gd
## Prints GRAB OK, or the failing checks and GRAB FAIL (exit 1).

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var gl: GameLoop
var grab: BallGrab
var prints: Footprints
var world: WorldInteractions
var table: Table
var player: Player
var _rejected: Array = []


func _init() -> void:
	create_timer(170.0).timeout.connect(func() -> void:
		if not finished:
			print("GRAB FAIL (script error or hang)")
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
	print("GRAB OK" if fails == 0 else "GRAB FAIL: %d checks" % fails)
	quit(0 if fails == 0 else 1)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_grab"
	DirAccess.make_dir_recursive_absolute(SaveManager.root.path_join("checkpoints"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	level = current_scene
	rd = level.get_node("RoundDirector")
	gl = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	table = level.get_node("Table")
	grab = level.get_node_or_null("BallGrab") as BallGrab
	prints = level.get_node_or_null("Footprints") as Footprints
	player = level.get_node("PlayerSpawner").call(&"get_local_player") as Player
	_check(grab != null and prints != null and prints.table == table, "MainLevel has BallGrab and Footprints")
	if grab == null or prints == null:
		_end()
		return
	world.interaction_rejected.connect(func(kind: StringName, reason: StringName) -> void: _rejected.append([kind, reason]))
	gl.advance()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and not rd.staging, "a live Round")
	for i in 60:
		await physics_frame
	await _grab_checks()
	await _footprint_checks()
	_end()


func _ball(net_id: int) -> Ball:
	for b in rd.get_balls():
		if b.net_id == net_id:
			return b
	return null


func _target() -> Ball:
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.is_pocketed and not b.retired and not grab.out.has(b.net_id):
			return b
	return null


## Stands the player `d` m from `b`, facing it.
func _face(b: Ball, d := 1.2) -> void:
	var away := Vector3(0.0, 0.0, 1.0) if b.global_position.z < table.global_position.z + 0.5 else Vector3(0.0, 0.0, -1.0)
	var at := b.global_position + away * d
	player.global_position = Vector3(at.x, 0.0, at.z)
	player.velocity = Vector3.ZERO
	var to := b.global_position - player.global_position
	player.rotation.y = atan2(-to.x, -to.z)
	for i in 4:
		await physics_frame


func _grab_checks() -> void:
	var b := _target()
	_check(b != null, "an object ball on the table")
	if b == null:
		return
	await _face(b)
	var prop := grab.get_node("Prop") as Interactable
	await _until(func() -> bool: return prop.global_position.y > -10.0, "the prompt on a ball in front", 3.0)
	b = _ball(prop.target_id)  # the nearest one in front of the player: the one the prompt names
	if b == null:
		_check(false, "the prompt names a ball")
		return
	_check(prop.prompt == BallGrab.PROMPT_TEXT and prop.global_position.distance_to(Vector3(b.global_position.x, 0.0, b.global_position.z)) < 0.05, "the prompt sits on it: '%s'" % prop.prompt)
	var cash0 := gl.economy.cash
	var fine := EconomyManager.fine_for(gl.current_night())
	var spot0 := b.global_position
	prop.try_use({})
	await process_frame
	await physics_frame
	_check(grab.out.has(b.net_id) and grab.held.get(1, -1) == b.net_id, "grabbed: the ball is out, in my hand")
	_check(not b.visible and b.freeze and (b.get_node("Shape") as CollisionShape3D).disabled, "the real ball is hidden, frozen, its collider off")
	_check(grab.get_node_or_null("Replica%d" % b.net_id) != null, "a replica in the hand")
	_check(gl.economy.cash == cash0 - fine, "the crew paid the scratch fine: %d -> %d" % [cash0, gl.economy.cash])
	var intent := ShotIntent.new()
	intent.power = 0.5
	intent.aim_dir = Vector2.RIGHT
	_check(rd._validate_shot(1, intent) == &"ball_out", "no Shot while a ball is out: %s" % rd._validate_shot(1, intent))
	player.global_position = Vector3(0.0, 0.0, 2.5)
	player.rotation.y = PI
	for i in 3:
		await physics_frame
	var thrown := {}
	var on_apply := func(_p: int, k: StringName, _t: int, pl: Dictionary) -> void:
		if k == BallGrab.THROW:
			thrown.merge(pl)
	world.interaction_applied.connect(on_apply)
	player.throw_cue()  # G: the ball goes before any cue
	await process_frame
	world.interaction_applied.disconnect(on_apply)
	_check(not thrown.is_empty() and not grab.holds(1), "thrown: out of the hand")
	if thrown.is_empty():
		return
	await _until(func() -> bool: return not grab.out.has(b.net_id), "the ball back on the table", float(thrown.t_land) + 2.0)
	for i in 30:
		await physics_frame
	var l := table.to_local(b.global_position)
	_check(b.visible and not (b.get_node("Shape") as CollisionShape3D).disabled, "back: shown, collider on (resting balls freeze again on their own)")
	_check(absf(l.x) <= table.spec.length_m * 0.5 and absf(l.z) <= table.spec.width_m * 0.5 and absf(l.y - (table.spec.bed_height_m + b.radius)) < 0.02, "...on the cloth: %s" % str(l))
	_check(b.global_position.distance_to(spot0) < table.spec.width_m, "...near where it was")
	_check(rd._validate_shot(1, intent) == &"", "Shots are open again ('%s')" % rd._validate_shot(1, intent))
	# the second grab of the Night: the ZAP
	b = _target()
	await _face(b)
	await _until(func() -> bool: return prop.global_position.y > -10.0, "the prompt on the next ball", 3.0)
	b = _ball(prop.target_id)
	prop.try_use({})
	await process_frame
	_check(grab.offenses.get(1, 0) == 2 and grab.holds(1), "a second grab: offense 2")
	await _until(func() -> bool: return player.mode == Player.Mode.RAGDOLL, "the second grab shocks the grabber limp", 2.0)
	var sink := level.get_node("DishStation") as DishStation
	_check(sink.find_children("*", "Label3D", true, false).any(func(x: Label3D) -> bool: return x.text == "ZAP!"), "a ZAP! over them")
	await _until(func() -> bool: return not grab.out.has(b.net_id), "a held ball slips back by itself", BallGrab.HOLD_MAX_SEC + 3.0)
	_check(not grab.holds(1) and b.visible, "slipped back: the hand is empty, the ball shown")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, "standing again", 5.0)
	# refusals
	await _until(func() -> bool: return rd.table.sim.awake == 0, "the slipped ball to settle", 5.0)
	b = _target()
	player.global_position = Vector3(0.0, 0.0, 4.0)
	await physics_frame
	_rejected.clear()
	world.request(BallGrab.GRAB, b.net_id, {})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"too_far", "from across the room: too_far %s" % str(_rejected))
	world.hostile_policy = WorldInteractions.HostilePolicy.OFF
	await _face(b)
	_rejected.clear()
	world.request(BallGrab.GRAB, b.net_id, {})
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"hostile_off", "the host toggle off: hostile_off %s" % str(_rejected))
	world.hostile_policy = WorldInteractions.HostilePolicy.ON


func _footprint_checks() -> void:
	prints.clear_all()
	await process_frame
	_check(prints.dirt_fraction() == 0.0, "a clean cloth")
	var spec := table.spec
	var lid := spec.bed_height_m + spec.rail_height_m
	var path: Array[Vector2] = []
	for i in 9:
		path.append(Vector2(-1.2 + i * 0.35, 0.3))
	for pt in path:
		player.global_position = table.to_global(Vector3(pt.x, lid + 0.02, pt.y))
		player.velocity = Vector3.ZERO
		for k in 3:
			await process_frame
	await create_timer(0.2).timeout
	var dirt := prints.dirt_fraction()
	_check(dirt > 0.0005, "walking on the table leaves prints (%.4f of the cloth)" % dirt)
	var mid := Vector2(0.2, 0.3)
	var near := 0.0
	for dx in range(-20, 21, 2):
		for dz in range(-15, 16, 3):
			near = maxf(near, prints.dirt_at(mid + Vector2(dx * 0.01, dz * 0.01)))
	_check(near > 0.3, "...along the walked line (dirt %.2f near it)" % near)
	player.global_position = Vector3(0.0, 0.0, 2.0)  # off the table
	await physics_frame
	var hook := prints.get_node("Prop") as Interactable
	player.global_position = hook.global_position + Vector3(0.3, 0.0, 0.0)
	await physics_frame
	hook.try_use({})
	await process_frame
	_check(prints.holds_towel(1) and hook.prompt == "Hang the towel back", "the towel taken")
	_rejected.clear()
	var b := _target()
	if b != null:
		world.request(BallGrab.GRAB, b.net_id, {})
		await process_frame
		_check(_rejected.size() >= 1 and _rejected[-1][1] in [&"hands_full", &"too_far"], "a grab with the towel in hand is refused %s (awake %d, shot %s, staging %s)" % [str(_rejected), rd.table.sim.awake, rd.shot_in_progress, rd.staging])
	var at := table.to_global(Vector3(mid.x, spec.bed_height_m, mid.y))
	player.global_position = table.to_global(Vector3(mid.x, 0.0, spec.width_m * 0.5 + 0.5))
	await physics_frame
	for k in 4:
		prints.request_wipe(at + Vector3((k - 1.5) * 0.25, 0.0, 0.0))
		await create_timer(0.4).timeout
	var left := 0.0
	for dx in range(-20, 21, 2):
		for dz in range(-15, 16, 3):
			left = maxf(left, prints.dirt_at(mid + Vector2(dx * 0.01, dz * 0.01)))
	_check(left < near * 0.4, "the towel wipes them (%.2f -> %.2f)" % [near, left])
	player.global_position = Vector3(0.0, 0.0, 4.0)
	await physics_frame
	_rejected.clear()
	prints.request_wipe(at)
	await process_frame
	_check(_rejected.size() == 1 and _rejected[0][1] == &"not_at_table", "wiping from across the room: not_at_table %s" % str(_rejected))
	player.global_position = hook.global_position + Vector3(0.3, 0.0, 0.0)
	await physics_frame
	hook.try_use({})
	await process_frame
	_check(not prints.holds_towel(1) and prints.towel_holder == 0, "the towel hung back")
