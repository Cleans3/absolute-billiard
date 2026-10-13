extends SceneTree
## The Round's set-up and clean-up (docs/plan/01 §3, 06 P33 U15/U16/A4, adhoc-1013c W5), one process, the real MainLevel (Solo):
##  - the plan itself: set-up <= 5 s and clean-up <= 3 s for any ball count, reveals inside the beam window, in net_id order, the vent open
##    before the saucer leaves and shut once it is below the mouth;
##  - the gates: `RoundDirector.staging` stops can_strike (and says `staging` to the validator), the Round clock does not run, GO LIVE is refused
##    at the pedestal while the last Round is cleared, `skip_staging` turns the whole thing off;
##  - set-up reveals EVERY ball (the authored Night 1 triangle, a finale rack, a Poisson rack with every gimmick ball type, a one-ball rack),
##    the cue ball and the gimmicks included, each through the same Materialise overlay, back to a plain opaque ball at the end;
##  - clean-up: the cloth is swapped for 8 flaps, every ball becomes a ghost that rides its flap, falls into the pit and vanishes, the table is
##    then cleared and the cloth is back;
##  - nothing in either sequence owns a collision object.
##   godot --path . --headless -s tests/world/staging_probe.gd
## Prints STAGING OK, or the failing checks and STAGING FAIL (exit 1).

const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")
const NIGHT_5 := preload("res://src/resources/nights/night_5.tres")
const SEED := 20261013

var fails := 0
var finished := false
var level: Node
var rd: RoundDirector
var gl: GameLoop
var stager: RoundStaging
var vent: Vent
var table: Table
var _staging_log: Array = []  # [on, msec] per staging_changed


func _init() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		if not finished:
			print("STAGING FAIL (script error or hang)")
			quit(1))
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _until(cond: Callable, what: String, sec := 20.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_check(false, "timeout waiting for " + what)
			return


func _on_staging(on: bool) -> void:
	_staging_log.append([on, Time.get_ticks_msec()])


func _cue(balls: Array[Ball]) -> Ball:
	for b in balls:
		if b.is_cue_ball:
			return b
	return null


func _run() -> void:
	_plan_checks()
	_check(RoundDirector.skip_staging == (DisplayServer.get_name() == "headless"), "skip_staging defaults to 'headless' (probes, tools): %s" % RoundDirector.skip_staging)
	await process_frame
	SaveManager.root = "user://test_staging"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, false, true)
	level = current_scene
	rd = level.get_node("RoundDirector")
	gl = level.get_node("GameLoop")
	stager = level.get_node_or_null("Staging") as RoundStaging
	vent = level.get_node_or_null("Vent") as Vent
	table = level.get_node("Table")
	_check(stager != null and vent != null and level.get_node_or_null("Trapdoor") is Trapdoor, "MainLevel has Staging, Vent and Trapdoor")
	_check(not RoundDirector.skip_staging, "SoloSupport.until_playable(keep_staging) leaves the pictures on")
	rd.staging_changed.connect(_on_staging)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "the first Intermission")

	await _live_flow()
	await _racks()
	await _cleanup_flow()
	await _go_live_gate()
	await _skip_and_abort()

	finished = true
	if fails == 0:
		print("STAGING OK")
		quit(0)
	else:
		print("STAGING FAIL: %d checks" % fails)
		quit(1)


# ---------------------------------------------------------------- the schedule itself (no scene)

