class_name GameLoop
extends Node
## Night/Round state machine, Round clock and shot budget (docs/plan/02 §3.1, §3.4).
## RoundDirector owns the table; this node only starts/ends Rounds and settles each Shot.
## Host runs the rules; clients mirror round_state (04 §5) and re-emit the same signals for the HUD.

enum Phase { NIGHT_START, INTERMISSION, ROUND_SETUP, ROUND_LIVE, ROUND_END, RECKONING, GAME_OVER, CAMPAIGN_WON }

signal night_started(night_number: int, quota: int)  # quota = the demand: Buyout on the final Night
signal round_started(round_index: int, time_limit: float, hazard_tier: int)
signal round_ended(reason: StringName, round_points: int)  # reason: timer | cleared | shots
signal night_ended(success: bool, demand: int)
signal intermission_started()
signal phase_changed(phase: Phase)
signal shot_settled(shot_id: String, cash: int, trick_id: StringName, foul: bool)  # HUD payout line
signal cue_respawned(reason: StringName)  # relayed from RoundDirector for the HUD
signal state_changed()  # time/shots/round/night fields changed (host after a rule, client after a mirror)
signal ready_changed()  # GO LIVE: someone (un)pressed it, or the crew changed (host after a rule, client after a mirror)
signal staging_changed(on: bool)  # relayed from RoundDirector: the table is being set up / cleared (06 P33 A4); the pedestal reads it

const SYNC_PERIOD := 1.0  # live-Round round_state heartbeat; phase changes are sent at once
const STOCK_SALT := 0x5701  # keeps the shelf's seed apart from round_seed's hash of the same three numbers

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
var ready_peers := PackedInt32Array()  # GO LIVE (02 §3.1): peers who pressed it this Intermission; the host owns the set
var waiting_peers := PackedInt32Array()  # ... and the peers whose press the start still waits for

var _timer_expired := false  # timer hit 0 mid-shot: end the Round when that shot resolves
var _endless: Array[NightConfig] = []  # generated Nights 6+, index 0 = Night nights.size()+1
var _best_pot := -1  # base_value of the best ball potted this Shot, and the pocket it fell in
var _best_pocket := &""
var _end_reason := &""
var _last_passed := true
var _sync_accum := 0.0
var _announced_night := -1  # client: last Night whose night_started was re-emitted


func _ready() -> void:
	if round_director != null:
		round_director.connect(&"shot_ended", _on_shot_ended)
		round_director.connect(&"table_cleared", _on_table_cleared)
		round_director.connect(&"cue_respawned", func(reason: StringName) -> void: cue_respawned.emit(reason))
		round_director.connect(&"ball_potted", _on_ball_potted)
		if round_director.has_signal(&"staging_changed"):
			round_director.connect(&"staging_changed", func(on: bool) -> void: staging_changed.emit(on))
	if stream != null:
		stream.tip_received.connect(_on_tip_received)
	if economy != null:
		economy.quota_evaluated.connect(func(paid: int, _demand: int, game_over: bool) -> void: _last_passed = not game_over)
	var net := get_node_or_null(^"/root/NetManager")
	if net != null:  # a peer joining the crew, leaving, or backgrounding changes who GO LIVE waits for
		net.connect(&"roster_changed", _on_crew_changed)
		net.connect(&"peers_away_changed", _on_crew_changed)


func _process(delta: float) -> void:
	if phase != Phase.ROUND_LIVE:
		return
	var waiting := is_staging()  # the Round's clock starts when the set-up has played (06 P33 A4)
	if not is_host():
		if not waiting:
			time_left = maxf(time_left - delta, 0.0)  # cosmetic between round_state packets
		return
	_sync_accum += delta
	if _sync_accum >= SYNC_PERIOD:
		_sync_accum = 0.0
		_push_state()
		if stream != null:
			stream.resend()
	if _timer_expired or waiting:
		return
	time_left = maxf(time_left - delta, 0.0)
	if time_left == 0.0:
		_timer_expired = true
		if not _shot_live():
			_end_round(&"timer")


## Nights 1–5 are authored; 6+ come from Night 5 (02 §3.4 Endless) and are cached.
func current_night() -> NightConfig:
	return night_at(night_index)


