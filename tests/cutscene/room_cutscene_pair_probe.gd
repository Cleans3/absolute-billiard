extends SceneTree
# PAIR_TIMEOUT=150
## The cutscenes over the network (adhoc-1013c F3b: 04 §5 `cutscene_cue` + `cutscene_ack`, 09 §3.8 "waiting for each other"), two peers on a
## manual cutscene clock, run through tests/net/pair.sh:
##   1. The intro: the host's cue starts it on BOTH peers with one seed; the host finishes its own copy first and Night 1 does NOT start (the
##      campaign waits for the client's ack); the client finishes, acks, and the campaign starts on both with the intro's seed.
##   2. The failure: GAME_OVER plays the failure sequence on both from the phase alone, each ends on its stats card on black; the host presses
##      Continue first and does not leave (it waits for the client's Continue); the client's Continue (an ack) releases it.
##   3. The win: both ride the truck; the host presses Continue, the client never does: the host's wait times out (max wait) and it leaves.
##   tests/net/pair.sh tests/cutscene/room_cutscene_pair_probe.gd
## Prints `ROOM CUTSCENE HOST OK` / `ROOM CUTSCENE CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var loop: GameLoop
var director: CutsceneDirector
var cs: CutscenePlayer
var left := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("ROOM CUTSCENE %s FAIL: %s" % [role.to_upper(), msg])
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


func _wait_flag(name: String, sec := 40.0) -> void:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, sec)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


## Steps whatever is on to the end of the sequence (or to the open-ended truck).
func _play_out() -> void:
	var guard := 0
	while cs.is_playing() and not (cs.current is TruckOutro) and guard < 600:
		if cs.current != null:
			cs.current.step(0.25)
		guard += 1


func _stats_card() -> RunStatsCard:
	if director.card == null:
		return null
	for c in director.card.get_children():
		if c is RunStatsCard:
			return c
	return null


func _run() -> void:
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/checkpoints")
	SaveManager.root = dir
	CutsceneDirector.skip_cutscenes = false
	CutsceneDirector.manual_clock = true
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
	loop = level.get_node("GameLoop")
	director = level.get_node("CutsceneDirector")
	cs = director.cutscenes
	director.leave_handler = func() -> void: left += 1
	await _intro()
	await _failure()
	await _win()
	print("ROOM CUTSCENE %s OK" % role.to_upper())
	quit(0)


func _intro() -> void:
	await _until(func() -> bool: return cs.is_playing() and cs.playing_id == &"intro", "the intro starts on this peer")
	var seed_seen: int = cs.current.cut_seed
	await _check(seed_seen != 0 and loop.campaign_seed == 0, "Night 1 has not started when the intro does")
	await _check(cs.current is IntroVan and not cs.current.skippable, "a first watch cannot be skipped")
	if role == "host":
		_play_out()
		await _check(not cs.is_playing() and loop.campaign_seed == 0 and director._waiting, "host: its own intro is over, the campaign waits for the client's ack")
		_flag_seed(seed_seen)
		_flag("host_intro_done")
		await _until(func() -> bool: return loop.campaign_seed != 0, "the client's ack starts the campaign")
	else:
		await _wait_flag("host_intro_done")
		await _check(cs.is_playing() and loop.campaign_seed == 0, "client: still on its own intro when the host has finished")
		await _check(seed_seen == _read_seed(), "both peers play the intro with the host's seed")
		_play_out()
		await _until(func() -> bool: return loop.campaign_seed != 0, "round_state reaches the client: the host started the campaign")
	await _check(loop.campaign_seed == seed_seen, "the campaign runs on the intro's seed")
	await _check(not cs.is_playing() and SaveManager.cutscene_seen(&"intro"), "the intro is over and seen")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	(level.get_node("UILayer/StoryCards") as StoryCards).close()
	var players := level.get_node("PlayerSlots").get_children()
	for slot in players:
		var p := (slot as PlayerSlot).player
		await _check(p.visible and p.humanoid.transform.is_equal_approx(Transform3D.IDENTITY), "everyone is upright and in the room after the throw")
	await _check((level.get_node("EntranceDoor") as EntranceDoor).is_locked(), "the door is bolted on both peers")


func _flag_seed(seed_value: int) -> void:
	var f := FileAccess.open(_file("seed"), FileAccess.WRITE)
	f.store_string(str(seed_value))
	f.close()


func _read_seed() -> int:
	return int(FileAccess.get_file_as_string(_file("seed")))


func _failure() -> void:
	if role == "host":
		await _wait_flag("client_ready_fail")
		loop._set_phase(GameLoop.Phase.GAME_OVER)
	else:
		_flag("client_ready_fail")
	await _until(func() -> bool: return cs.is_playing() and cs.playing_id == &"fail", "the failure sequence starts from the phase")
	await _check((level.get_node("UILayer/PhaseScreen") as PhaseScreen).visible == false, "no Game over screen under the cutscene")
	_play_out()
	await _check(director.card != null and director.card.fade.color.a >= 0.999, "the stats card is up on black")
	var card := _stats_card()
	await _check(card != null and (card.get_node("%Grade") as Label).text == RunStats.grade_of(loop.run_stats.to_dict()), "...with the run's grade (the client holds the host's tally)")
	var close_btn := card.get_node("%Close") as Button
	if role == "host":
		close_btn.pressed.emit()
		await _check(left == 0 and director._waiting, "host: Continue does not leave while the client is still on its card")
		_flag("host_continued")
		await _until(func() -> bool: return left == 1, "the client's Continue releases the host")
	else:
		await _wait_flag("host_continued")
		await _check(left == 0, "client: nobody has left yet")
		close_btn.pressed.emit()
		await _until(func() -> bool: return left == 1, "the client leaves right after its own Continue")
		_flag("client_continued")
	await _wait_flag("client_continued")
	director._close_card()
	director._over = true


func _win() -> void:
	if role == "host":
		await _wait_flag("client_ready_win")
		loop.night_index = 2  # the finale: the Night with ending cards
		loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	else:
		_flag("client_ready_win")
	await _until(func() -> bool: return cs.is_playing() and cs.playing_id == &"win", "the win sequence starts from the phase")
	await _check(loop.mode == GameLoop.MODE_CAMPAIGN, "the Campaign mode reached this peer")
	left = 0
	_play_out()
	await _check(cs.current is TruckOutro, "both peers ride the truck")
	var truck := cs.current as TruckOutro
	truck.step(30.0)
	await _check(truck._card.visible, "the stats card is up on the truck")
	if role == "host":
		(truck._card.get_node("%Close") as Button).pressed.emit()
		await _check(left == 0 and director._waiting, "host: Continue waits for the client")
		director._wait_left = 0.2  # the client never presses Continue: the max wait lets the host go
		await _until(func() -> bool: return left == 1, "the max wait releases the host")
		_flag("host_released")
	else:
		await _wait_flag("host_released")
		await _check(cs.is_playing() and left == 0, "client: still riding, it never pressed Continue")
