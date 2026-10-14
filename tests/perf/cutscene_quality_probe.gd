extends SceneTree
## What a cutscene that has the screen does to QualityManager, GlareFlags and the Mirror (docs/plan/07, adhoc-1014b C5, S2, S5).
## The caller side is `Cutscene`: it calls `cutscene_hold(true, on_stage)` on group QualityManager.HOLD_GROUP right before its camera goes
## current and `(false, ...)` right before it is restored (this probe plays that part itself when the Cutscene on the branch does not yet).
##   - while a hold stands: no 30 fps idle cap (tiers 0-2), no ladder-window accumulation, the first-run benchmark neither starts
##     nor samples (and starts over from the frames after it), and the first frame after it is a frame's dt, not the cutscene's;
##   - a hold nobody released (its part freed) is dropped, and a level freed mid-hold leaves none behind;
##   - a cutscene camera's cut runs no whole-tree GlareFlags pass (its part's own nodes get the switches), nor does the game camera coming back;
##   - the Mirror's room capture waits for the hold and says when it is done (`is_captured`, `captured`); the LoadingScreen waits for it.
##   godot --path . --headless -s tests/perf/cutscene_quality_probe.gd     prints CUTSCENE QUALITY OK
## The capture's frames against a real renderer: src/tools/mirror_capture_timing.gd (windowed).

const CABIN := "res://src/cutscene/IntroCabin.tscn"
const MIRROR := "res://src/gameplay/bar/Mirror.tscn"

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _hold(on: bool) -> void:
	call_group(QualityManager.HOLD_GROUP, &"cutscene_hold", on, true)


