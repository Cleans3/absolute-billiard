class_name QualityManager
extends Node

## Frame-rate and quality governor (07 §2 modes, §7). Owns the fps side only — PhysicsSim owns the
## tick (LIVE_TICK live / REST_TICK at rest). Downclocks to 30 fps when the table is at rest and no
## input arrived for IDLE_AFTER_MS, climbs the thermal ladder on a 10 s mean-fps window, and exposes
## app pause/resume for NET/SYNC to hook (07 §3.5, §7.5).

signal tier_changed(tier: int)
signal app_paused
signal app_resumed

const WINDOW_S := 10.0
const IDLE_AFTER_MS := 2000
const IDLE_FPS := 30
const BACKGROUND_FPS := 10
const BATTERY_FPS := 30
## Per tier (07 §7.4): the viewport (3D scale, MSAA, screen-space AA, the lamp's shadow atlas px), the fps cap, the trails, and the
## cheap-mode switches GlareFlags.apply puts on the scene (the lamp's shadow, the Environment's glow, the two reflection probes);
## Mirror and StreamTv read `current_tier` for their own sizes and rates (tier 2: a static mirror, one slow TV feed). Tiers 1-2 drop MSAA
## to save fill, which leaves every edge bare (the phone's black-with-white-outline edges, adhoc-1013c U4): FXAA stands in there, a
## one-pass post filter (Mobile supports FXAA and SMAA, Godot 4.7 docs "3D antialiasing"). The two probes cost ~18 % of a tier-1 frame
## on a weak GPU and change under 0.5 % of the pixels (adhoc-1014a: Intel UHD, 1280x720, perf_tier.gd), so tiers 1 and 2 go without.
## Tier 2 also wants a 120 Hz live tick: PhysicsSim.LIVE_TICK is 120 today, so `tick_cap()` is a no-op until that constant is raised.
const TIERS: Array[Dictionary] = [
	{scale = 1.0, msaa = Viewport.MSAA_2X, aa = Viewport.SCREEN_SPACE_AA_DISABLED, fps = 60, trails = true, atlas = 2048, shadow = true, glow = true, probes = true},
	{scale = 0.85, msaa = Viewport.MSAA_DISABLED, aa = Viewport.SCREEN_SPACE_AA_FXAA, fps = 60, trails = true, atlas = 1024, shadow = true, glow = true, probes = false},
	{scale = 0.7, msaa = Viewport.MSAA_DISABLED, aa = Viewport.SCREEN_SPACE_AA_FXAA, fps = 30, trails = false, atlas = 512, shadow = false, glow = false, probes = false},
]
const TICK_CAP_TIER2 := 120

@export var sim: PhysicsSim
@export var active_fps := 60  # 120 is PC-only (07 §2 modes)

static var current_tier := 0
var battery_mode := false: set = set_battery_mode
var ladder := QualityLadder.new()
var paused := false
var idle := false

var _resting := true
var _last_input_ms := 0
var _win_us := 0
var _win_frames := 0
var _prev_us := 0
var _applied_fps := -1
var _cam: Camera3D                 ## the viewport's camera last seen: a new one (cutscene, skin preview) gets the glare flags too
var _bench := -1.0                 ## first-run benchmark (DeviceClass): -1 none, else seconds since it began
var _bench_at := 0                 ## the tier it measures at
var _bench_cost := PackedFloat32Array()
var _bench_delta := PackedFloat32Array()
var _bench_gpu_seen := false


func _ready() -> void:
	add_to_group(Settings.GROUP)
	add_to_group(GlareFlags.GROUP)
	if sim != null:
		sim.shot_started.connect(func(_b: Ball, _i: ShotIntent) -> void: _resting = false)
		sim.all_resting.connect(func() -> void: _resting = true)
		_resting = sim.awake == 0
	_last_input_ms = Time.get_ticks_msec()
	_prev_us = Time.get_ticks_usec()
	if Settings.quality_tier() < 0:  # Auto: start where this device belongs, not at tier 0 (DeviceClass)
		ladder.tier = DeviceClass.start_tier()
		var saved := DeviceClass.saved()
		if not saved.is_empty():
			ladder.floor_tier = int(saved.tier)
		elif DeviceClass.needs_benchmark():
			_bench_at = ladder.tier
			_bench = 0.0
	_on_settings_changed()
	GlareFlags.apply.call_deferred(get_tree())  # after the level's own _ready calls have built its cameras and viewports


## Settings.quality: Auto leaves the ladder running, High / Medium / Low pin tier 0 / 1 / 2 (docs/plan/06 P11).
func _on_settings_changed() -> void:
	var before := ladder.tier
	var fixed := Settings.quality_tier()
	if fixed >= 0:
		ladder.tier = fixed
	_apply_tier()
	_apply_fps()
	if ladder.tier != before:
		tier_changed.emit(ladder.tier)


func set_battery_mode(on: bool) -> void:
	battery_mode = on
	if is_inside_tree():
		_apply_fps()


