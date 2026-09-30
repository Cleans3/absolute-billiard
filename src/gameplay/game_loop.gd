class_name GameLoop
extends Node
## Night/Round state machine, Round clock and shot budget (docs/plan/02 §3.1, §3.4).
## RoundDirector owns the table; this node only starts/ends Rounds and settles each Shot.

enum Phase { NIGHT_START, INTERMISSION, ROUND_SETUP, ROUND_LIVE, ROUND_END, RECKONING, GAME_OVER, CAMPAIGN_WON }

signal night_started(night_number: int, quota: int)  # quota = the demand: Buyout on the final Night
signal round_started(round_index: int, time_limit: float, hazard_tier: int)
signal round_ended(reason: StringName, round_points: int)  # reason: timer | cleared | shots
signal night_ended(success: bool, demand: int)
signal intermission_started()
signal phase_changed(phase: Phase)
signal shot_settled(shot_id: String, cash: int, trick_id: StringName, foul: bool)  # HUD payout line
signal cue_respawned(reason: StringName)  # relayed from RoundDirector for the HUD

@export var round_director: Node  # RoundDirector; retype once its class lands in this tree
@export var economy: EconomyManager
@export var stream: StreamManager
@export var events: Node  # EventScheduler; typed Node like round_director
@export var hud: Control  # kept for the frozen contract; the HUD pulls from this node, not the reverse
@export var nights: Array[NightConfig]

var phase := Phase.NIGHT_START
var campaign_seed := 0
var round_seed := 0
var night_index := 0  # into `nights`
var round_index := 0  # 1-based within the Night
var shots_left := 0
var time_left := 0.0
var round_points := 0  # raw points banked this Round

var _timer_expired := false  # timer hit 0 mid-shot: end the Round when that shot resolves


func _ready() -> void:
	if round_director != null:
		round_director.connect(&"shot_ended", _on_shot_ended)
		round_director.connect(&"table_cleared", _on_table_cleared)
		round_director.connect(&"cue_respawned", func(reason: StringName) -> void: cue_respawned.emit(reason))
		if stream != null:
			round_director.connect(&"ball_potted", stream.on_ball_potted)
	if stream != null:
		stream.tip_received.connect(_on_tip_received)


func _process(delta: float) -> void:
	if phase != Phase.ROUND_LIVE or _timer_expired:
		return
	time_left = maxf(time_left - delta, 0.0)
	if time_left == 0.0:
		_timer_expired = true
		if not _shot_live():
			_end_round(&"timer")


func current_night() -> NightConfig:
	return nights[night_index]


func start_campaign() -> void:
	if nights.is_empty():
		push_error("GameLoop.start_campaign: `nights` is empty")
		return
	campaign_seed = randi()
	night_index = 0
	_begin_night()


## Host only. Intermission → next Round; Reckoning → next Night.
func advance() -> void:
	if not is_host():
		return
	match phase:
		Phase.INTERMISSION:
			_start_round()
		Phase.RECKONING:
			night_index += 1
			_begin_night()


func is_host() -> bool:
	# by path, not the `NetManager` identifier: `-s` probes compile scripts before autoload names exist
	var net := get_node_or_null(^"/root/NetManager")
	return net != null and bool(net.call(&"is_host"))


func _begin_night() -> void:
	var config := current_night()
	round_index = 0
	if stream != null:
		stream.reset_for_night(config, hash([campaign_seed, config.night_number]))
	_set_phase(Phase.NIGHT_START)
	night_started.emit(config.night_number, economy.demand_for(config, _is_final_night()))
	_set_phase(Phase.INTERMISSION)
	intermission_started.emit()


func _start_round() -> void:
	var config := current_night()
	round_index += 1
	round_seed = hash([campaign_seed, config.night_number, round_index])
	round_points = 0
	shots_left = config.shots_per_round
	time_left = config.round_time_limit_sec
	if events != null:  # applies the chosen Event; returns the Round length delta before the timer arms
		time_left += float(events.call(&"begin_round", round_index))
	_timer_expired = false
	_set_phase(Phase.ROUND_SETUP)
	round_director.call(&"start_round", config, round_index, round_seed)
	stream.set_live(true)
	_set_phase(Phase.ROUND_LIVE)
	round_started.emit(round_index, time_left, config.hazard_tiers[round_index - 1])


func _end_round(reason: StringName) -> void:
	_set_phase(Phase.ROUND_END)
	stream.set_live(false)
	round_director.call_deferred(&"end_round")  # not from inside RoundDirector's own shot_ended emit
	round_ended.emit(reason, round_points)
	if round_index < current_night().rounds_count:
		_set_phase(Phase.INTERMISSION)
		intermission_started.emit()
	else:
		_reckon()


func _reckon() -> void:
	var is_final := _is_final_night()
	var passed := economy.evaluate_quota(current_night(), is_final)
	_set_phase(Phase.RECKONING)
	night_ended.emit(passed, economy.demand_for(current_night(), is_final))
	if not passed:
		_set_phase(Phase.GAME_OVER)
	elif is_final:
		_set_phase(Phase.CAMPAIGN_WON)


## One handler, fixed order: pay (reads pre-shot Viewer_Scalar) → stream moves → budget. Every shot, foul or not, costs 1.
func _on_shot_ended(shot_id: String, _shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool) -> void:
	if phase != Phase.ROUND_LIVE:
		return
	var points := 0 if foul else raw_points
	var ids: Array[StringName] = []
	if not foul:
		ids = trick_ids
	var cash := economy.award_shot_reward(points, ids, &"")
	stream.on_shot_ended(points, ids, foul)
	round_points += points
	shots_left -= 1
	shot_settled.emit(shot_id, cash, ids[0] if not ids.is_empty() else &"", foul)
	# table_cleared is emitted after shot_ended, so ask now: a clearing shot ends as `cleared`
	# even when it was also the last of the budget or landed after the timer.
	if _table_cleared():
		_end_round(&"cleared")
	elif shots_left <= 0:
		_end_round(&"shots")
	elif _timer_expired:
		_end_round(&"timer")


func _on_table_cleared(_round_id: String) -> void:
	if phase == Phase.ROUND_LIVE:
		_end_round(&"cleared")


func _on_tip_received(amount: int) -> void:
	economy.add_cash(amount, &"tip")


func _is_final_night() -> bool:
	return night_index == nights.size() - 1


func _table_cleared() -> bool:
	return round_director.has_method(&"is_table_cleared") and bool(round_director.call(&"is_table_cleared"))


func _shot_live() -> bool:
	return bool(round_director.get(&"shot_in_progress"))


func _set_phase(p: Phase) -> void:
	phase = p
	phase_changed.emit(p)
