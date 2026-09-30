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
## [scale, msaa, fps cap, trails] per tier (07 §7.4). Tier 2 also wants a 120 Hz live tick:
## PhysicsSim.LIVE_TICK is 120 today, so `tick_cap()` is a no-op until that constant is raised.
const TIERS: Array[Dictionary] = [
	{scale = 1.0, msaa = Viewport.MSAA_2X, fps = 60, trails = true},
	{scale = 0.85, msaa = Viewport.MSAA_DISABLED, fps = 60, trails = true},
	{scale = 0.85, msaa = Viewport.MSAA_DISABLED, fps = 30, trails = false},
]
const TICK_CAP_TIER2 := 120

@export var sim: PhysicsSim
@export var active_fps := 60  # 120 is PC-only (07 §2 modes)

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


func _ready() -> void:
	if sim != null:
		sim.shot_started.connect(func(_b: Ball, _i: ShotIntent) -> void: _resting = false)
		sim.all_resting.connect(func() -> void: _resting = true)
		_resting = sim.awake == 0
	_last_input_ms = Time.get_ticks_msec()
	_prev_us = Time.get_ticks_usec()
	_apply_tier()
	_apply_fps()


func set_battery_mode(on: bool) -> void:
	battery_mode = on
	if is_inside_tree():
		_apply_fps()


## Live tick to use for `base` under the current tier (07 §7.4 tier 2: 120 Hz).
func tick_cap(base: int) -> int:
	return mini(base, TICK_CAP_TIER2) if ladder.tier >= 2 else base


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


func _process(_delta: float) -> void:
	var now_us := Time.get_ticks_usec()
	var dt := now_us - _prev_us
	_prev_us = now_us
	var idle_now := _resting and Time.get_ticks_msec() - _last_input_ms > IDLE_AFTER_MS
	if idle_now != idle:
		idle = idle_now
		_apply_fps()
		_reset_window()
	if paused or idle:
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
	var t: Dictionary = TIERS[ladder.tier]
	var vp := get_viewport()
	vp.scaling_3d_scale = t.scale
	vp.msaa_3d = t.msaa


func _reset_window() -> void:
	_win_us = 0
	_win_frames = 0
