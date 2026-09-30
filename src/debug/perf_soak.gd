extends PerfFixture

## 07 §7 acceptance fixture: autoplay — break, wait for rest, "aim" for `aim` seconds without input (the
## QualityManager downclocks), re-rack from the pool — for `minutes` (default 5; 20 = the 07 acceptance run),
## with the real QualityManager + thermal ladder in the loop. Reports active-frame fps, deepest ladder tier,
## the reduced-rate share, memory drift Round 1 -> 5 and orphans. Needs a window for the fps rows.

const CUE := preload("res://src/resources/cues/demo_cue.tres")
const QUALITY := preload("res://src/gameplay/quality/quality_manager.gd")

var _quality: QualityManager
var _max_tier := 0
var _cam: Camera3D
var _angle := 0.0


func _init() -> void:
	fixture_name = "perf_soak"


func _run() -> void:
	add_room()
	add_table()
	await get_tree().physics_frame
	spawn_balls(12)
	_cam = add_camera(Vector3(-3.0, 1.8, -0.5), TABLE_POS + Vector3(0, 0.8, 0))
	_quality = QUALITY.new()
	_quality.sim = table.sim
	add_child(_quality)
	_quality.tier_changed.connect(func(t: int) -> void: _max_tier = maxi(_max_tier, t))
	logger.exclude_source = func() -> bool: return _quality.idle or _quality.paused
	logger.tier_source = func() -> int: return _quality.ladder.tier
	logger.awake_source = func() -> int: return table.sim.awake
	logger.begin(fixture_name)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(arg("seed", 20260930))
	var end_s := float(arg("minutes", 5.0)) * 60.0
	var aim_s := float(arg("aim", 6.0))
	var round_n := 0
	var mem_first := 0.0
	var mem_fifth := 0.0
	while logger.elapsed_s() < end_s:
		reset_rack()
		var f0 := Engine.get_physics_frames()
		while table.sim.awake > 0 and Engine.get_physics_frames() - f0 < 10 * PhysicsSim.LIVE_TICK:
			await get_tree().process_frame
		await _aim(aim_s)
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2.RIGHT.rotated(deg_to_rad(rng.randf_range(-3.0, 3.0)))
		intent.power = rng.randf_range(0.5, 1.0)
		_quality.keep_awake()  # the shot itself is input
		cue_ball.strike(intent, CUE)
		f0 = Engine.get_physics_frames()
		while table.sim.awake > 0 and Engine.get_physics_frames() - f0 < 20 * PhysicsSim.LIVE_TICK and logger.elapsed_s() < end_s:
			await get_tree().process_frame
		round_n += 1
		var mem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		if round_n == 1:
			mem_first = mem
		elif round_n == 5:
			mem_fifth = mem
	var total_s := logger.elapsed_s()
	var idle_share := 100.0 * logger.excluded_us * 1e-6 / maxf(total_s, 1e-6)
	var active_fps := 1000.0 / maxf(logger.mean(logger.frame_ms), 0.001)
	check("fps_mean_active", active_fps, 55.0, ">=", "fps", true)
	check("ladder_max_tier", _max_tier, 1, "<=", "tier", true)
	check("reduced_rate_share", idle_share, 50.0, ">=", "%", true, false)
	check("orphan_nodes_end", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), 0, "<=", "nodes")
	var drift := (mem_fifth / mem_first - 1.0) * 100.0 if mem_fifth > 0.0 else 0.0
	check("static_mem_drift_r1_r5", drift, 5.0, "<=", "%", false, round_n >= 5)
	check("rounds_played", round_n, 5, ">=", "rounds", false, false)


## Wait `s` seconds with no input, orbiting slowly (a stand-in for the aiming camera drift).
func _aim(s: float) -> void:
	var t0 := logger.elapsed_s()
	while logger.elapsed_s() - t0 < s:
		await get_tree().process_frame


func _process(delta: float) -> void:
	if _cam == null or _quality == null or _quality.idle:
		return
	_angle += delta * 0.2
	_cam.position = TABLE_POS + Vector3(cos(_angle) * 4.0, 1.8, sin(_angle) * 3.2)
	_cam.look_at(TABLE_POS + Vector3(0, 0.8, 0))
