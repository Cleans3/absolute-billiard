class_name PerfLogger
extends Node

## Frame/monitor recorder for the 07 §9 fixtures. Every frame's time goes into a packed array (percentiles
## at the end); every `interval_s` one CSV row of the 07 §9 monitor list lands in user://perf/<name>-<ts>.csv.
## Renderer-side numbers read 0 under --headless (dummy renderer): `renders()` tells fixtures to SKIP those gates.

const COLUMNS := "time_s,fps,frame_ms_mean,frame_ms_max,time_process_ms,time_physics_ms,draw_calls,primitives," \
		+ "video_mem_mb,texture_mem_mb,static_mem_mb,nodes,orphans,awake_balls,contact_events_per_shot,net_bytes_per_sec," \
		+ "gpu_ms,cpu_render_ms,phys_active,phys_pairs,phys_islands,tier"

var interval_s := 0.25
var frame_ms := PackedFloat32Array()
var gpu_ms := PackedFloat32Array()
var draw_calls := PackedInt32Array()
var primitives_max := 0
var video_mem_max := 0.0
var texture_mem_max := 0.0
var static_mem_max := 0.0
var nodes_max := 0
var first_window_max_ms := 0.0  # slowest frame in the first `first_window_s` (07 §6 "no frame over 50 ms")
var first_window_s := 5.0
var awake_source: Callable
var events_source: Callable
var tier_source: Callable
## Frames for which this returns true (idle downclock, paused) stay out of the frame statistics.
var exclude_source: Callable
var excluded_us := 0
var csv_path := ""
var running := false

var _file: FileAccess
var _t0_us := 0
var _prev_us := 0
var _row_us := 0
var _row_frames := 0
var _row_sum_ms := 0.0
var _row_max_ms := 0.0
var _vp_rid: RID
var _flush_us := 0


static func renders() -> bool:
	return DisplayServer.get_name() != "headless"


func begin(fixture: String) -> void:
	DirAccess.make_dir_recursive_absolute("user://perf")
	var ts := Time.get_datetime_string_from_system(false).replace(":", "-")
	csv_path = "user://perf/%s-%s.csv" % [fixture, ts]
	_file = FileAccess.open(csv_path, FileAccess.WRITE)
	_file.store_line(COLUMNS)
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_t0_us = Time.get_ticks_usec()
	_prev_us = _t0_us
	_row_us = _t0_us
	_flush_us = _t0_us
	running = true


func end() -> void:
	if not running:
		return
	running = false
	RenderingServer.viewport_set_measure_render_time(_vp_rid, false)
	_file.close()


func elapsed_s() -> float:
	return (Time.get_ticks_usec() - _t0_us) * 1e-6


func _process(_delta: float) -> void:
	if not running:
		return
	var now := Time.get_ticks_usec()
	var ms := (now - _prev_us) * 1e-3
	_prev_us = now
	if exclude_source.is_valid() and exclude_source.call():
		excluded_us += int(ms * 1000.0)
		return
	frame_ms.append(ms)
	if elapsed_s() <= first_window_s:
		first_window_max_ms = maxf(first_window_max_ms, ms)
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	gpu_ms.append(gpu)
	var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	draw_calls.append(dc)
	primitives_max = maxi(primitives_max, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
	video_mem_max = maxf(video_mem_max, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)
	texture_mem_max = maxf(texture_mem_max, Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0)
	static_mem_max = maxf(static_mem_max, Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
	nodes_max = maxi(nodes_max, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	_row_frames += 1
	_row_sum_ms += ms
	_row_max_ms = maxf(_row_max_ms, ms)
	if (now - _row_us) * 1e-6 >= interval_s:
		_write_row(now, gpu)


func _write_row(now: int, gpu: float) -> void:
	var span_s := (now - _row_us) * 1e-6
	_row_us = now
	var mean_ms := _row_sum_ms / maxi(_row_frames, 1)
	var awake: int = awake_source.call() if awake_source.is_valid() else 0
	var events: int = events_source.call() if events_source.is_valid() else 0
	var tier: int = tier_source.call() if tier_source.is_valid() else 0
	var cpu_r := RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)
	_file.store_line("%.3f,%.1f,%.3f,%.3f,%.3f,%.3f,%d,%d,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%.3f,%.3f,%d,%d,%d,%d" % [
		elapsed_s(), _row_frames / maxf(span_s, 1e-6), mean_ms, _row_max_ms,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		awake, events, _net_bytes(), gpu, cpu_r,
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
		Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT), tier])
	_row_frames = 0
	_row_sum_ms = 0.0
	_row_max_ms = 0.0
	if (now - _flush_us) > 4_000_000:
		_flush_us = now
		_file.flush()


## `Game/NetBytesPerSec` belongs to NET (07 §3): read it when registered, 0 until then.
func _net_bytes() -> int:
	return int(Performance.get_custom_monitor(&"Game/NetBytesPerSec")) if Performance.has_custom_monitor(&"Game/NetBytesPerSec") else 0


func percentile(a: PackedFloat32Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return s[clampi(int(ceil(p * s.size())) - 1, 0, s.size() - 1)]


func mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var t := 0.0
	for v in a:
		t += v
	return t / a.size()


func pct_under(a: PackedFloat32Array, limit_ms: float) -> float:
	if a.is_empty():
		return 0.0
	var n := 0
	for v in a:
		if v <= limit_ms:
			n += 1
	return 100.0 * n / a.size()
