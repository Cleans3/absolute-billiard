extends SceneTree
## A Round ends (or the table is staged) under a player who is aiming (adhoc-1014a V10, S5): the shooter leaves CUE, ends standing on
## the floor where they stood before aiming, the head camera is the current one and its transform is sane, the guide is gone, and a
## cue ball freed under an aiming player (the clean-up queue_frees every ball) neither errors nor leaves them pinned to it.
##   godot --path . --headless -s tests/player/round_end_cue_probe.gd        prints ROUND END CUE OK (any SCRIPT ERROR in the output = fail)

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var player: Player
var cue: CueController
var loop: GameLoop


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("ROUND END CUE FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


## Walk to the cue ball, become the shooter, enter CUE.
func _aim() -> bool:
	var b := _cue_ball()
	player.global_position = Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0
	rd.current_shooter_id = root.multiplayer.get_unique_id()
	var ok := player.enter_cue()
	await _frames(3)
	return ok and player.mode == Player.Mode.CUE and cue.active


## Standing again: WALK, the cue idle and its guide hidden, on the floor, the head camera current and its transform finite.
func _standing(what: String, home: Vector3) -> void:
	_check(player.mode == Player.Mode.WALK, "%s: back in WALK (mode %d)" % [what, player.mode])
	_check(not cue.active and not cue.guide.visible, "%s: the cue is idle and its guide gone" % what)
	_check(player.cam.current, "%s: the head camera is the current one" % what)
	var o := player.cam.global_transform.origin
	_check(o.is_finite() and player.cam.global_transform.basis.is_finite() and player.global_position.is_finite(), "%s: camera and body transforms are finite" % what)
	_check(absf(player.global_position.y - home.y) < 0.1, "%s: standing on the floor (y %.2f, was %.2f)" % [what, player.global_position.y, home.y])
	_check(player.global_position.distance_to(home) < 0.05, "%s: back where they stood before aiming (%s vs %s)" % [what, player.global_position, home])
	_check(o.y > player.global_position.y + 1.0 and o.y < player.global_position.y + 2.2, "%s: the eye is at standing height (%.2f over the floor)" % [what, o.y - player.global_position.y])


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_round_end_cue"
	DirAccess.make_dir_recursive_absolute(SaveManager.root + "/checkpoints")
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	level = current_scene
	rd = level.get_node("RoundDirector")
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	cue = player.cue
	loop = level.get_node("GameLoop")
	loop.advance()
	await _frames(30)
	for i in 120:
		await physics_frame
	_check(player != null and loop.phase == GameLoop.Phase.ROUND_LIVE, "a Round is live")
	var home := Vector3.ZERO

	# 1. the Round ends while the shooter aims (the timer, the shots, a cleared table: same _end_round)
	_check(await _aim(), "1: the shooter is in CUE")
	home = _home()
	loop.call(&"_end_round", &"timer")
	await _frames(3)
	_standing("1 round end", home)

	# 2. the clean-up frees every ball under a player who is aiming: no error, they stand up
	await _next_round()
	_check(await _aim(), "2: the shooter is in CUE in the next Round")
	home = _home()
	var old := _cue_ball()
	rd.call(&"_clear_balls")
	await _frames(4)
	_check(not is_instance_valid(old), "2: the old cue ball is freed")
	_standing("2 freed ball", home)

	# 3. the table is staged (set-up or clean-up) under an aiming player
	loop.call(&"_end_round", &"timer")
	await _next_round()
	_check(await _aim(), "3: the shooter is in CUE in the third Round")
	home = _home()
	rd.staging = true
	await _frames(2)
	_standing("3 staging", home)
	rd.staging = false

	# 4. a phase that is not ROUND_LIVE (a reckoning, an Intermission) stands the shooter up too
	_check(await _aim(), "4: the shooter is in CUE again")
	home = _home()
	loop.phase_changed.emit(GameLoop.Phase.RECKONING)
	await _frames(2)
	_standing("4 reckoning", home)
	finished = true
	print("ROUND END CUE OK" if fails == 0 else "ROUND END CUE FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _home() -> Vector3:
	var b := _cue_ball()
	return Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)


## Intermission (or reckoning) -> the next Round is live.
func _next_round() -> void:
	for i in 4:
		await _frames(5)
		if loop.phase == GameLoop.Phase.ROUND_LIVE and _cue_ball() != null:
			break
		loop.advance()
		await _frames(20)
	for i in 90:
		await physics_frame
	_check(loop.phase == GameLoop.Phase.ROUND_LIVE and _cue_ball() != null, "a Round is live (phase %d)" % loop.phase)