func _plan_checks() -> void:
	for n in [1, 2, 5, 11, 13, 16, 24, 40, 64]:
		_check(StagingPlan.setup_duration(n) <= StagingPlan.SETUP_MAX_SEC, "set-up of %d balls fits %.1f s: %.2f" % [n, StagingPlan.SETUP_MAX_SEC, StagingPlan.setup_duration(n)])
		var prev := -1.0
		for i in n:
			var r := StagingPlan.reveal_start(i, n)
			_check(r > prev and r >= StagingPlan.BEAM_FROM and r < StagingPlan.BEAM_FROM + StagingPlan.BEAM_WINDOW + 0.001, "reveal %d of %d inside the beam window, in order: %.3f" % [i, n, r])
			prev = r
		_check(is_equal_approx(StagingPlan.ball_progress(0, n, StagingPlan.BEAM_FROM - 0.01), 0.0), "nothing is there before the beam")
		_check(is_equal_approx(StagingPlan.ball_progress(n - 1, n, StagingPlan.last_in(n)), 1.0), "the last ball is solid at last_in")
	_check(StagingPlan.CLEANUP_SEC <= StagingPlan.CLEANUP_MAX_SEC, "clean-up fits %.1f s: %.2f" % [StagingPlan.CLEANUP_MAX_SEC, StagingPlan.CLEANUP_SEC])
	# the vent: shut at the start, open before the saucer leaves, shut again once it is out, and never open past the end
	_check(is_zero_approx(StagingPlan.vent_openness(0.0)), "vent shut at t = 0")
	_check(is_equal_approx(StagingPlan.vent_openness(StagingPlan.VENT_OPEN_SEC), 1.0) and StagingPlan.VENT_OPEN_SEC <= StagingPlan.UFO_OUT_FROM + 0.3, "vent fully open about when the saucer starts out")
	_check(StagingPlan.vent_openness(StagingPlan.UFO_OUT_FROM + 0.1) > 0.9, "...and open while it passes the mouth")
	_check(is_zero_approx(StagingPlan.vent_openness(StagingPlan.VENT_CLOSE_AT + StagingPlan.VENT_CLOSE_SEC)), "vent shut again after the saucer is out")
	_check(StagingPlan.VENT_CLOSE_AT + StagingPlan.VENT_CLOSE_SEC <= StagingPlan.BEAM_FROM + 0.001, "...before the first ball")
	_check(StagingPlan.ufo_flight(StagingPlan.VENT_CLOSE_AT) > 0.8, "the saucer is well out of the mouth when the louvres start to close")
	# the flaps: closed at 0 and at the end, hanging in between, a ball's release is before the flaps shut and after they start to open
	for k in StagingPlan.FLAPS:
		_check(is_zero_approx(StagingPlan.flap_angle(k, 0.0)) and is_zero_approx(StagingPlan.flap_angle(k, StagingPlan.CLEANUP_SEC)), "flap %d is flat at both ends" % k)
		_check(is_equal_approx(StagingPlan.flap_angle(k, (StagingPlan.flap_open_start(k) + StagingPlan.OPEN_SEC + StagingPlan.flap_shut_start(k)) * 0.5), deg_to_rad(StagingPlan.OPEN_DEG)), "flap %d hangs open in between" % k)
		for id in [0, 3, 7, 12]:
			var rel := StagingPlan.release_time(k, id)
			_check(rel > StagingPlan.flap_open_start(k) and rel < StagingPlan.flap_shut_start(k) - 0.3, "a ball on flap %d (net_id %d) lets go while the flap is opening: %.3f" % [k, id, rel])
	_check(StagingPlan.flap_rank(3) == 0 and StagingPlan.flap_rank(4) == 0 and StagingPlan.flap_rank(0) == StagingPlan.RANKS - 1 and StagingPlan.flap_rank(7) == StagingPlan.RANKS - 1, "flap ranks count from the middle outward")


# ---------------------------------------------------------------- a real Round start

