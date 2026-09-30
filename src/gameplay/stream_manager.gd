class_name StreamManager
extends Node
## Viewers, hype, tips and the one Viewer_Scalar (docs/plan/02 §3.2–3.3). GameLoop drives it (host only);
## clients mirror `viewers`/`hype` from update_viewers (04 §5).

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
const NET_PERIOD := 0.25  # hype decay reaches clients at 4 Hz at most

var viewers := 0
var hype := 0.0

var base_viewers_bonus := 0  # stream_overlay
var tip_rate_mult := 1.0  # stream_overlay: tip milestones come this many times as often

var _pots_this_shot := 0
var _net_dirty := false
var _net_accum := 0.0
var _milestone := 0  # highest 500-viewer level already tipped this Night
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	set_process(false)


func reset_for_night(config: NightConfig, rng_seed := 0) -> void:
	viewers = config.base_viewers + base_viewers_bonus
	hype = 0.0
	_pots_this_shot = 0
	_milestone = _level()
	_rng.seed = rng_seed
	_publish()


## Shop upgrades (ItemDelta); re-baselines the tip level so a faster rate never pays out retroactively.
func apply_upgrades(p_base_viewers_bonus: int, p_tip_rate_mult: float) -> void:
	base_viewers_bonus = p_base_viewers_bonus
	tip_rate_mult = p_tip_rate_mult
	_milestone = _level()


## Restores a checkpoint (viewers < 0 = the Night's base).
func restore(p_viewers: int, p_hype: float, config: NightConfig) -> void:
	viewers = p_viewers if p_viewers >= 0 else config.base_viewers + base_viewers_bonus
	hype = p_hype
	_pots_this_shot = 0
	_milestone = _level()
	_publish()


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func update_viewers(count: int, p_hype: float) -> void:
	viewers = count
	hype = p_hype
	viewers_changed.emit(viewers, hype)


## Host: emit locally and mirror. GameLoop re-sends at 1 Hz because unreliable packets can drop.
func _publish() -> void:
	viewers_changed.emit(viewers, hype)
	_net_dirty = false
	_net_accum = 0.0
	if is_inside_tree() and multiplayer.is_server():
		update_viewers.rpc(viewers, hype)


func resend() -> void:
	if is_inside_tree() and multiplayer.is_server():
		update_viewers.rpc(viewers, hype)


## Hype only decays while a Round is live; Intermission is for negotiating, not a clock.
func set_live(live: bool) -> void:
	set_process(live)


## Crew-pool moves from WorldInteractions (03 §3.4): viewers floor at 0, hype clamps to 0–1.
func add_viewers(n: int) -> void:
	viewers = maxi(viewers + n, 0)
	_publish()
	_roll_tips()


func add_hype(x: float) -> void:
	hype = clampf(hype + x, 0.0, 1.0)
	_publish()


func viewer_scalar() -> float:
	return 1.0 + (viewers / SCALAR_REF_VIEWERS) * (0.5 + 0.5 * hype)


## Buffer only: EconomyManager must read viewer_scalar() before this shot's pots move it.
func on_ball_potted(ball: Ball, _shot_id: String, _pocket_id: StringName) -> void:
	if ball != null and not ball.is_cue_ball:
		_pots_this_shot += 1


func on_shot_ended(_raw_points: int, trick_ids: Array[StringName], foul: bool) -> void:
	var d_viewers := FOUL_VIEWERS if foul else POT_VIEWERS * _pots_this_shot
	var d_hype := FOUL_HYPE if foul else POT_HYPE * _pots_this_shot
	if not foul and _pots_this_shot > 0 and not trick_ids.is_empty():
		d_viewers += TRICK_POT_VIEWERS  # a foul Shot scores nothing (01 §3): its pots pay no viewers either
	_pots_this_shot = 0
	if d_viewers > 0:
		d_viewers = roundi(d_viewers * _gain(&"stream_viewer_gain_mult"))
	if d_hype > 0.0:
		d_hype *= _gain(&"stream_hype_gain_mult")
	viewers = maxi(viewers + d_viewers, 0)
	hype = clampf(hype + d_hype, 0.0, 1.0)
	_publish()
	_roll_tips()


func _process(delta: float) -> void:
	var shown := roundi(hype * 100.0)
	hype = maxf(hype - HYPE_DECAY_PER_SEC * delta, 0.0)
	if roundi(hype * 100.0) != shown:
		viewers_changed.emit(viewers, hype)
		_net_dirty = true
	_net_accum += delta
	if _net_dirty and _net_accum >= NET_PERIOD:
		_publish()


func _roll_tips() -> void:
	while _level() > _milestone:
		_milestone += 1
		tip_received.emit(_rng.randi_range(TIP_MIN, TIP_MAX))


func _gain(stat: StringName) -> float:
	var fx := get_node_or_null(^"../EffectManager")
	return fx.get_stat(stat, EffectManager.ALL_PEERS, 1.0) if fx != null else 1.0


func _level() -> int:
	return floori(viewers * tip_rate_mult / float(TIP_MILESTONE))