func night_at(index: int) -> NightConfig:
	if index < nights.size():
		return nights[index]
	while _endless.size() <= index - nights.size():
		_endless.append(NightConfig.endless(nights[-1], nights.size() + _endless.size() + 1))
	return _endless[index - nights.size()]


## The demand of the Night at `index` (Buyout on the final one), for a board that looks past the current Night.
func ask_for(index: int) -> int:
	return economy.demand_for(night_at(index), index == nights.size() - 1)


func start_campaign() -> void:
	if nights.is_empty():
		push_error("GameLoop.start_campaign: `nights` is empty")
		return
	campaign_seed = randi()
	night_index = 0
	economy.wipe()  # keeps the persistent unlocks only (02 §3.7)
	_begin_night()


## Host only. Rebuilds a checkpoint's Round boundary: Cash, Shop, viewers, then the Intermission before the next Round.
func resume_from(profile: SaveProfile) -> void:
	campaign_seed = profile.campaign_seed
	night_index = maxi(profile.current_night - 1, 0)
	economy.restore(profile)
	if profile.round_index <= 0:
		_begin_night()
		return
	round_index = profile.round_index
	var config := current_night()
	_set_phase(Phase.NIGHT_START)
	night_started.emit(config.night_number, economy.demand_for(config, _is_final_night()))
	stream.restore(profile.viewers, profile.hype, config)
	_set_phase(Phase.INTERMISSION)
	intermission_started.emit()


## Host only. Intermission → next Round; Reckoning → next Night; a won campaign → Endless Night 6.
func advance() -> void:
	if not is_host():
		return
	match phase:
		Phase.INTERMISSION:
			if not is_staging():  # the last Round's clean-up is still playing
				_start_round()
		Phase.RECKONING, Phase.CAMPAIGN_WON:
			night_index += 1
			_begin_night()


## Host. The GO LIVE pedestal (WorldInteractions `go_live`): a press toggles the presser's ready flag; the Round
## starts once every peer the crew waits on has pressed. A peer that left is dropped, one in the background is not waited on.
func toggle_ready(peer_id: int) -> void:
	if not is_host() or phase != Phase.INTERMISSION or is_staging():
		return
	var at := ready_peers.find(peer_id)
	if at >= 0:
		ready_peers.remove_at(at)
	else:
		ready_peers.append(peer_id)
	_refresh_ready()


## Identity of this Intermission's Bartender shelf (06 P17): one Night + Round of one campaign always rolls the same drinks.
func stock_key() -> int:
	return hash([campaign_seed, current_night().night_number, round_index, STOCK_SALT])


## The table is being set up or cleared (RoundDirector.staging): no clock runs, no strike, no GO LIVE (06 P33 A4).
func is_staging() -> bool:
	return round_director != null and round_director.get(&"staging") == true


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
	round_director.set(&"ball_overrides", economy.ball_overrides())  # Shop tier upgrades: value(ball_type)
	round_director.call(&"start_round", economy.round_config(config), round_index, round_seed)
	stream.set_live(true)
	_sync_accum = 0.0
	_set_phase(Phase.ROUND_LIVE)
	round_started.emit(round_index, time_left, config.hazard_tiers[round_index - 1])


func _end_round(reason: StringName) -> void:
	_end_reason = reason
	_set_phase(Phase.ROUND_END)
	stream.set_live(false)
	round_director.call_deferred(&"end_round")  # not from inside RoundDirector's own shot_ended emit
	round_ended.emit(reason, round_points)
	if round_index < current_night().rounds_count:
		_set_phase(Phase.INTERMISSION)
		intermission_started.emit()
	else:
		_reckon()
	_checkpoint()


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
	if phase != Phase.ROUND_LIVE or not is_host():
		return
	var points := 0 if foul else raw_points
	var ids: Array[StringName] = []
	if not foul:
		ids = trick_ids
	var cash := economy.award_shot_reward(points, ids, &"" if foul else _best_pocket)
	_best_pot = -1
	_best_pocket = &""
	stream.on_shot_ended(points, ids, foul)
	round_points += points
	shots_left -= 1
	var trick: StringName = ids[0] if not ids.is_empty() else &""
	shot_settled.emit(shot_id, cash, trick, foul)
	push_shot_settled.rpc(shot_id, cash, trick, foul)
	_push_state()
	# table_cleared is emitted after shot_ended, so ask now: a clearing shot ends as `cleared`
	# even when it was also the last of the budget or landed after the timer.
	if _table_cleared():
		_end_round(&"cleared")
	elif shots_left <= 0:
		_end_round(&"shots")
	elif _timer_expired:
		_end_round(&"timer")