func _live_flow() -> void:
	_staging_log.clear()
	gl.advance()  # GO LIVE, solo: the Round starts and the set-up begins
	var start_ms := Time.get_ticks_msec()
	var clock0 := gl.time_left
	var balls := rd.get_balls()
	var n := balls.size()
	var cue := _cue(balls)
	_check(rd.staging and gl.is_staging() and stager.kind == RoundStaging.KIND_SETUP, "the Round starts staged: rd.staging, the loop sees it, the stager is in set-up")
	_check(n >= 6 and cue != null, "a rack and a cue ball: %d balls" % n)
	var hidden := true
	for b in balls:
		hidden = hidden and not b.visible
	_check(hidden, "every ball is hidden when the Round starts (they exist, frozen, and are beamed in)")
	_check(not rd.can_strike(cue), "can_strike is false while staging")
	var intent := ShotIntent.new()
	intent.power = 0.5
	intent.aim_dir = Vector2.RIGHT
	intent.shooter_id = 1
	_check(rd._validate_shot(1, intent) == &"staging", "the shot validator says `staging`: %s" % rd._validate_shot(1, intent))
	var seen := {}  # net_id -> seconds since the Round started, first frame the ball was visible
	var clock_moved := false
	while rd.staging and Time.get_ticks_msec() - start_ms < 9000:
		await process_frame
		var el := (Time.get_ticks_msec() - start_ms) / 1000.0
		for b in balls:
			if b.visible and not seen.has(b.net_id):
				seen[b.net_id] = el
		clock_moved = clock_moved or absf(gl.time_left - clock0) > 0.0001
	var took := (Time.get_ticks_msec() - start_ms) / 1000.0
	_check(took <= StagingPlan.SETUP_MAX_SEC + 0.4, "set-up took %.2f s (budget %.1f)" % [took, StagingPlan.SETUP_MAX_SEC])
	_check(absf(took - StagingPlan.setup_duration(n)) < 0.5, "...about what the plan says for %d balls: %.2f" % [n, StagingPlan.setup_duration(n)])
	_check(not clock_moved, "the Round clock did not move during the set-up")
	_check(seen.size() == n, "every ball was shown: %d of %d" % [seen.size(), n])
	var ids: Array = seen.keys()
	ids.sort()
	for i in ids.size():
		var want := StagingPlan.reveal_start(i, n)
		_check(absf(float(seen[ids[i]]) - want) < 0.3, "ball %d (net_id %d) appeared at %.2f s, the plan says %.2f" % [i, ids[i], seen[ids[i]], want])
	_check(not rd.staging and stager.kind == &"", "staging ended with the sequence")
	_check(rd.can_strike(cue), "...and the cue ball can be struck again")
	_check(_staging_log.size() == 2 and _staging_log[0][0] == true and _staging_log[1][0] == false, "staging_changed fired true then false: %s" % [_staging_log])
	var plain := true
	for b in balls:
		var mesh := b.get_node("Mesh") as MeshInstance3D
		plain = plain and b.visible and mesh.material_overlay == null and is_zero_approx(mesh.transparency)
	_check(plain, "after the set-up every ball is a plain opaque ball again (no overlay, no fade)")
	_check(not (stager.get_node("Ufo") as Node3D).visible and not vent.is_open and is_zero_approx(vent.openness), "the saucer is gone and the vent is shut")
	var t_after := gl.time_left
	await create_timer(0.6).timeout
	_check(gl.time_left < t_after - 0.3, "the Round clock runs once the set-up has played: %.2f -> %.2f" % [t_after, gl.time_left])


# ---------------------------------------------------------------- one set-up per rack kind, sampled at fixed times

func _racks() -> void:
	var wild := NightConfig.new()
	wild.object_ball_count = 12
	var ids: Array[StringName] = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty", &"stone_ball", &"bomb_ball", &"split_ball", &"joker_ball"]
	wild.unlocked_ball_types = ids
	var cases := [
		["authored Night 1 triangle", NIGHT_1, 1, 11, []],
		["authored finale rack (Night 5)", NIGHT_5, 1, 11, []],
		["Poisson rack with every gimmick ball", wild, 0, 13, [&"bomb_ball", &"split_ball", &"joker_ball", &"stone_ball"]],
		["Poisson rack, Night 1 config", NIGHT_1, 0, 11, []],
	]
	RoundDirector.skip_staging = true  # the director places the balls and does not play: this probe plays the stager by hand
	for c in cases:
		if rd.shot_in_progress:
			await _until(func() -> bool: return not rd.shot_in_progress, "no live shot")
		rd.start_round(c[1], c[2], SEED)
		var balls := rd.get_balls()
		var n := balls.size()
		_check(n == int(c[3]), "%s: %d balls (want %d)" % [c[0], n, c[3]])
		var types := {}
		for b in balls:
			types[b.ball_type.id] = true
		for want: StringName in c[4]:
			_check(types.has(String(want)), "%s holds a %s" % [c[0], want])
		_check(_cue(balls) != null, "%s holds the cue ball" % c[0])
		await _walk_setup(c[0], balls)
	# a one-ball rack (just the cue ball), and the far end of the count range
	var cue_only: Array[Ball] = [_cue(rd.get_balls())]
	await _walk_setup("cue ball alone", cue_only)
	RoundDirector.skip_staging = false


