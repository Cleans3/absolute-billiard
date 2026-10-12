class_name EventScheduler
extends Node
## Crew-chosen Events (docs/plan/03 §3.2). Builds 3 eligible offers at Intermission before Rounds 2/3,
## runs the vote, and applies the winner when GameLoop starts the Round. No rolling: the crew prices a bet.

signal event_offer_ready(round_index: int, tier: int, event_ids: Array[StringName])
signal event_applied(event_id: StringName, tier: int, reward_mult: float)
signal event_ended(event_id: StringName)
signal event_warning(event_id: StringName, lead_time_sec: float)  # a forced scripted_first Event is next
signal ball_shuffle_requested(count: int)  # Round start and half-time; RoundDirector re-rolls that many BallTypes

const OFFER_SIZE := 3
const VOTE_TIMEOUT_SEC := 20.0  # [tune]

@export var effects: EffectManager
@export var game_loop: GameLoop
@export var table: Table  # pocket ids for pocket_jackpot

var pocket_ids: Array[StringName] = []  # filled from `table` on first use; probes set it directly
var active_pocket := &""  # the pocket a RANDOM_POCKET Event (pocket_jackpot) pays on this Round, on every peer; ImpactFx marks it
var rng := RandomNumberGenerator.new()

var _offer: Array[StringName] = []
var _votes := {}  # peer_id -> event_id
var _vote_left := 0.0
var _chosen: Event
var _active: Event
var _used := {}  # this Night
var _seen := {}  # this campaign: scripted_first Events already met
var _half_at := -1.0  # GameLoop.time_left at which the half-time shuffle fires; < 0 = none pending


func _ready() -> void:
	set_process(false)
	if game_loop != null:
		game_loop.intermission_started.connect(_on_intermission)
		game_loop.round_ended.connect(_on_round_ended)
		game_loop.night_started.connect(func(_n: int, _q: int) -> void: _used.clear())


func _process(delta: float) -> void:
	if not _offer.is_empty():
		_vote_left -= delta
		if _vote_left <= 0.0:
			_resolve()
	if _half_at >= 0.0 and game_loop != null and game_loop.time_left <= _half_at:
		_half_at = -1.0
		ball_shuffle_requested.emit(_shuffle_count())
	if _offer.is_empty() and _half_at < 0.0:
		set_process(false)


func _is_host() -> bool:
	return multiplayer.is_server()


func vote_seconds_left() -> float:
	return maxf(_vote_left, 0.0)


# --- offer + vote ------------------------------------------------------------------------------

func _on_intermission() -> void:
	if not _is_host():
		return
	var config := game_loop.current_night()
	var next := game_loop.round_index + 1
	if next > config.rounds_count or next > config.hazard_tiers.size() or config.hazard_tiers[next - 1] <= 0:
		return
	offer(next, config.hazard_tiers[next - 1], config.night_number)


## Host. Forced scripted_first Event, else 3 eligible ones to vote on. Returns the ids offered.
func offer(round_index: int, tier: int, night_number: int) -> Array[StringName]:
	rng.seed = hash([game_loop.campaign_seed if game_loop != null else 0, night_number, round_index])
	_chosen = null
	_offer.clear()
	_votes.clear()
	var normal: Array[Event] = []
	for e in FxCatalog.EVENTS:
		if e.tier != tier or e.min_night > night_number or _used.has(e.id):
			continue
		if e.scripted_first and not _seen.has(e.id):
			_chosen = e  # the crew meets it once before it becomes a choice
			break
		normal.append(e)
	var ids: Array[StringName] = []
	if _chosen != null:
		ids.append(_chosen.id)
		event_warning.emit(_chosen.id, _chosen.warning_lead_time_sec)
	else:
		while ids.size() < OFFER_SIZE and not normal.is_empty():
			ids.append(normal.pop_at(rng.randi() % normal.size()).id)
		_offer = ids.duplicate()
		_vote_left = VOTE_TIMEOUT_SEC
		set_process(not _offer.is_empty())
	if not ids.is_empty():
		event_offer.rpc(round_index, tier, ids)
	return ids


@rpc("authority", "call_local", "reliable", 3)
func event_offer(round_index: int, tier: int, event_ids: Array[StringName]) -> void:
	event_offer_ready.emit(round_index, tier, event_ids)


