extends PerfFixture

## 07 §1 acceptance fixture: max-power break into 12 object balls + cue, fixed seed, N runs. Physics-only (no
## room/renderer), so it runs headless: `godot --headless --path . --fixed-fps 60 res://src/debug/perf_break.tscn
## -- --runs=5`. `Jolt step` = Performance.TIME_PHYSICS_PROCESS on live ticks (engine step + _integrate_forces).

const CUE := preload("res://src/resources/cues/demo_cue.tres")
const REST_CAP_S := 20.0
const OFF_TABLE_MARGIN_M := 0.05

var _events := 0
var _events_last := 0
var _step_ms := PackedFloat32Array()
var _pairs_peak := 0
var _cd_peak := 0
var _fell := 0
var _base_ms := 0.0
var _fell_flag: Dictionary = {}  # Ball -> true, per run


func _init() -> void:
	fixture_name = "perf_break"


func _run() -> void:
	# empty-scene physics frame: the monitor also counts the frame loop itself, subtract it from every step row
	var base_ms := PackedFloat32Array()
	for i in 60:
		await get_tree().physics_frame
		base_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_base_ms = logger.percentile(base_ms, 0.5)
	add_table()
	await get_tree().physics_frame
	spawn_balls(int(arg("balls", 12)))
	for b in balls:
		b.contacted.connect(_on_contact)
	# --cloth=0.7 --tilt=1.0: table-stat Effects live (raises the events/shot limit to 400, 07 §3)
	var stat_fx := params.has("cloth") or params.has("tilt")
	if stat_fx:
		table.sim.set_stat(&"cloth_friction_mult", float(arg("cloth", 1.0)))
		table.sim.set_stat(&"table_tilt_deg", float(arg("tilt", 0.0)))
		table.sim.set_tilt_direction(Vector2(1, 0.5))
	logger.awake_source = func() -> int: return table.sim.awake
	logger.events_source = func() -> int: return _events_last
	Performance.add_custom_monitor("Game/ContactEventsPerShot", func() -> int: return _events_last)
	logger.begin(fixture_name)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(arg("seed", 20260930))
	var runs := int(arg("runs", 100))
	var rest_s := PackedFloat32Array()
	var max_events := 0
	var off_table := 0
	var shot_us := 0.0
	var shot_ticks := 0
	for i in runs:
		reset_rack()
		_fell_flag.clear()
		await _wait_awake_zero(10.0)
		_events = 0
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2.RIGHT.rotated(deg_to_rad(rng.randf_range(-0.4, 0.4)))
		intent.power = 1.0
		var f0 := Engine.get_physics_frames()
		var t0 := Time.get_ticks_usec()
		cue_ball.strike(intent, CUE)
		await _wait_awake_zero(REST_CAP_S)
		shot_us += Time.get_ticks_usec() - t0
		shot_ticks += Engine.get_physics_frames() - f0
		rest_s.append((Engine.get_physics_frames() - f0) / float(PhysicsSim.LIVE_TICK))
		_events_last = _events
		max_events = maxi(max_events, _events)
		off_table += _count_off_table()
	# at rest: every body asleep (07 §1 "table at rest <= 0.05 ms")
	# rest cost in us/tick is tests/perf/rest_cost_probe.gd (TIME_PHYSICS_PROCESS cannot resolve 0.05 ms); here: structure
	var active_rest := 0
	var sensors_on := 0
	for i in 30:
		await get_tree().physics_frame
		active_rest = maxi(active_rest, int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)))
	for a in table.get_children():
		if a is Area3D and a.monitoring:
			sensors_on += 1
	Performance.remove_custom_monitor("Game/ContactEventsPerShot")
	var tree_balls := balls.filter(func(b: Ball) -> bool: return b.is_inside_tree()).size()
	# structural rows (CCD, rest time, contacts, sensors, events) are machine independent, so CI gates them too;
	# only the step ceiling depends on the machine (--step-limit-ms)
	var hard := true
	# --fixed=1 (run with `godot --fixed-fps 60`, every frame = 2 live ticks, frames unthrottled): wall / ticks over the
	# shots — stable to ~1%, and what CI / the dev PC use. On a device (real time) that ratio is just the tick period, so
	# the row falls back to TIME_PHYSICS_PROCESS minus the empty-scene baseline: noisy (+-0.3 ms) but the only in-engine one.
	var live_ms := shot_us / maxi(shot_ticks, 1) / 1000.0 if bool(arg("fixed", 0)) else logger.mean(_step_ms)
	check("jolt_step_live_mean", live_ms, float(arg("step-limit-ms", 1.0)), "<=", "ms/tick")
	check("tick_monitor_p99", logger.percentile(_step_ms, 0.99), 0.0, "<=", "ms/tick (monitor)", false, false)
	check("pocket_sensors_on_at_rest", sensors_on, 0, "<=", "areas", false, hard)
	check("bodies_active_at_rest", active_rest, 0, "<=", "bodies", false, hard)
	check("contacts_per_step_peak", _pairs_peak, 40, "<=", "contacts", false, hard)
	check("ccd_bodies_peak", _cd_peak, 2, "<=", "bodies", false, hard)
	check("events_per_shot_max", max_events, 400 if stat_fx else 200, "<=", "events")
	check("strike_to_rest_max", _max(rest_s), 9.0, "<=", "s", false, hard)
	check("off_table_or_fell", off_table + _fell, 0, "<=", "balls")
	check("ball_count_delta", absi(tree_balls - balls.size()), 0, "<=", "balls")
	check("runs", runs, 0, ">=", "runs", false, false)


func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


func _wait_awake_zero(cap_s: float) -> void:
	var f0 := Engine.get_physics_frames()
	while table.sim.awake > 0 and (Engine.get_physics_frames() - f0) < cap_s * PhysicsSim.LIVE_TICK:
		await get_tree().physics_frame


func _on_contact(ball: Ball, other: Node, kind: StringName) -> void:
	if kind == &"RAIL" or ball.get_instance_id() < other.get_instance_id():
		_events += 1


func _physics_process(_delta: float) -> void:
	if table == null or table.sim.awake == 0:
		return
	_step_ms.append(maxf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0 - _base_ms, 0.0))
	var cd := 0
	var contacts := 0
	var floor_y := table.global_position.y + table.spec.bed_height_m - 0.2
	for b in balls:
		if b.continuous_cd:
			cd += 1
		for other in b.get_colliding_bodies():
			if other is Ball:
				contacts += 1 if b.get_instance_id() < other.get_instance_id() else 0
			elif other.name != &"Bed":
				contacts += 1
		if not b.is_pocketed and b.global_position.y < floor_y and not _fell_flag.has(b):
			_fell_flag[b] = true
			_fell += 1
	_cd_peak = maxi(_cd_peak, cd)
	_pairs_peak = maxi(_pairs_peak, contacts)


func _count_off_table() -> int:
	var n := 0
	var hl := table.spec.length_m * 0.5 + OFF_TABLE_MARGIN_M
	var hw := table.spec.width_m * 0.5 + OFF_TABLE_MARGIN_M
	for b in balls:
		if b.is_pocketed or _fell_flag.has(b):
			continue
		var p := b.global_position - table.global_position
		if absf(p.x) > hl or absf(p.z) > hw or is_nan(p.x):
			n += 1
	return n
