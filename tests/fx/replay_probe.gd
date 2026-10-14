extends SceneTree

## Instant replay (docs/plan/10 §3.7):
##  - the plan, pure: the clip is [key - 2.0, key + 0.8] clipped to the recording, slowed to 0.3x around the key pot, screen time inside
##    4-6 s, the warp monotonic from the clip's start to its end; positions interpolate, visibility holds; the wide camera stands past the
##    key pocket's long rail, the close one over the cloth, both above it and looking at what they frame;
##  - the rule: a paid trick of tier >= 2 or a cleared table, never a foul or a Shot with no scoring pot; the title is the best trick's;
##  - in the real MainLevel (solo): a real Shot is recorded; a decided replay starts after START_DELAY, hides every real ball, draws one
##    ghost per track through its own camera and holds input; any key skips it and everything comes back (balls, camera, input); one plays
##    to its end; the next Shot cancels one; a replay of the Round's last Shot holds the clean-up, which plays once it ends.
##   godot --path . --headless -s tests/fx/replay_probe.gd
## Prints REPLAY OK, or the failing checks and REPLAY FAIL (exit 1).

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var gl: GameLoop
var table: Table
var replay: InstantReplay
var stager: RoundStaging


func _init() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		if not finished:
			print("REPLAY FAIL (script error or hang)")
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
	_check(not InstantReplay.enabled, "the replay is off in a headless run by default (no older probe waits for one)")
	_plan_checks()
	_rule_checks()
	InstantReplay.enabled = true
	await process_frame
	SaveManager.root = "user://test_replay"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	Settings.set_value(&"instant_replay", true)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	level = current_scene
	rd = level.get_node("RoundDirector")
	gl = level.get_node("GameLoop")
	table = level.get_node("Table")
	stager = level.get_node_or_null("Staging") as RoundStaging
	replay = level.get_node_or_null("InstantReplay") as InstantReplay
	_check(replay != null and replay.round_director == rd and replay.table == table and replay.game_loop == gl, "MainLevel has an InstantReplay wired to its director, table and loop")
	if replay == null:
		_end()
		return
	gl.advance()  # GO LIVE
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and not rd.staging, "a live Round")
	for i in 120:
		await physics_frame

	await _shoot()
	_check(replay.frame_count() > 20, "a real Shot was recorded: %d frames" % replay.frame_count())
	_check(replay.sound_count() >= 2, "...with its table sounds (the strike and a hit at least): %d" % replay.sound_count())
	await _skip_flow()
	await _natural_end()
	await _cancel_by_shot()
	await _cleanup_hold()
	_end()


func _end() -> void:
	finished = true
	if fails == 0:
		print("REPLAY OK")
		quit(0)
	else:
		print("REPLAY FAIL: %d checks" % fails)
		quit(1)


# ---------------------------------------------------------------- pure

func _plan_checks() -> void:
	var times := PackedFloat32Array()
	var a := PackedVector3Array()  # the key ball: 1 m/s along +x from x = -1, into a pocket at x = 2.5
	var b := PackedVector3Array()  # a ball that is potted at 1.5 s
	var sa := PackedByteArray()
	var sb := PackedByteArray()
	for k in 241:  # 4 s at 60 fps
		var t := k / 60.0
		times.append(t)
		a.append(Vector3(-1.0 + t, 0.0, 0.5))
		b.append(Vector3(0.0, 0.0, -0.5))
		sa.append(1)
		sb.append(1 if t < 1.5 else 0)
	var tracks: Array[PackedVector3Array] = [a, b]
	var shown: Array[PackedByteArray] = [sa, sb]
	var half_w := 1.27
	var pocket := Vector3(2.5, 0.0, half_w)
	var p := ReplayPlan.make(times, tracks, shown, 0, 3.5, pocket, Transform3D.IDENTITY, half_w)
	_check(is_equal_approx(p.t0, 1.5) and is_equal_approx(p.t1, 4.0), "clip [key - 2.0, key + 0.8] clipped to the recording: [%.2f, %.2f]" % [p.t0, p.t1])
	_check(p.length() > 4.0 and p.length() < 6.0, "screen time 4-6 s: %.2f" % p.length())
	_check(is_equal_approx(p.source_time(0.0), p.t0) and absf(p.source_time(p.length()) - p.t1) < 0.01, "the warp runs from the clip's start to its end")
	var prev := -1.0
	var mono := true
	for i in 200:
		var s := p.source_time(p.length() * i / 199.0)
		mono = mono and s >= prev
		prev = s
	_check(mono, "the warp never runs backwards")
	_check(is_equal_approx(p.speed_at(3.5), ReplayPlan.SLOW) and is_equal_approx(p.speed_at(1.6), 1.0), "0.3x at the key pot, 1x well before it")
	_check(p.is_slow(3.5) and not p.is_slow(2.0), "SLOW-MO only around the key pot")
	_check(p.position(0, 2.25).distance_to(Vector3(1.25, 0.0, 0.5)) < 0.001, "positions interpolate between frames")
	_check(p.visible(1, 1.0) and not p.visible(1, 2.0), "a potted ball is not drawn after it went")
	_check(p.approach_dir().distance_to(Vector3.RIGHT) < 0.01, "the approach is read from the key ball's run")
	var wide := p.wide_pose(2.0)
	_check(wide[0].z > half_w and wide[0].y > half_w * 0.5, "the wide shot stands past the key pocket's long rail, above the cloth: %s" % str(wide[0]))
	var close := p.close_pose()
	_check(absf(close[0].z) < half_w and close[0].x < pocket.x and close[0].y > 0.1, "the close shot is over the cloth, behind the ball's run, above it: %s" % str(close[0]))
	for s in [p.t0, 3.0, 3.5, p.t1]:
		var xf := p.camera(s)
		var look: Vector3 = p.position(0, s) if s < 2.5 else pocket
		_check((-xf.basis.z).dot((look - xf.origin).normalized()) > 0.5, "the camera faces what it frames at %.2f s" % s)
	var short := ReplayPlan.make(times, tracks, shown, 0, 0.5, pocket, Transform3D.IDENTITY, half_w)
	_check(is_zero_approx(short.t0), "a pot early in the Shot starts the clip at the strike")
	var fly := short.close_window()
	_check(fly.x >= short.t0 + 0.2 and fly.y <= short.key_time + 0.001 and fly.y > fly.x, "...still opens on the wide shot and has flown in by the pot: [%.2f, %.2f]" % [fly.x, fly.y])
	_check(short.camera(short.t0).origin.distance_to(short.wide_pose(short.t0)[0]) < 0.001, "...the first frame is the wide shot")
	var normal := p.close_window()
	_check(is_equal_approx(normal.y, p.key_time - ReplayPlan.SLOW_BEFORE), "with a full run-up the camera lands as the slow window opens")


