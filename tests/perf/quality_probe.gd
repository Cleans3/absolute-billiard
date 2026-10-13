extends SceneTree
## QualityLadder + QualityManager behaviour (07 §7). `godot --path . --headless -s tests/perf/quality_probe.gd`


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var l := QualityLadder.new()
	assert(l.on_window(59.0, 60.0, 10.0) == 0, "healthy window keeps tier 0")
	assert(l.on_window(50.0, 60.0, 20.0) == 1, "sag -> tier 1")
	assert(l.on_window(50.0, 60.0, 30.0) == 2, "still sagging -> tier 2")
	assert(l.on_window(20.0, 30.0, 40.0) == 2, "tier 2 is the floor")
	assert(l.on_window(30.0, 30.0, 60.0) == 2, "recovery blocked inside the 60 s dwell")
	assert(l.on_window(30.0, 30.0, 100.0) == 1, "recovery after dwell, one step")
	assert(l.on_window(30.0, 60.0, 110.0) == 2, "undo within 30 s degrades again")
	assert(l.on_window(60.0, 60.0, 200.0) == 2, "dwell doubled to 120 s after an undone recovery")
	assert(l.on_window(60.0, 60.0, 231.0) == 1, "recovers once the doubled dwell has passed")

	var sim := PhysicsSim.new()
	root.add_child(sim)
	var q := QualityManager.new()
	q.sim = sim
	root.add_child(q)
	await process_frame
	assert(Engine.max_fps == 60, "active fps 60, got %d" % Engine.max_fps)
	q.notification(NOTIFICATION_APPLICATION_PAUSED)
	assert(q.paused and Engine.max_fps == QualityManager.BACKGROUND_FPS, "pause -> 10 fps")
	var seen := [0, 0]
	q.app_paused.connect(func() -> void: seen[0] += 1)
	q.app_resumed.connect(func() -> void: seen[1] += 1)
	q.notification(NOTIFICATION_APPLICATION_RESUMED)
	assert(not q.paused and Engine.max_fps == 60 and seen[1] == 1, "resume restores 60 fps")
	q._last_input_ms -= QualityManager.IDLE_AFTER_MS + 10
	await process_frame
	assert(q.idle and Engine.max_fps == QualityManager.IDLE_FPS, "rest + no input -> 30 fps")
	q.keep_awake()
	assert(Engine.max_fps == 60, "input wakes to 60 fps")
	q.battery_mode = true
	assert(Engine.max_fps == 30, "battery mode caps 30 fps")
	q.battery_mode = false
	q.ladder.tier = 1
	q._apply_tier()
	assert(is_equal_approx(root.scaling_3d_scale, 0.85) and root.msaa_3d == Viewport.MSAA_DISABLED, "tier 1 = 0.85 scale, MSAA off")
	assert(root.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA, "tier 1 swaps MSAA for FXAA (adhoc-1013c U4)")
	q.ladder.tier = 0
	q._apply_tier()
	assert(root.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED and root.msaa_3d == Viewport.MSAA_2X, "tier 0 = MSAA 2x, no FXAA")
	Engine.max_fps = 0
	print("QUALITY OK")
	quit()
