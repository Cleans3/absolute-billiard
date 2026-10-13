extends SceneTree
## QualityLadder + QualityManager behaviour (07 §7), the tier switches, DeviceClass (the start tier + first-run benchmark, adhoc-1014a V11)
## and GlareFlags (the glare hypothesis switches, V3). `godot --path . --headless -s tests/perf/quality_probe.gd`


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
	q.ladder.tier = 1
	q._apply_tier()
	assert(root.positional_shadow_atlas_size == 1024, "tier 1: a 1024 shadow atlas")
	q.ladder.tier = 2
	q._apply_tier()
	assert(is_equal_approx(root.scaling_3d_scale, 0.7) and root.positional_shadow_atlas_size == 512, "tier 2 = 0.7 scale, a 512 shadow atlas")
	q.ladder.tier = 0
	q._apply_tier()
	assert(root.positional_shadow_atlas_size == 2048, "tier 0 keeps the 2048 atlas")

	# --- the ladder's ceiling: a measured tier is not climbed back out of
	var lf := QualityLadder.new()
	lf.floor_tier = 1
	lf.tier = 2
	assert(lf.on_window(30.0, 30.0, 100.0) == 1, "recovers to the floor")
	assert(lf.on_window(60.0, 60.0, 400.0) == 1, "...and no further, however healthy the window")
	assert(lf.on_window(40.0, 60.0, 500.0) == 2, "but it still degrades below the floor")

	# --- DeviceClass: the name heuristic and the benchmark's verdict are pure
	var h := DeviceClass.heuristic_tier
	assert(h.call("Mali-G52 MC2", 8, 4096, "mobile") == 2, "a Mali-G52 starts at tier 2")
	assert(h.call("Adreno (TM) 610", 8, 6144, "mobile") == 2, "an Adreno 610 starts at tier 2")
	assert(h.call("Adreno (TM) 650", 8, 8192, "mobile") == 0, "an Adreno 650 starts at tier 0")
	assert(h.call("Mali-G76 MC4", 8, 6144, "mobile") == 1, "a Mali-G76 starts at tier 1")
	assert(h.call("NVIDIA GeForce RTX 3050 Ti Laptop GPU", 16, 15000, "mobile") == 0, "a desktop dGPU starts at tier 0")
	assert(h.call("Intel(R) UHD Graphics (TGL GT1)", 16, 15000, "mobile") == 1, "an integrated GPU starts at tier 1")
	assert(h.call("Adreno (TM) 650", 4, 8192, "mobile") == 1 and h.call("Adreno (TM) 650", 8, 3000, "mobile") == 1, "4 cores or 3 GB: at least tier 1")
	assert(h.call("Adreno (TM) 650", 8, 2000, "mobile") == 2, "2 GB: tier 2")
	assert(h.call("Adreno (TM) 650", 8, 8192, "gl_compatibility") == 1, "the fallback renderer: at least tier 1")
	assert(h.call("", 8, -1, "dummy") == 0, "an unknown device (RAM -1) is not penalised")
	var tc := DeviceClass.tier_from_cost
	assert(tc.call(0, 8.0) == 0 and tc.call(0, 14.0) == 0, "tier 0 at 8-14 ms: stays")
	assert(tc.call(0, 16.0) == 1, "tier 0 at 16 ms (over 60 fps / 1.1): tier 1")
	assert(tc.call(0, 30.0) == 2, "tier 0 at 30 ms: tier 2")
	assert(tc.call(1, 7.0) == 0, "tier 1 at 7 ms (under half the budget): promoted to tier 0")
	assert(tc.call(2, 12.0) == 1 and tc.call(2, 20.0) == 2 and tc.call(2, 40.0) == 2, "tier 2 (30 fps budget): 12 ms -> 1, 20 -> 2, 40 -> 2 (the floor)")
	DeviceClass.path = "user://device_class_probe.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DeviceClass.path))
	assert(DeviceClass.saved().is_empty() and not DeviceClass.needs_benchmark(), "headless: nothing saved, no benchmark")
	DeviceClass.save(1, 9.5)
	var cfg := ConfigFile.new()
	assert(cfg.load(DeviceClass.path) == OK and int(cfg.get_value("device", "tier")) == 1 and is_equal_approx(float(cfg.get_value("device", "ms")), 9.5), "save writes tier and cost")
	# the benchmark in QualityManager: 5 s of 50 ms frames (no GPU timer headless: the frame delta stands in) -> tier 2, kept as the floor
	var qb := QualityManager.new()
	root.add_child(qb)
	await process_frame
	qb._bench = 0.0
	qb._bench_at = 0
	for i in 100:
		qb._bench_step(0.05)
	assert(qb._bench < 0.0 and qb.ladder.tier == 2 and qb.ladder.floor_tier == 2, "a slow device lands on tier 2 and stays there: %d" % qb.ladder.tier)
	assert(cfg.load(DeviceClass.path) == OK and int(cfg.get_value("device", "tier")) == 2, "the verdict is persisted")
	qb.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DeviceClass.path))

	# --- GlareFlags: syntax, apply and restore
	GlareFlags.persist = false
	var bad: Array[String] = []
	var parsed := GlareFlags.parse("glow_off, aa:smaa,msaa:4x,bogus,aa:nope", bad)
	assert(parsed == {&"glow_off": "1", &"aa": "smaa", &"msaa": "4x"} and bad == ["bogus", "aa:nope"], "AB_GLARE syntax: %s / bad %s" % [parsed, bad])
	assert(GlareFlags.parse("none").is_empty() and GlareFlags.parse("default") == GlareFlags.DEFAULTS and GlareFlags.parse("all").size() == GlareFlags.BOOLS.size(), "none / default / all")
	var scratch := Node3D.new()
	root.add_child(scratch)
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	we.environment.glow_enabled = true
	scratch.add_child(we)
	var probe := ReflectionProbe.new()
	scratch.add_child(probe)
	var lamp := SpotLight3D.new()
	lamp.shadow_enabled = true
	lamp.light_bake_mode = Light3D.BAKE_DYNAMIC
	scratch.add_child(lamp)
	var baked := OmniLight3D.new()
	baked.light_bake_mode = Light3D.BAKE_STATIC
	scratch.add_child(baked)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.normal_enabled = true
	mi.material_override = mat
	scratch.add_child(mi)
	var cam := Camera3D.new()
	scratch.add_child(cam)
	QualityManager.current_tier = 0
	GlareFlags.set_all({})
	GlareFlags.apply(self)
	assert(we.environment.glow_enabled and probe.visible and lamp.shadow_enabled and is_equal_approx(baked.light_specular, 0.5) and is_equal_approx(cam.near, 0.05) and is_equal_approx(mat.metallic_specular, 0.5), "baseline: the scene's own values")
	GlareFlags.set_all(GlareFlags.parse("baked_spec_off,depth_range,mat_spec_off,normalmap_off,lamp_shadow_off,glow_off,probes_off"))
	GlareFlags.apply(self)
	assert(is_zero_approx(baked.light_specular) and is_equal_approx(lamp.light_specular, 0.5), "baked_spec_off zeroes the baked light's specular, not the lamp's")
	assert(is_equal_approx(cam.near, GlareFlags.NEAR_FIX) and is_equal_approx(cam.far, 4000.0), "depth_range: near 0.1, far untouched")
	assert(is_zero_approx(mat.metallic_specular) and not mat.normal_enabled and not lamp.shadow_enabled and not we.environment.glow_enabled and not probe.visible, "every flag reaches its node")
	GlareFlags.set_all({})
	GlareFlags.apply(self)
	assert(we.environment.glow_enabled and probe.visible and lamp.shadow_enabled and is_equal_approx(baked.light_specular, 0.5) and is_equal_approx(cam.near, 0.05) and mat.normal_enabled and is_equal_approx(mat.metallic_specular, 0.5), "turning the flags off puts every original value back")
	QualityManager.current_tier = 2
	GlareFlags.apply(self)
	assert(not we.environment.glow_enabled and not probe.visible and not lamp.shadow_enabled, "tier 2 switches glow, probes and the lamp's shadow off")
	QualityManager.current_tier = 1
	GlareFlags.apply(self)
	assert(we.environment.glow_enabled and not probe.visible and lamp.shadow_enabled, "tier 1 keeps glow and the shadow, drops the probes")
	QualityManager.current_tier = 0
	GlareFlags.apply(self)
	assert(probe.visible, "tier 0 has them all")
	GlareFlags.set_all(GlareFlags.parse("aa:smaa,msaa:4x"))
	var vp := GlareFlags.viewport_for(QualityManager.TIERS[1])
	assert(vp.aa == Viewport.SCREEN_SPACE_AA_SMAA and vp.msaa == Viewport.MSAA_4X and is_equal_approx(vp.scale, 0.85), "aa / msaa override the tier's")
	GlareFlags.set_all(GlareFlags.DEFAULTS)
	scratch.free()
	Engine.max_fps = 0
	print("QUALITY OK")
	quit()