## Anyone votes for one of the offered ids; the host is the only one who counts.
@rpc("any_peer", "call_local", "reliable", 3)
func submit_event_vote(event_id: StringName) -> void:
	if not _is_host() or not _offer.has(event_id):
		return
	var peer := multiplayer.get_remote_sender_id()
	_votes[1 if peer == 0 else peer] = event_id
	if _votes.size() >= multiplayer.get_peers().size() + 1:  # solo: the first pick is final
		_resolve()


## Most votes wins; a tie or no votes goes to the host's pick, else the first card.
func _resolve() -> void:
	if _offer.is_empty():
		return
	var tally := {}
	var best := 0
	for id: StringName in _votes.values():
		tally[id] = int(tally.get(id, 0)) + 1
		best = maxi(best, tally[id])
	var tied: Array[StringName] = []
	for id in _offer:
		if best > 0 and int(tally.get(id, 0)) == best:
			tied.append(id)
	var pick := _offer[0]
	if tied.size() == 1:
		pick = tied[0]
	elif _votes.has(1) and (tied.is_empty() or tied.has(_votes[1])):
		pick = _votes[1]
	elif not tied.is_empty():
		pick = tied[0]
	_chosen = FxCatalog.event(pick)
	_offer.clear()
	_votes.clear()


# --- applying ----------------------------------------------------------------------------------

## Host, from GameLoop._start_round before the timer arms. Applies the chosen Event (settling an open
## vote first) and returns the Round length delta from it and from live Effects (energy_drink).
func begin_round(round_index: int) -> float:
	_resolve()
	var bonus := effects.round_time_add() if effects != null else 0.0
	if _chosen != null:
		var pocket := _roll_for(_chosen)
		bonus += _chosen.round_time_add_sec
		_used[_chosen.id] = true
		_seen[_chosen.id] = true
		apply_event.rpc(_chosen.id, round_index, pocket)
		if _touches(_chosen, &"ball_type_shuffle_count"):
			ball_shuffle_requested.emit.call_deferred(_shuffle_count())  # after start_round drops the rack
			_half_at = (game_loop.current_night().round_time_limit_sec + bonus) * 0.5
			set_process(true)
		_chosen = null
	return bonus


## Host: an Event right now, outside the vote (the slot's chaos payout, 02 §3.8). One hazard at a time: false when one
## already runs or the id is unknown.
func trigger_now(event_id: StringName, round_index: int) -> bool:
	var e := FxCatalog.event(event_id)
	if e == null or _active != null:
		return false
	apply_event.rpc(e.id, round_index, _roll_for(e))
	if _touches(e, &"ball_type_shuffle_count"):
		ball_shuffle_requested.emit(_shuffle_count())
	return true


## The host's rolls an Event needs before it applies: its pocket (RANDOM_POCKET) and the tilt direction.
func _roll_for(e: Event) -> StringName:
	var pocket := &""
	if e.opportunity == Event.Opportunity.RANDOM_POCKET:
		var pockets := _pockets()
		pocket = pockets[rng.randi() % pockets.size()]
	if _touches(e, &"table_tilt_deg"):
		effects.set_tilt_direction(Vector2.from_angle(rng.randf() * TAU))
	return pocket


@rpc("authority", "call_local", "reliable", 3)
func apply_event(event_id: StringName, _round_index: int, pocket_id: StringName) -> void:
	var e := FxCatalog.event(event_id)
	if e == null:
		return
	_active = e
	active_pocket = pocket_id
	effects.begin_event(e, pocket_id)
	event_applied.emit(e.id, e.tier, e.reward_mult)


func _on_round_ended(_reason: StringName, _round_points: int) -> void:
	_half_at = -1.0
	_chosen = null
	active_pocket = &""
	if _active != null:
		var id := _active.id
		_active = null
		event_ended.emit(id)


func _touches(e: Event, stat: StringName) -> bool:
	return e.effects.any(func(x: Effect) -> bool: return x.stat_modifiers.any(func(m: StatMod) -> bool: return m.stat == stat))


func _shuffle_count() -> int:
	return roundi(effects.get_stat(&"ball_type_shuffle_count", EffectManager.ALL_PEERS, 0.0))


func _pockets() -> Array[StringName]:
	if pocket_ids.is_empty() and table != null:
		for p in table.layout.pockets:
			pocket_ids.append(p.id)
	return pocket_ids