func _run() -> void:
	GlareFlags.persist = false
	DeviceClass.path = "user://cutscene_quality_probe.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DeviceClass.path))
	SaveManager.root = "user://test_cutscene_quality"
	DirAccess.make_dir_recursive_absolute(SaveManager.root.path_join("checkpoints"))
	await _manager()
	await _glare()
	await _mirror()
	await _level()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DeviceClass.path))
	Engine.max_fps = 0
	if fails == 0:
		print("CUTSCENE QUALITY OK")
	else:
		printerr("CUTSCENE QUALITY FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


# --- QualityManager ----------------------------------------------------------------------------------------------------------------

func _manager() -> void:
	var q := QualityManager.new()
	root.add_child(q)
	await _frames(2)
	var part := Node3D.new()
	var cam := Camera3D.new()
	cam.name = QualityManager.CUTSCENE_CAMERA
	part.add_child(cam)
	root.add_child(part)

	# the idle cap is the control: rest + no input for IDLE_AFTER_MS -> 30 fps; a hold keeps every tier at its own cap
	q._last_input_ms -= QualityManager.IDLE_AFTER_MS + 10
	await _frames(1)
	_check(q.idle and Engine.max_fps == QualityManager.IDLE_FPS, "control: rest and no input -> the idle 30 fps cap")
	q.keep_awake()
	cam.make_current()
	_hold(true)
	_check(QualityManager.cutscene_holds == 1, "a hold is counted for the Mirror to read")
	for tier in 3:
		q.ladder.tier = tier
		q._apply_tier()
		q._apply_fps()
		q._last_input_ms -= QualityManager.IDLE_AFTER_MS + 10
		await _frames(2)
		_check(not q.idle and Engine.max_fps == QualityManager.TIERS[tier].fps, "tier %d held: awake at its own cap (%d fps), got idle=%s %d" % [tier, QualityManager.TIERS[tier].fps, q.idle, Engine.max_fps])
	q.ladder.tier = 0
	q._apply_tier()
	_hold(false)
	_check(QualityManager.cutscene_holds == 0, "off ends the hold")
	q._last_input_ms -= QualityManager.IDLE_AFTER_MS + 10
	await _frames(2)
	_check(q.idle and Engine.max_fps == QualityManager.IDLE_FPS, "after the hold the idle cap is back")
	q.keep_awake()

	# the ladder's window: held frames are not the bar's, and the first frame after is a frame's dt
	if Settings.quality_tier() < 0:
		q._reset_window()
		await _frames(4)
		_check(q._win_frames >= 3, "control: the window counts frames (%d)" % q._win_frames)
		_hold(true)
		_check(q._win_frames == 0, "a hold starts a fresh window")
		q._prev_us -= 11_000_000  # the cutscene runs 11 s ...
		await _frames(5)
		_check(q._win_frames == 0 and q._win_us == 0, "held: no frame reaches the window (%d)" % q._win_frames)
		_hold(false)
		await _frames(2)
		_check(q._win_us < 1_000_000, "... and the first frame after it is a frame's dt, not 11 s (%d us)" % q._win_us)
		_check(q.ladder.tier == 0, "no demotion from a cutscene")
	else:
		print("SKIP window check: the quality setting is pinned")

	# the first-run benchmark
	q._bench_at = 0
	q._bench = 0.0
	_hold(true)
	await _frames(6)
	_check(q._bench == 0.0 and q._bench_cost.is_empty(), "held: the benchmark does not start (%.2f s, %d samples)" % [q._bench, q._bench_cost.size()])
	_check(Engine.max_fps != 0, "held: the benchmark did not uncap the fps")
	_hold(false)
	for i in 20:
		q._bench_step(0.1)
	_check(q._bench > 0.0 and q._bench_cost.size() > 0 and Engine.max_fps == 0, "free: it runs (sampling, uncapped)")
	_hold(true)
	await _frames(1)
	_check(q._bench == 0.0 and q._bench_cost.is_empty() and q._bench_delta.is_empty(), "a hold mid-benchmark throws away what it measured (%d samples)" % q._bench_cost.size())
	_check(Engine.max_fps == QualityManager.TIERS[q.ladder.tier].fps, "... and gives the fps cap back: %d" % Engine.max_fps)
	_hold(false)
	await _frames(1)
	_check(q._bench > 0.0 and q._bench < DeviceClass.WARMUP_S, "after the hold it starts over from its warm-up (%.2f s)" % q._bench)
	for i in 100:
		if q._bench >= 0.0:
			q._bench_step(0.05)
	_check(q._bench < 0.0, "... and finishes")
	q.ladder.tier = 0
	q.ladder.floor_tier = 0
	q._apply_tier()
	q._apply_fps()

	# a hold that was never released (the part was freed) is dropped; a level freed mid-hold leaves none
	q._bench = -1.0
	_hold(true)
	part.free()  # its camera goes with it: no cutscene camera is current
	await _frames(QualityManager.HOLD_STALE_FRAMES + 3)
	_check(q._hold == 0 and QualityManager.cutscene_holds == 0, "a hold with no cutscene camera is dropped after %d frames" % QualityManager.HOLD_STALE_FRAMES)
	var kept := Node3D.new()
	var kept_cam := Camera3D.new()
	kept_cam.name = QualityManager.CUTSCENE_CAMERA
	kept.add_child(kept_cam)
	root.add_child(kept)
	kept_cam.make_current()
	_hold(true)
	await _frames(QualityManager.HOLD_STALE_FRAMES + 3)
	_check(q._hold == 1, "a hold with its cutscene camera current stands as long as it does")
	_hold(false)
	_hold(false)
	_check(q._hold == 0 and QualityManager.cutscene_holds == 0, "off never goes below 0")
	_hold(true)
	q.free()
	_check(QualityManager.cutscene_holds == 0 and get_nodes_in_group(QualityManager.HOLD_GROUP).is_empty(), "the level freed mid-hold: no hold, no receiver left")
	kept.free()


# --- GlareFlags --------------------------------------------------------------------------------------------------------------------

func _glare() -> void:
	GlareFlags.set_all(GlareFlags.parse("depth_range,lamp_spec_off"))
	var q := QualityManager.new()
	root.add_child(q)
	var bar := Node3D.new()  # a bar-sized tree: the walk's cost is what a cut paid
	for i in 1500:
		var n := Node3D.new()
		n.add_child(MeshInstance3D.new())
		bar.add_child(n)
	root.add_child(bar)
	var game_cam := Camera3D.new()
	root.add_child(game_cam)
	game_cam.make_current()
	await _frames(3)
	var walks := GlareFlags.walks
	_check(walks >= 1 and is_equal_approx(game_cam.near, GlareFlags.NEAR_FIX), "the game's camera got the whole pass once (%d), near %.2f" % [walks, game_cam.near])

	var late_lamp := OmniLight3D.new()  # a node outside the part, born after the last whole pass
	bar.add_child(late_lamp)
	var part := Node3D.new()
	var lamp := OmniLight3D.new()
	part.add_child(lamp)
	var cut_cam := Camera3D.new()
	cut_cam.name = QualityManager.CUTSCENE_CAMERA
	part.add_child(cut_cam)
	root.add_child(part)
	_hold(true)
	cut_cam.make_current()
	await _frames(2)
	_check(GlareFlags.walks == walks, "a cutscene camera's cut runs no whole-tree pass (%d -> %d)" % [walks, GlareFlags.walks])
	_check(is_equal_approx(cut_cam.near, GlareFlags.NEAR_FIX) and is_zero_approx(lamp.light_specular), "... its part got the switches (near %.2f, lamp specular %.2f)" % [cut_cam.near, lamp.light_specular])
	_check(is_equal_approx(late_lamp.light_specular, 0.5), "... and nothing outside it was visited")
	_hold(false)
	game_cam.make_current()
	await _frames(2)
	_check(GlareFlags.walks == walks, "the game camera coming back runs none either")
	var part2 := Node3D.new()
	var cut_cam2 := Camera3D.new()
	cut_cam2.name = QualityManager.CUTSCENE_CAMERA
	part2.add_child(cut_cam2)
	root.add_child(part2)
	_hold(true)
	cut_cam2.make_current()
	await _frames(2)
	_hold(false)
	game_cam.make_current()
	await _frames(2)
	_check(GlareFlags.walks == walks and is_equal_approx(cut_cam2.near, GlareFlags.NEAR_FIX), "the next part's cut: none, and its camera is done too")
	var preview_cam := Camera3D.new()  # any other new camera (the skin preview's) still gets the whole pass
	root.add_child(preview_cam)
	preview_cam.make_current()
	await _frames(2)
	_check(GlareFlags.walks == walks + 1 and is_equal_approx(late_lamp.light_specular, 0.0), "a new ordinary camera still gets the whole pass (%d)" % (GlareFlags.walks - walks))

	var t0 := Time.get_ticks_usec()
	GlareFlags.apply(self)
	var whole := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	GlareFlags.apply_under(part)
	var scoped := (Time.get_ticks_usec() - t0) / 1000.0
	print("GLARE scratch bar (%d nodes): whole-tree pass %.2f ms, a part's pass %.3f ms" % [root.find_children("*", "", true, false).size(), whole, scoped])
	for n: Node in [part, part2, preview_cam, game_cam, bar, q]:
		n.free()
	GlareFlags.set_all(GlareFlags.DEFAULTS)


# --- Mirror ------------------------------------------------------------------------------------------------------------------------

func _mirror() -> void:
	var q := QualityManager.new()  # it is the receiver of the hold the Mirror reads
	root.add_child(q)
	var m := (load(MIRROR) as PackedScene).instantiate() as Mirror
	var seen := [0]
	m.captured.connect(func() -> void: seen[0] += 1)
	root.add_child(m)
	await _frames(3)
	_check(m.is_in_group(&"mirror") and m.is_captured and seen[0] == 1, "the Mirror is in group mirror and reports its capture once (headless has none to take): %s %d" % [m.is_captured, seen[0]])
	m.is_captured = false
	_hold(true)
	m.capture()
	await _frames(Mirror.CALM_FRAMES + 6)
	_check(seen[0] == 1 and not m.is_captured and m._recapture, "held: the capture waits (%d captures)" % seen[0])
	_hold(false)
	_hold(true)  # a cut between two parts: off, then on
	await _frames(Mirror.CALM_FRAMES + 6)
	_check(seen[0] == 1, "off then on back to back: still waiting")
	_hold(false)
	await _frames(Mirror.CALM_FRAMES - 1)
	_check(seen[0] == 1, "free: it still lets %d calm frames pass first" % Mirror.CALM_FRAMES)
	await _frames(3)
	_check(seen[0] == 2 and m.is_captured and not m._recapture, "free: the held capture runs and says so (%d)" % seen[0])
	# under the loading screen a hold does not stall it: the overlay waits for this capture, and the intro's cue fires beneath it
	var overlay := Node.new()
	overlay.name = "LoadingScreen"
	root.add_child(overlay)
	_hold(true)
	m.capture()
	_check(seen[0] == 3, "a hold under the loading screen does not hold the capture (%d)" % seen[0])
	_hold(false)
	overlay.free()
	_hold(true)
	m.capture()
	_check(seen[0] == 3 and m._recapture, "the same hold without the overlay does")
	_hold(false)
	m.free()
	q.free()


# --- the real level ----------------------------------------------------------------------------------------------------------------

func _level() -> void:
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	var q := level.get_node("QualityManager") as QualityManager
	var mirror := get_first_node_in_group(&"mirror") as Mirror
	_check(mirror != null and mirror.is_captured and root.get_node_or_null("LoadingScreen") == null, "the bar is up with its mirror captured and no loading screen")
	_check(q.is_in_group(QualityManager.HOLD_GROUP), "the level's QualityManager receives the hold")
	await _frames(3)

	# a stage part in the real level: the camera cut costs no whole-tree pass, and the bar's frames do not run the ladder meanwhile
	var walks := GlareFlags.walks
	var player_cam := root.get_camera_3d()
	var cs := (load(CABIN) as PackedScene).instantiate() as Cutscene
	cs.configure({"seed": 4242, "manual": true})
	root.add_child(cs)
	cs.global_position = Cutscene.STAGE_ORIGIN
	var held_by_cutscene := QualityManager.cutscene_holds
	cs.play()
	var emulated := QualityManager.cutscene_holds == held_by_cutscene  # the Cutscene on this branch has no hold call yet
	if emulated:
		_hold(true)
	_check(QualityManager.cutscene_holds == held_by_cutscene + 1, "a playing cutscene holds (%d)" % QualityManager.cutscene_holds)
	var frames_before := q._win_frames
	await _frames(3)
	_check(GlareFlags.walks == walks, "the real intro cabin's cut: no whole-tree pass (%d -> %d)" % [walks, GlareFlags.walks])
	_check(cs.camera.has_meta(&"glare_seen"), "... its camera was handled")
	_check(q._win_frames == 0, "... and no frame of it reached the ladder's window (%d, was %d)" % [q._win_frames, frames_before])
	var part_nodes := cs.find_children("*", "", true, false).size()
	var t0 := Time.get_ticks_usec()
	GlareFlags.apply_under(cs)
	var scoped := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	GlareFlags.apply(self)
	var whole := (Time.get_ticks_usec() - t0) / 1000.0
	print("GLARE real bar (%d nodes): whole-tree pass %.2f ms, the cabin's pass (%d nodes) %.3f ms" % [root.find_children("*", "", true, false).size(), whole, part_nodes, scoped])
	_check(scoped * 4.0 < whole, "a part's pass is a fraction of the whole one (%.3f vs %.2f ms)" % [scoped, whole])
	cs.abort()
	if emulated:
		_hold(false)
	await _frames(2)
	_check(QualityManager.cutscene_holds == held_by_cutscene and root.get_camera_3d() == player_cam, "the part ended: the hold is off and the game camera is back")
	_check(GlareFlags.walks == walks + 1, "the game camera coming back ran none (only the timing pass above)")

	# the level freed mid-cutscene
	var cs2 := (load(CABIN) as PackedScene).instantiate() as Cutscene
	cs2.configure({"seed": 4242, "manual": true})
	root.add_child(cs2)
	cs2.global_position = Cutscene.STAGE_ORIGIN
	cs2.play()
	var emulated2 := QualityManager.cutscene_holds == held_by_cutscene
	if emulated2:
		_hold(true)
	level.free()
	cs2.free()
	_check(QualityManager.cutscene_holds == 0, "the level freed mid-cutscene: the count is back to 0 (%d)" % QualityManager.cutscene_holds)
