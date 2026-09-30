extends PerfFixture

## 07 §2 acceptance fixture: the bar room + table + 12 balls + 4 dummy avatars, camera orbiting for `seconds`
## (default 60) at render scale `scale` (default 0.85 — the budget baseline; tier 0 is 1.0) with MSAA 2x.
## Needs a window: headless has no renderer, the render rows SKIP.

const JANK_TOL_MS := 1.0  # 60 Hz vsync: "under 16.6 ms" = no missed vsync, so 16.6 + 1 ms of timer jitter

var _cam: Camera3D
var _angle := 0.0
var _avatars: Array[Node3D] = []
var _t := 0.0


func _init() -> void:
	fixture_name = "perf_bar"


func _run() -> void:
	var vp := get_viewport()
	vp.scaling_3d_scale = float(arg("scale", 0.85))
	vp.msaa_3d = Viewport.MSAA_2X
	add_room()
	add_table()
	await get_tree().physics_frame
	spawn_balls(12)
	var seats := [Vector3(-2.6, 0, -0.6), Vector3(2.6, 0, -0.6), Vector3(-4.1, 0, -3.5), Vector3(4.1, 0, -3.5)]
	for i in seats.size():
		_avatars.append(add_avatar(seats[i], 90.0 * i))
	_cam = add_camera(Vector3(0, 1.8, 1.0), TABLE_POS + Vector3(0, 0.9, 0))
	logger.tier_source = func() -> int: return 0
	logger.begin(fixture_name)
	var seconds := float(arg("seconds", 60.0))
	while logger.elapsed_s() < seconds:
		await get_tree().process_frame
	vp.scaling_3d_scale = 1.0
	var limit := 1000.0 / 60.0 + JANK_TOL_MS
	check("frames_within_vsync_pct", logger.pct_under(logger.frame_ms, limit), 95.0, ">=", "%", true)
	var dc := logger.percentile(_to_float(logger.draw_calls), 0.95)
	check("draw_calls_p95", dc, 120, "<=", "calls", true, true, dc > 0.0)
	check("primitives_max", logger.primitives_max, 60000, "<=", "tris", true)
	var gpu_mean := logger.mean(logger.gpu_ms)
	check("gpu_frame_mean", gpu_mean, 13.0, "<=", "ms", true, true, gpu_mean > 0.0)
	check("gpu_frame_p95", logger.percentile(logger.gpu_ms, 0.95), 13.0, "<=", "ms", true, false, gpu_mean > 0.0)
	check("frame_max_first_5s", logger.first_window_max_ms, 50.0, "<=", "ms", true)
	check("texture_mem_max", logger.texture_mem_max, 180.0, "<=", "MB", true)
	check("static_mem_max", logger.static_mem_max, 260.0, "<=", "MB")
	check("node_count_max", logger.nodes_max, 1500, "<=", "nodes")
	check("fps_mean", 1000.0 / maxf(logger.mean(logger.frame_ms), 0.001), 55.0, ">=", "fps", true, false)
	check("frame_p99", logger.percentile(logger.frame_ms, 0.99), limit, "<=", "ms", true, false)


func _to_float(a: PackedInt32Array) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(a.size())
	for i in a.size():
		f[i] = a[i]
	return f


func _process(delta: float) -> void:
	if _cam == null:
		return
	_t += delta
	_angle += delta * TAU / 30.0
	var c := TABLE_POS + Vector3(0, 0, 0)
	_cam.position = c + Vector3(cos(_angle) * 4.6, 1.8, sin(_angle) * 3.6)
	_cam.look_at(c + Vector3(0, 0.9, 0))
	for i in _avatars.size():
		_avatars[i].rotation.y += delta * 0.4 * (1.0 if i % 2 == 0 else -1.0)
		_avatars[i].position.y = absf(sin(_t * 1.5 + i)) * 0.03