## Plays `balls` through the stager by hand: sampled every 50 ms, every ball hidden then shown in net_id order, its overlay while it is not yet
## solid, the saucer and the beam where the plan puts them, the vent in step, a plain ball at the end.
func _walk_setup(label: String, balls: Array[Ball]) -> void:
	var n := balls.size()
	stager.play_setup(balls, false)
	var ordered := balls.duplicate()
	ordered.sort_custom(func(a: Ball, b: Ball) -> bool: return a.net_id < b.net_id)
	var ufo := stager.get_node("Ufo") as Ufo
	var dur := stager.duration()
	_check(dur <= StagingPlan.SETUP_MAX_SEC and is_equal_approx(dur, StagingPlan.setup_duration(n)), "%s: set-up %.2f s <= %.1f" % [label, dur, StagingPlan.SETUP_MAX_SEC])
	var shown_before := 0
	var t := 0.0
	var mid_checked := {}
	while t <= dur + 0.001:
		stager.seek(t)
		var shown := 0
		for b: Ball in ordered:
			if b.visible:
				shown += 1
		_check(shown >= shown_before, "%s: balls only ever appear (t=%.2f: %d after %d)" % [label, t, shown, shown_before])
		shown_before = shown
		for i in n:
			var b: Ball = ordered[i]
			var p := StagingPlan.ball_progress(i, n, t)
			_check(b.visible == (p > 0.0), "%s: ball %d is visible exactly once its beam has reached it (t=%.2f p=%.2f)" % [label, i, t, p])
			var mesh := b.get_node("Mesh") as MeshInstance3D
			if p > 0.1 and p < 0.65 and not mid_checked.has(i):
				mid_checked[i] = true
				_check(mesh.material_overlay != null and mesh.transparency > 0.0 and mesh.transparency < 1.0, "%s: ball %d (%s) is materialising: overlay %s, transparency %.2f" % [label, i, b.ball_type.id, mesh.material_overlay != null, mesh.transparency])
			if p >= 1.0:
				_check(mesh.material_overlay == null and is_zero_approx(mesh.transparency), "%s: ball %d is solid at t=%.2f" % [label, i, t])
		t += 0.05
	_check(mid_checked.size() == n, "%s: every ball was seen mid-materialise, the cue ball and the gimmicks included: %d of %d" % [label, mid_checked.size(), n])
	# the saucer and the vent at the moments that matter
	stager.seek(0.0)
	_check(not ufo.visible and is_zero_approx(vent.openness), "%s: t=0: no saucer, vent shut" % label)
	stager.seek(StagingPlan.UFO_OUT_FROM + 0.01)
	var mouth := vent.mouth_transform().origin
	_check(ufo.visible and vent.openness > 0.9 and ufo.global_position.y > mouth.y - 0.45 and absf(ufo.global_position.x - vent.global_position.x) < 0.5, "%s: the saucer sets off from inside the open vent: %s" % [label, ufo.global_position])
	stager.seek(StagingPlan.VENT_CLOSE_AT)
	_check(ufo.global_position.y < mouth.y - 0.5 and vent.openness > 0.95, "%s: it is below the mouth when the louvres start to close: y %.2f vs mouth %.2f" % [label, ufo.global_position.y, mouth.y])
	stager.seek(StagingPlan.BEAM_FROM)
	var hover_y := table.global_position.y + table.cloth_y() + RoundStaging.HOVER_ABOVE_BED
	_check(is_zero_approx(vent.openness) and absf(ufo.global_position.y - hover_y) < 0.05, "%s: the vent is shut and the saucer hovers at %.2f: %.2f" % [label, hover_y, ufo.global_position.y])
	for i in n:
		stager.seek(StagingPlan.reveal_start(i, n) + 0.001)
		var b: Ball = ordered[i]
		_check(ufo.beam_on and ufo.beam_target().distance_to(b.global_position) < 0.02, "%s: the beam rests on ball %d while it materialises" % [label, i])
	stager.seek(dur - 0.001)
	_check(not ufo.beam_on, "%s: beam off at the end" % label)
	stager.finish()
	_check(stager.kind == &"" and not ufo.visible, "%s: finish() ends it" % label)
	var plain := true
	for b in balls:
		var mesh := b.get_node("Mesh") as MeshInstance3D
		plain = plain and b.visible and mesh.material_overlay == null and is_zero_approx(mesh.transparency)
	_check(plain, "%s: a plain opaque ball each at the end" % label)
	_check(stager.find_children("*", "CollisionObject3D", true, false).is_empty() and stager.find_children("*", "CollisionShape3D", true, false).is_empty() \
			and vent.find_children("*", "CollisionObject3D", true, false).is_empty(), "%s: no collision object in the saucer, its beam or the vent" % label)


# ---------------------------------------------------------------- the Round ends