## The pocket that scores the Camera_Mult is the best ball's (02 §3.2); the cue ball never counts.
func _on_ball_potted(ball: Ball, shot_id: String, pocket_id: StringName) -> void:
	if not is_host():
		return
	if stream != null:
		stream.on_ball_potted(ball, shot_id, pocket_id)
	if ball != null and not ball.is_cue_ball:
		var value: int = 0
		if ball.ball_type != null:
			value = int(round_director.call(&"value_of", ball.ball_type)) if round_director.has_method(&"value_of") else ball.ball_type.base_value
		if value > _best_pot:
			_best_pot = value
			_best_pocket = pocket_id


func _on_table_cleared(_round_id: String) -> void:
	if phase == Phase.ROUND_LIVE and is_host():
		_end_round(&"cleared")


func _on_tip_received(amount: int) -> void:
	economy.add_cash(amount, &"tip")


func _is_final_night() -> bool:
	return night_index == nights.size() - 1  # the Buyout is Night 5 only; Endless has plain quotas


func _table_cleared() -> bool:
	return round_director.has_method(&"is_table_cleared") and bool(round_director.call(&"is_table_cleared"))


func _shot_live() -> bool:
	return bool(round_director.get(&"shot_in_progress"))


func _set_phase(p: Phase) -> void:
	phase = p
	phase_changed.emit(p)
	state_changed.emit()
	_push_state()
	_reset_ready()


# --- GO LIVE ready set ----------------------------------------------------------------------------

## Peer ids of the crew: the roster, or the host alone where no roster exists (unit probes).
func _crew() -> PackedInt32Array:
	var net := get_node_or_null(^"/root/NetManager")
	var ids: PackedInt32Array = net.call(&"seat_order") if net != null else PackedInt32Array()
	if ids.is_empty():
		ids.append(1)
	return ids


func _is_away(peer_id: int) -> bool:
	var net := get_node_or_null(^"/root/NetManager")
	return net != null and bool(net.call(&"is_peer_away", peer_id))


## A new phase clears the ready set; an Intermission starts out waiting on everyone.
func _reset_ready() -> void:
	ready_peers = PackedInt32Array()
	waiting_peers = PackedInt32Array()
	if phase == Phase.INTERMISSION:
		for id in _crew():
			if not _is_away(id):
				waiting_peers.append(id)
	ready_changed.emit()
	_push_ready()


func _on_crew_changed() -> void:
	if is_host() and phase == Phase.INTERMISSION:
		_refresh_ready()


func _refresh_ready() -> void:
	var crew := _crew()
	var kept := PackedInt32Array()
	for id in ready_peers:
		if crew.has(id):
			kept.append(id)
	ready_peers = kept
	waiting_peers = PackedInt32Array()
	for id in crew:
		if not ready_peers.has(id) and not _is_away(id):
			waiting_peers.append(id)
	ready_changed.emit()
	_push_ready()
	if phase == Phase.INTERMISSION and waiting_peers.is_empty() and not ready_peers.is_empty():
		advance()


# --- mirror to clients (04 §5) -------------------------------------------------------------------

func _push_state() -> void:
	if is_inside_tree() and multiplayer.is_server():
		round_state.rpc(night_index, round_index, phase, time_left, shots_left, round_points, round_seed, _end_reason, campaign_seed)


func _push_ready() -> void:
	if is_inside_tree() and multiplayer.is_server():
		ready_state.rpc(ready_peers, waiting_peers)


## Host: a client came back from the background (RoundDirector.send_full_state); it just needs the numbers.
func resync_peer(peer_id: int) -> void:
	round_state.rpc_id(peer_id, night_index, round_index, phase, time_left, shots_left, round_points, round_seed, _end_reason, campaign_seed)
	ready_state.rpc_id(peer_id, ready_peers, waiting_peers)


