class_name StreamManager
extends Node
## Viewers, hype, tips and the one Viewer_Scalar (docs/plan/02 §3.2–3.3). GameLoop drives it.

signal viewers_changed(viewers: int, hype: float)
signal tip_received(amount: int)

const POT_VIEWERS := 25
const TRICK_POT_VIEWERS := 100
const FOUL_VIEWERS := -50
const POT_HYPE := 0.1
const FOUL_HYPE := -0.3
const HYPE_DECAY_PER_SEC := 0.05
const SCALAR_REF_VIEWERS := 500.0  # 02 §3.2: the viewer term is viewers / 500
const TIP_MILESTONE := 500
const TIP_MIN := 25
const TIP_MAX := 150

var viewers := 0
var hype := 0.0

var _pots_this_shot := 0
var _milestone := 0  # highest 500-viewer level already tipped this Night
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	set_process(false)


func reset_for_night(config: NightConfig, rng_seed := 0) -> void:
	viewers = config.base_viewers
	hype = 0.0
	_pots_this_shot = 0
	_milestone = _level()
	_rng.seed = rng_seed
	viewers_changed.emit(viewers, hype)


## Hype only decays while a Round is live; Intermission is for negotiating, not a clock.
func set_live(live: bool) -> void:
	set_process(live)


func viewer_scalar() -> float:
	return 1.0 + (viewers / SCALAR_REF_VIEWERS) * (0.5 + 0.5 * hype)


## Buffer only: EconomyManager must read viewer_scalar() before this shot's pots move it.
func on_ball_potted(ball: Ball, _shot_id: String, _pocket_id: StringName) -> void:
	if ball != null and not ball.is_cue_ball:
		_pots_this_shot += 1


func on_shot_ended(_raw_points: int, trick_ids: Array[StringName], foul: bool) -> void:
	var d_viewers := POT_VIEWERS * _pots_this_shot
	var d_hype := POT_HYPE * _pots_this_shot
	if _pots_this_shot > 0 and not trick_ids.is_empty():
		d_viewers += TRICK_POT_VIEWERS
	if foul:
		d_viewers += FOUL_VIEWERS
		d_hype += FOUL_HYPE
	_pots_this_shot = 0
	viewers = maxi(viewers + d_viewers, 0)
	hype = clampf(hype + d_hype, 0.0, 1.0)
	viewers_changed.emit(viewers, hype)
	while _level() > _milestone:
		_milestone += 1
		tip_received.emit(_rng.randi_range(TIP_MIN, TIP_MAX))


func _process(delta: float) -> void:
	hype = maxf(hype - HYPE_DECAY_PER_SEC * delta, 0.0)


func _level() -> int:
	return floori(viewers / float(TIP_MILESTONE))