func _rule_checks() -> void:
	var cases := [  # trick ids, scoring pots, foul, cleared, expected
		[[&"Carom"], 1, false, false, true],
		[[&"KickShot"], 2, false, false, true],
		[[&"RailRunner"], 1, false, false, true],
		[[&"Combo3"], 3, false, false, true],
		[[&"BankShot"], 1, false, false, false],
		[[&"Combo"], 2, false, false, false],
		[[&"Combo", &"Carom"], 2, false, false, true],
		[[], 1, false, true, true],
		[[], 1, false, false, false],
		[[&"Carom"], 0, false, false, false],
		[[&"Carom"], 1, true, false, false],
		[[], 1, true, true, false],
	]
	for c in cases:
		var ids: Array[StringName] = []
		ids.assign(c[0])
		_check(InstantReplay.qualifies(ids, c[1], c[2], c[3]) == c[4], "qualifies(%s, pots %d, foul %s, cleared %s) == %s" % [str(c[0]), c[1], c[2], c[3], c[4]])
	var two: Array[StringName] = [&"Combo", &"Carom"]
	_check(InstantReplay.title_for(two) == "CAROM!", "the title is the best trick's: %s" % InstantReplay.title_for(two))
	_check(InstantReplay.title_for([] as Array[StringName]) == InstantReplay.CLEARED_TITLE, "a clear with no trick reads TABLE CLEARED!")


# ---------------------------------------------------------------- the level

func _cue() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


## A real Shot at the nearest object ball; returns once it has ended.
func _shoot() -> void:
	var cue := _cue()
	var target: Ball = null
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.is_pocketed and (target == null or b.global_position.distance_to(cue.global_position) < target.global_position.distance_to(cue.global_position)):
			target = b
	var d := target.global_position - cue.global_position
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 0.6
	intent.shooter_id = 1
	table.sim.request_shot(intent)
	await rd.shot_ended
	await process_frame


## Makes the last recorded Shot worth a replay, as if it had potted its first object ball with a Carom.
func _decide() -> void:
	replay.cancel()
	var track := -1
	for b in rd.get_balls():
		if not b.is_cue_ball and replay._index.has(b):
			track = replay._index[b]
			break
	var t_last: float = replay._times[replay._times.size() - 1]
	replay._pots = [{t = t_last * 0.6, track = track, pocket = table.pockets.keys()[0]}]
	var ids: Array[StringName] = [&"Carom"]
	replay.recording = true
	replay._on_shot_ended("probe", 1, 10, ids, false)
	_check(replay.holds_table() and not replay.is_playing(), "a decided replay waits START_DELAY before it starts")


func _all_hidden(want_hidden: bool) -> bool:
	for b in rd.get_balls():
		if b.visible == want_hidden:
			return false
	return true