## Clients: adopt the host's numbers and re-emit the signals the host raised, in the host's order.
@rpc("authority", "call_remote", "reliable", 3)
func round_state(p_night: int, p_round: int, p_phase: int, p_time_left: float, p_shots: int, p_points: int, p_seed: int, p_reason: StringName, p_campaign: int) -> void:
	var was := phase
	campaign_seed = p_campaign  # story keys its per-player profile entries by it (09 §2.3)
	night_index = p_night
	round_index = p_round
	time_left = p_time_left
	shots_left = p_shots
	round_points = p_points
	round_seed = p_seed
	_end_reason = p_reason
	state_changed.emit()
	var config := current_night()
	var new_night := p_phase == Phase.NIGHT_START and (_announced_night != night_index or was != Phase.NIGHT_START)
	if p_phase == was and not new_night:
		return
	if new_night:
		_announced_night = night_index
		night_started.emit(config.night_number, economy.demand_for(config, _is_final_night()))
	if (p_phase == Phase.INTERMISSION or p_phase == Phase.RECKONING) and (was == Phase.ROUND_LIVE or was == Phase.ROUND_END):
		round_ended.emit(p_reason, p_points)
	phase = p_phase as Phase
	phase_changed.emit(phase)
	match phase:
		Phase.INTERMISSION:
			intermission_started.emit()
		Phase.ROUND_LIVE:
			round_started.emit(round_index, time_left, config.hazard_tiers[round_index - 1])
		Phase.RECKONING:
			night_ended.emit(_last_passed, economy.demand_for(config, _is_final_night()))


## Clients: who has pressed GO LIVE and who the start still waits on (the pedestal shows both).
@rpc("authority", "call_remote", "reliable", 3)
func ready_state(ready_ids: PackedInt32Array, waiting_ids: PackedInt32Array) -> void:
	ready_peers = ready_ids
	waiting_peers = waiting_ids
	ready_changed.emit()


@rpc("authority", "call_remote", "reliable", 3)
func push_shot_settled(shot_id: String, cash: int, trick_id: StringName, foul: bool) -> void:
	shot_settled.emit(shot_id, cash, trick_id, foul)


# --- checkpoints (04 §2.6) -----------------------------------------------------------------------

## What a resume needs, taken at a Round boundary. After a passed Night the resume point is the next Night's start.
func build_profile() -> SaveProfile:
	var p := SaveProfile.new()
	var config := current_night()
	p.crew_cash = economy.cash
	p.current_night = config.night_number
	p.round_index = round_index
	if round_index >= config.rounds_count:
		p.current_night += 1
		p.round_index = 0
	p.quota_target = economy.demand_for(night_at(p.current_night - 1), p.current_night == nights.size())
	p.viewers = stream.viewers
	p.hype = stream.hype
	p.owned_items = economy.owned.duplicate()
	p.persistent_unlocks = economy.persistent_unlocks().duplicate()
	p.stock_key = economy.stock_key
	for i in economy.stock_size():
		p.stock_ids.append(economy.stock_id(i))
		p.stock_left.append(economy.stock_left(i))
	p.campaign_seed = campaign_seed
	var net := get_node_or_null(^"/root/NetManager")
	p.crew_size = int(net.call(&"get_roster").size()) if net != null else 1
	return p


## Every Round end (host): write it here and push it to every peer, which each write their own copy.
## A finished run (game over / campaign won) deletes the checkpoint on every peer instead; the newest
## SaveManager.KEEP_CHECKPOINTS files are kept, one file per session key, overwritten each Round.
func _checkpoint() -> void:
	var over := phase == Phase.GAME_OVER or phase == Phase.CAMPAIGN_WON
	var blob := PackedByteArray() if over else SaveManager.encode(build_profile())
	var net := get_node_or_null(^"/root/NetManager")
	var roster_size := int(net.call(&"get_roster").size()) if net != null else 1
	var key := SaveManager.checkpoint_key(net.lobby_code if net != null else "", roster_size, net.session_seed if net != null else 0)
	if over:
		SaveManager.delete_checkpoint(key)
	else:
		SaveManager.write_checkpoint(key, blob)
	if net != null and net.has_method(&"push_save_checkpoint"):
		net.rpc(&"push_save_checkpoint", SaveManager.SAVE_VERSION, blob)
