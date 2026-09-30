class_name QualityLadder
extends RefCounted

## Pure thermal-ladder state machine (07 §7.4). Fed one mean-fps sample per 10 s window; returns the
## tier to run next. Degrades one step when the mean sags, recovers one step per dwell (>= 60 s) and
## doubles the dwell (cap 8 min) if the recovery was undone within 30 s — that is the anti-oscillation.

const MAX_TIER := 2
const DEGRADE_RATIO := 55.0 / 60.0  # 07 §7.4: "mean fps < 55" at a 60 fps target, same ratio at 30
const RECOVER_RATIO := 0.96
const BASE_DWELL_S := 60.0
const MAX_DWELL_S := 480.0
const UNDO_WINDOW_S := 30.0

var tier := 0
var _changed_at_s := -1e9
var _dwell_s := BASE_DWELL_S
var _last_was_recovery := false


func on_window(mean_fps: float, target_fps: float, now_s: float) -> int:
	if mean_fps < target_fps * DEGRADE_RATIO:
		if tier < MAX_TIER:
			if _last_was_recovery and now_s - _changed_at_s < UNDO_WINDOW_S:
				_dwell_s = minf(_dwell_s * 2.0, MAX_DWELL_S)
			_move(tier + 1, now_s, false)
	elif tier > 0 and mean_fps >= target_fps * RECOVER_RATIO and now_s - _changed_at_s >= _dwell_s:
		_move(tier - 1, now_s, true)
	return tier


func _move(to: int, now_s: float, recovery: bool) -> void:
	tier = to
	_changed_at_s = now_s
	_last_was_recovery = recovery