func _cleanup_flow() -> void:
	RoundDirector.skip_staging = false
	if rd.shot_in_progress:
		await _until(func() -> bool: return not rd.shot_in_progress, "no live shot")
	rd.start_round(NIGHT_1, 1, SEED)  # staged: the set-up starts ...
	stager.finish()                   # ... and is snapped to its end
	_check(not rd.staging, "a finished set-up is not staging")
	var balls := rd.get_balls()
	var n := balls.size()
	var cloth := table.get_node("Cloth") as MeshInstance3D
	var pocketed := 0
	var live: Array[Ball] = []
	for b in balls:
		if b.retired or b.is_pocketed:
			pocketed += 1
		else:
			live.append(b)
	var start_pos: Array[Vector3] = []
	for b in live:
		start_pos.append(table.to_local(b.global_position))
	rd.end_round()
	_check(rd.staging and stager.kind == RoundStaging.KIND_CLEANUP, "end_round() starts the clean-up")
	var pit := stager.get_node("TablePit") as TablePit
	_check(pit.flap_count() == StagingPlan.FLAPS and pit.ghost_count() == live.size(), "%d flaps and a ghost for each of the %d balls on the table" % [pit.flap_count(), live.size()])
	_check(not cloth.visible, "the real cloth is swapped for the flaps")
	var hidden := true
	for b in balls:
		hidden = hidden and not b.visible
	_check(hidden, "the real balls are hidden (ghosts stand in; the frozen bodies are not moved)")
	_check(not rd.can_strike(_cue(balls)), "nothing can be struck while the table opens")
	_check(stager.find_children("*", "CollisionObject3D", true, false).is_empty() and stager.find_children("*", "CollisionShape3D", true, false).is_empty(), "no collision object in the flaps, the pit or the ghosts")
	# the flap meshes are the cloth, cut: the same width, the pieces side by side
	var cut_ok := true
	var holder := pit.get_node("Frame")
	for k in StagingPlan.FLAPS:
		var mi := holder.get_node("Flap%d" % k).get_child(0) as MeshInstance3D
		cut_ok = cut_ok and mi.mesh.get_surface_count() == 1 and mi.mesh.get_aabb().size.z <= cloth.mesh.get_aabb().size.z / float(StagingPlan.FLAPS) + 0.001 and mi.material_override == cloth.material_override
	_check(cut_ok, "8 flap meshes, one surface each, a flap wide, wearing the cloth's own material")
	# time 0 matches the table; later times: flaps open, balls ride then fall, never below the pit floor
	stager.seek(0.0)
	var drift := 0.0
	var ghosts := pit.ghost_positions()
	for i in live.size():
		drift = maxf(drift, ghosts[i].distance_to(start_pos[i]))
	_check(drift < 0.002, "at t = 0 each ghost stands where its ball stood (max drift %.4f m)" % drift)
	var floor_y := table.cloth_y() - pit.pit_depth()
	stager.seek(0.5)
	var opened := false
	for k in StagingPlan.FLAPS:
		opened = opened or absf(pit.get_node("Frame/Flap%d" % k).rotation.x) > 0.3
	_check(opened, "by 0.5 s the flaps are opening")
	var low_enough := true
	var t := 0.0
	var last_y := {}
	while t <= StagingPlan.CLEANUP_SEC:
		stager.seek(t)
		var pos := pit.ghost_positions()
		for i in pos.size():
			low_enough = low_enough and pos[i].y >= floor_y - 0.001
			_check(not last_y.has(i) or pos[i].y <= last_y[i] + 0.0001 + (0.0 if t < 0.6 else 0.0), "ghost %d only moves down (t=%.2f: %.3f after %.3f)" % [i, t, pos[i].y, last_y.get(i, 0.0)])
			last_y[i] = pos[i].y
		t += 0.05
	_check(low_enough, "no ghost ever goes below the pit floor (%.3f)" % floor_y)
	stager.seek(1.2)
	var gone := true
	for g in pit.get_node("Frame").get_children():
		if g.name.begins_with("Ghost"):
			gone = gone and not (g as MeshInstance3D).visible
	_check(gone, "by 1.2 s every ball has fallen into the dark and vanished")
	stager.seek(StagingPlan.CLEANUP_SEC - 0.001)
	var shut := true
	for k in StagingPlan.FLAPS:
		shut = shut and absf(pit.get_node("Frame/Flap%d" % k).rotation.x) < 0.01
	_check(shut, "the bed is closed again at the end")
	stager.finish()
	_check(cloth.visible and rd.get_balls().is_empty() and not rd.staging, "finished: the cloth is back, the table is clear, staging is over")
	# and in real time, against the budget
	rd.start_round(NIGHT_1, 1, SEED)
	stager.finish()
	_staging_log.clear()
	rd.end_round()
	var t0 := Time.get_ticks_msec()
	await _until(func() -> bool: return not rd.staging, "the clean-up to play", 8.0)
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	_check(took <= StagingPlan.CLEANUP_MAX_SEC + 0.4 and absf(took - StagingPlan.CLEANUP_SEC) < 0.5, "clean-up took %.2f s (budget %.1f, plan %.2f)" % [took, StagingPlan.CLEANUP_MAX_SEC, StagingPlan.CLEANUP_SEC])
	_check(rd.get_balls().is_empty() and table.get_node("Cloth").visible, "...and left a clear table with its cloth")