func _skip_flow() -> void:
	var cam_before := root.get_viewport().get_camera_3d()
	_decide()
	if not await _until(replay.is_playing, "the replay to start", InstantReplay.START_DELAY + 2.0):
		return
	var cut := replay.cut
	_check(_all_hidden(true), "every real ball is hidden while the replay plays")
	_check(cut.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D).size() == replay._tracks.size(), "one ghost per recorded ball")
	_check(root.get_viewport().get_camera_3d() == cut.camera, "the replay's camera is the current one")
	_check(UIRouter.blocking(), "the replay holds the game's input")
	_check(cut.camera.cull_mask == StreamTv.FEED_MASK, "the replay camera draws what a TV feed draws (no lamp, no aim guide)")
	await create_timer(0.5).timeout
	var ended := [false, false]
	replay.ended.connect(func(skipped: bool) -> void:
		ended[0] = true
		ended[1] = skipped, CONNECT_ONE_SHOT)
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	await _until(func() -> bool: return ended[0], "any key to skip the replay", 2.0)
	_check(ended[1], "...and it reports skipped")
	await process_frame
	_check(not replay.is_playing() and not replay.holds_table(), "nothing is left playing or pending")
	_check(_all_hidden(false), "every real ball is back")
	_check(root.get_viewport().get_camera_3d() == cam_before, "the player's camera is back")
	_check(not UIRouter.blocking(), "input is released")


func _natural_end() -> void:
	_decide()
	if not await _until(replay.is_playing, "the second replay to start", InstantReplay.START_DELAY + 2.0):
		return
	var cut := replay.cut
	var length := cut.length_sec()
	var expect := 0
	for e in cut.sounds:
		if float(e.t) > cut.plan.t0 and float(e.t) <= cut.plan.t1:
			expect += 1
	var sfx := root.get_node_or_null(^"Sfx")
	var clacks_before := _table_sounds_played(sfx)
	var t0 := Time.get_ticks_msec()
	var skipped := [true]
	var done := [false]
	var played := [-1]
	replay.ended.connect(func(s: bool) -> void:
		done[0] = true
		played[0] = cut.sounds_played
		skipped[0] = s, CONNECT_ONE_SHOT)
	await _until(func() -> bool: return done[0], "the replay to play to its end", length + 3.0)
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	_check(not skipped[0], "a replay left alone ends by itself, not skipped")
	_check(took > length - 0.5 and took < length + 1.5, "...after its own length: %.2f s for %.2f s" % [took, length])
	_check(expect > 0 and played[0] == expect, "the Shot's table sounds inside the clip are heard again, once each: %d of %d" % [played[0], expect])
	_check(sfx == null or _table_sounds_played(sfx) - clacks_before >= expect, "...through Sfx (%d more table sounds)" % (_table_sounds_played(sfx) - clacks_before))
	await process_frame
	_check(_all_hidden(false), "every real ball is back after a full replay")


func _table_sounds_played(sfx: Node) -> int:
	if sfx == null:
		return 0
	var n := 0
	var stats: Dictionary = sfx.get(&"stats")
	for k: StringName in stats:
		if String(k).begins_with("clack_") or String(k).begins_with("rail_") or k == &"cue_tip" or k == &"pocket_drop":
			n += int(stats[k])
	return n


func _cancel_by_shot() -> void:
	_decide()
	if not await _until(replay.is_playing, "the third replay to start", InstantReplay.START_DELAY + 2.0):
		return
	var at_start := [false, false]  # [playing, every ball drawn] the moment the next Shot starts
	table.sim.shot_started_net.connect(func(_id: int, _shooter: int, _tick: int) -> void:
		at_start[0] = replay.is_playing()
		at_start[1] = _all_hidden(false), CONNECT_ONE_SHOT)
	await _shoot()  # the next Shot's start cancels it
	_check(not at_start[0], "the next Shot cancels a replay on screen")
	_check(at_start[1], "...and the real balls are back for it")
	await create_timer(InstantReplay.START_DELAY + 0.5).timeout
	if replay.is_playing():  # the Shot just played may itself have been worth one
		replay.cancel()


func _cleanup_hold() -> void:
	if stager == null:
		_check(false, "MainLevel has a Staging node")
		return
	RoundDirector.skip_staging = false
	_decide()
	rd.end_round()  # the Round's last Shot: its clean-up must wait for this replay
	_check(rd.staging and rd.is_cleanup_held() and not stager.is_playing(), "the clean-up is held (staging on, the pit not opening) while a replay is decided")
	if not await _until(replay.is_playing, "the held Round's replay to start", InstantReplay.START_DELAY + 2.0):
		return
	_check(not stager.is_playing(), "...and still while it plays")
	replay.cancel()
	await process_frame
	_check(stager.is_playing() and stager.kind == RoundStaging.KIND_CLEANUP and not rd.is_cleanup_held(), "the clean-up plays once the replay ends")
	await _until(func() -> bool: return not rd.staging, "the clean-up to finish", StagingPlan.CLEANUP_SEC + 3.0)
	_check(rd.get_balls().is_empty(), "the table is cleared after the held clean-up")
	RoundDirector.skip_staging = true
