class_name QualityManager
extends Node

## Frame-rate and quality governor (07 §2 modes, §7). Owns the fps side only — PhysicsSim owns the
## tick (LIVE_TICK live / REST_TICK at rest). Downclocks to 30 fps when the table is at rest and no
## input arrived for IDLE_AFTER_MS, climbs the thermal ladder on a 10 s mean-fps window, and exposes
## app pause/resume for NET/SYNC to hook (07 §3.5, §7.5). A cutscene that has the screen (`cutscene_hold`, adhoc-1014b) is not the bar:
## its frames neither feed the ladder's window nor the first-run benchmark, the idle cap stays off, and its camera cut costs the part's
## nodes a glare pass and not the whole tree.

signal tier_changed(tier: int)
signal app_paused
signal app_resumed

const WINDOW_S := 10.0
const IDLE_AFTER_MS := 2000
const IDLE_FPS := 30
const BACKGROUND_FPS := 10
const BATTERY_FPS := 30
const HOLD_GROUP := &"cutscene_hold"      ## Cutscene calls `cutscene_hold(on, stage)` on it right before its camera goes current and right before it is restored
const CUTSCENE_CAMERA := "CutsceneCamera" ## the name Cutscene.play() gives its fresh Camera3D (a part's own, a child of the part)
const _SEEN := &"glare_seen"                ## meta on a camera the glare switches have been applied for
const HOLD_STALE_FRAMES := 30             ## a hold with no cutscene camera current this long was never released (the part was freed): dropped
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
static var cutscene_holds := 0     ## cutscenes holding the screen right now (this level's `_hold`, 0 once it leaves the tree): Mirror's capture waits on it
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
var _hold := 0                     ## cutscenes holding the screen right now (`cutscene_hold`); this node's own count, so a freed level leaks nothing
var _stale := 0                    ## consecutive frames with a hold and no cutscene camera current


func _ready() -> void:
	add_to_group(Settings.GROUP)
	add_to_group(GlareFlags.GROUP)
	add_to_group(HOLD_GROUP)
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
		_camera_changed(cam)
	if _hold > 0:
		_held_frame(cam)
		return
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


## Group call from Cutscene (adhoc-1014b S2): `on` right before its camera goes current, off right before it is restored; a cut between
## two parts is off then on, so a count and not a flag. A hold ends the frames that belong to the bar's window (the ladder starts a fresh one).
func cutscene_hold(on: bool, _stage := false) -> void:
	var before := _hold
	_hold = maxi(_hold + (1 if on else -1), 0)
	cutscene_holds = _hold
	if (before == 0) != (_hold == 0):
		_reset_window()
		_stale = 0


## A frame a cutscene shows is not the bar's: awake at the tier's own cap (never the idle 30 fps), nothing for the ladder's window, and a
## first-run benchmark that starts over once it ends (its warm-up then covers the cut between two parts). `_prev_us` keeps up, so the
## first frame after the hold is a frame's dt and not the whole cutscene's. A hold whose part was freed never calls off: with no
## cutscene camera current for HOLD_STALE_FRAMES it is dropped.
func _held_frame(cam: Camera3D) -> void:
	_prev_us = Time.get_ticks_usec()
	keep_awake()
	if _bench >= 0.0:
		_bench_restart()
	_stale = 0 if _is_cutscene_camera(cam) else _stale + 1
	if _stale > HOLD_STALE_FRAMES:
		push_warning("QualityManager: a cutscene hold with no cutscene camera for %d frames, dropped" % HOLD_STALE_FRAMES)
		_hold = 0
		cutscene_holds = 0
		_stale = 0
		_reset_window()


static func _is_cutscene_camera(cam: Camera3D) -> bool:
	return cam != null and String(cam.name).begins_with(CUTSCENE_CAMERA)


## The viewport's camera changed. The whole tree is walked only for a camera nobody has seen: a cutscene's own camera gets the switches
## over its part alone (a Cutscene builds its nodes before its camera takes over), and one seen before (the game's, back from a cutscene)
## nothing, the tree did not change under it. Four cuts in the intro used to be four walks over the bar.
func _camera_changed(cam: Camera3D) -> void:
	if cam != null:
		if cam.has_meta(_SEEN):
			return
		cam.set_meta(_SEEN, true)
		if _hold > 0 or _is_cutscene_camera(cam):
			GlareFlags.apply_under(cam.get_parent())
			return
	GlareFlags.apply(get_tree())


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_EXIT_TREE:
			if _hold > 0:  # the level went mid-cutscene: nothing is holding any more
				_hold = 0
				cutscene_holds = 0
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


## A cutscene took the screen mid-benchmark: what it measured so far is the cutscene's. The renderer's timers and the uncapped fps go
## back and it starts over (`_bench` 0.0 = its warm-up first) from the frames after the hold.
func _bench_restart() -> void:
	if _bench > 0.0:  # it had started: its first step took the timers and uncapped the fps
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)
		_applied_fps = -1
		_apply_fps()
	_bench = 0.0
	_bench_cost.clear()
	_bench_delta.clear()
	_bench_gpu_seen = false


static func _median(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]


func _reset_window() -> void:
	_win_us = 0
	_win_frames = 0