# ---------------------------------------------------------------- GO LIVE waits for the clean-up

func _go_live_gate() -> void:
	RoundDirector.skip_staging = false
	# a live Round, ended the real way: the loop's own end -> INTERMISSION, the director clears the table
	if gl.phase == GameLoop.Phase.INTERMISSION:
		gl.advance()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE, "a live Round")
	rd.start_round(NIGHT_1, 1, SEED)  # the earlier steps drove the director by hand: give the loop's Round a rack again
	stager.finish()
	gl._end_round(&"timer")
	await process_frame
	await process_frame
	_check(gl.phase == GameLoop.Phase.INTERMISSION and rd.staging and gl.is_staging(), "the Round ended: Intermission, and the table is clearing")
	var pedestal: GoLivePedestal
	for n in level.get_node("Bar").get_children():
		if n is GoLivePedestal:
			pedestal = n
	_check(pedestal != null and pedestal.get_node("Status").text == "Table clearing", "the pedestal says the table is clearing: %s" % (pedestal.get_node("Status").text if pedestal != null else "-"))
	gl.toggle_ready(1)
	_check(gl.ready_peers.is_empty(), "GO LIVE is refused while the table clears")
	gl.advance()
	_check(gl.phase == GameLoop.Phase.INTERMISSION, "...and advance() does not start the next Round either")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	_check(world._validate(1, &"go_live", null, 0, {}) == &"staging" and WaitText.INTERACTION.has(&"staging"), "the host's validator says `staging`, and the word has its sentence")
	await _until(func() -> bool: return not rd.staging, "the clean-up to end", 8.0)
	_check(pedestal != null and "Ready 0/1" in pedestal.get_node("Status").text, "the pedestal is a GO LIVE button again: %s" % pedestal.get_node("Status").text)
	gl.toggle_ready(1)
	_check(gl.phase == GameLoop.Phase.ROUND_LIVE and rd.staging, "after the clean-up GO LIVE starts the next Round, staged again")
	stager.finish()


# ---------------------------------------------------------------- skip_staging, and a sequence cut short

func _skip_and_abort() -> void:
	RoundDirector.skip_staging = true
	if rd.shot_in_progress:
		await _until(func() -> bool: return not rd.shot_in_progress, "no live shot")
	rd.start_round(NIGHT_1, 1, SEED)
	var balls := rd.get_balls()
	var visible_all := true
	for b in balls:
		visible_all = visible_all and b.visible
	_check(not rd.staging and visible_all and rd.can_strike(_cue(balls)), "skip_staging: the rack is on the table and strikable at once, nothing staged")
	var n := balls.size()
	rd.end_round()
	_check(not rd.staging and rd.get_balls().size() == n, "skip_staging: end_round() leaves the frozen table as it always did")
	# a new Round while a set-up is playing, and an end while it plays: the picture snaps, nobody waits for it
	RoundDirector.skip_staging = false
	rd.start_round(NIGHT_1, 1, SEED)
	_check(rd.staging, "a staged start")
	rd.start_round(NIGHT_1, 2, SEED + 1)
	_check(rd.staging and stager.kind == RoundStaging.KIND_SETUP and stager.elapsed < 0.1, "a re-rack restarts the set-up on the new balls")
	rd.end_round()
	_check(rd.staging and stager.kind == RoundStaging.KIND_CLEANUP, "an end during a set-up snaps it and clears the table")
	stager.finish()
	_check(not rd.staging and rd.get_balls().is_empty(), "...and nothing is left staging")
	RoundDirector.skip_staging = true