## Live tick to use for `base` under the current tier (07 §7.4 tier 2: 120 Hz); PhysicsSim calls it on strike.
static func tick_cap(base: int) -> int:
	return mini(base, TICK_CAP_TIER2) if current_tier >= 2 else base


func trails_enabled() -> bool:
	return TIERS[ladder.tier].trails


## Anything that moves without input (remote player pose, effect animation) calls this to hold 60 fps.
func keep_awake() -> void:
	_last_input_ms = Time.get_ticks_msec()
	if idle:
		idle = false
		_reset_window()
		_apply_fps()


func _input(_event: InputEvent) -> void:
	keep_awake()


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != _cam:
		_cam = cam
		GlareFlags.apply(get_tree())
	if _bench >= 0.0:
		_bench_step(delta)
		return
	var now_us := Time.get_ticks_usec()
	var dt := now_us - _prev_us
	_prev_us = now_us
	var idle_now := _resting and Time.get_ticks_msec() - _last_input_ms > IDLE_AFTER_MS
	if idle_now != idle:
		idle = idle_now
		_apply_fps()
		_reset_window()
	if paused or idle or Settings.quality_tier() >= 0:
		return
	_win_us += dt
	_win_frames += 1
	if _win_us >= int(WINDOW_S * 1e6):
		var mean := _win_frames / (_win_us * 1e-6)
		var before := ladder.tier
		ladder.on_window(mean, float(_target_fps()), now_us * 1e-6)
		_reset_window()
		if ladder.tier != before:
			_apply_tier()
			_apply_fps()
			tier_changed.emit(ladder.tier)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_set_paused(true)
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_set_paused(false)


func _set_paused(p: bool) -> void:
	if p == paused:
		return
	paused = p
	AudioServer.set_bus_mute(0, p)
	_last_input_ms = Time.get_ticks_msec()
	_reset_window()
	_apply_fps()
	(app_paused if p else app_resumed).emit()


func _target_fps() -> int:
	if paused:
		return BACKGROUND_FPS
	var cap: int = TIERS[ladder.tier].fps
	if battery_mode:
		cap = mini(cap, BATTERY_FPS)
	cap = mini(cap, active_fps)
	return mini(cap, IDLE_FPS) if idle else cap


func _apply_fps() -> void:
	var f := _target_fps()
	if f != _applied_fps:
		_applied_fps = f
		Engine.max_fps = f


func _apply_tier() -> void:
	current_tier = ladder.tier
	var t := GlareFlags.viewport_for(TIERS[ladder.tier])
	var vp := get_viewport()
	vp.scaling_3d_scale = t.scale
	vp.msaa_3d = t.msaa
	vp.screen_space_aa = t.aa
	vp.positional_shadow_atlas_size = TIERS[ladder.tier].atlas
	GlareFlags.apply(get_tree())


## GlareFlags changed (the debug panel, or a tool): the viewport's AA / scale and every node the flags reach.
func _on_glare_changed() -> void:
	_apply_tier()


# --- first-run benchmark (DeviceClass) ---------------------------------------------------------------------------------------------

## ~3 s of real frames after a 1.5 s warm-up, uncapped, at the heuristic's start tier. A frame's cost is the slower of the GPU's
## measured time and the CPU's render setup + physics (`Performance.TIME_PROCESS` is the whole frame, vsync wait included, so it
## cannot be used). A phone's vsync hides a fast device behind 16.7 ms, which is why the cost is read from the renderer's own timers
## and not from the frame delta; the delta only counts when it is clearly late (over the tier's budget by 15 %), which catches a
## script-bound or timer-less device and can only demote. The median is kept (a hitch is not the device); the tier is
## `DeviceClass.tier_from_cost`.
func _bench_step(delta: float) -> void:
	var rid := get_viewport().get_viewport_rid()
	if _bench == 0.0:
		RenderingServer.viewport_set_measure_render_time(rid, true)
		Engine.max_fps = 0
		_applied_fps = -1
	_bench += delta
	if _bench > DeviceClass.WARMUP_S:
		var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
		var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_bench_gpu_seen = _bench_gpu_seen or gpu > 0.0
		_bench_cost.append(maxf(gpu, cpu))
		_bench_delta.append(delta * 1000.0)
	if _bench < DeviceClass.WARMUP_S + DeviceClass.BENCH_S or paused:
		return
	RenderingServer.viewport_set_measure_render_time(rid, false)
	var cost := _median(_bench_cost)
	var late := _median(_bench_delta)
	if late > 1000.0 / (30.0 if _bench_at >= 2 else 60.0) * 1.15:
		cost = maxf(cost, late)
	_bench = -1.0
	var before := ladder.tier
	ladder.tier = DeviceClass.tier_from_cost(_bench_at, cost) if cost > 0.0 else _bench_at
	ladder.floor_tier = ladder.tier
	DeviceClass.save(ladder.tier, cost)
	_reset_window()
	_apply_tier()
	_apply_fps()
	if ladder.tier != before:
		tier_changed.emit(ladder.tier)


static func _median(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]


func _reset_window() -> void:
	_win_us = 0
	_win_frames = 0
