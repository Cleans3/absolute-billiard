class_name EffectManager
extends Node
## Live Effects, stat resolution and Reward_Multiplier (docs/plan/03 §2–§3, §5; contract §6).
## Host decides and broadcasts `apply_effect`; every peer mirrors the list and expires it from its own
## local Shot / Round signals, so no expiry RPC exists. VIEW effects are kept only by the peer they land on.

signal effect_applied(effect_id: StringName, target: int, owner_peer_id: int, duration_sec: float)
signal effect_expired(effect_id: StringName, target: int, owner_peer_id: int)
signal reward_multiplier_changed(new_value: float)
signal shooter_changed(peer_id: int)
signal drink_refused(drink_id: StringName, peer_id: int, reason: StringName)
signal visual_hook_started(tag: StringName)
signal visual_hook_stopped(tag: StringName)
signal live_changed  ## any Effect, Drink or Event came or went (the Blackboard re-reads `live_drinks` / `live_events`)

const MAX_LIVE_DRINKS := 3  # [tune] per player
const DRINK_MULT_CAP := 2.0  # [tune]
const EVENT_MULT_CAP := 3.0  # [tune]
const MAX_HOOKS := 2  # 03 §3.8
const ALL_PEERS := -1  # get_stat subject: every live Effect, whoever it lands on
const ROUND := -1  # duration_ms sentinels, shared with the apply_effect RPC
const SHOT := -2


class LiveEffect:
	extends RefCounted
	var effect: Effect
	var owner_peer_id := 0  # who caused it
	var target_id := 0  # subject peer for PLAYER/CUE/VIEW (0 = crew); rail id for a rail-scoped TABLE effect
	var duration_ms := 0
	var remaining := 0.0

	func is_rail_scoped() -> bool:
		return effect.target == Effect.Target.TABLE and target_id != 0

	func is_player_scoped() -> bool:
		return effect.target in [Effect.Target.PLAYER, Effect.Target.CUE, Effect.Target.VIEW]


class LiveDrink:
	extends RefCounted
	var drink: Drink
	var peer_id := 0
	var reward_mult := 1.0
	var gift := false  # neighbours_round's buff to the seat-left player: no slot, no effects
	var effect_ids: Array[StringName] = []


class ActiveEvent:
	extends RefCounted
	var event: Event
	var pocket := &""  # RANDOM_POCKET: the host-chosen pocket
	var spent := false  # NEXT_POT: already paid out


@export var sim: Node  # PhysicsSim; typed Node so probes can stand in
@export var round_director: Node  # RoundDirector
@export var game_loop: GameLoop

## Seat order by peer id (NetManager.seat_order); swappable so tests need no session.
var seat_order_source: Callable = _net_seat_order
var rng := RandomNumberGenerator.new()

var _live: Array[LiveEffect] = []
var _drinks: Array[LiveDrink] = []
var _events: Array[ActiveEvent] = []
var _hooks: Array[StringName] = []
var _pushed := {}  # stat -> last value sent to the sim
var _pushed_rails := {}  # rail id -> last mult sent
var _tilt_dir := Vector2.ZERO
var _night_uses := {}  # "peer:drink" -> count this Night
var _shot_pockets: Array[StringName] = []  # non-cue pots of the Shot being resolved
var _last_reward := 1.0
var _last_shooter := 0


func _ready() -> void:
	set_process(false)
	rng.randomize()
	if sim != null:
		sim.set(&"stat_source", get_stat)
	if round_director != null:
		round_director.connect(&"shot_ended", _on_shot_ended)
		round_director.connect(&"ball_potted", _on_ball_potted)
	if game_loop != null:
		game_loop.round_ended.connect(_on_round_ended)
		game_loop.night_started.connect(func(_n: int, _q: int) -> void: _night_uses.clear())


func _process(delta: float) -> void:
	var timed := false
	for i in range(_live.size() - 1, -1, -1):
		var le := _live[i]
		if le.duration_ms <= 0:
			continue
		le.remaining -= delta
		if le.remaining <= 0.0:
			_remove(le)
		else:
			timed = true
	if not timed:
		set_process(false)


func _is_host() -> bool:
	return multiplayer.is_server()


# --- stat resolution (03 §2.1) -----------------------------------------------------------------

## base → all ADD summed → all MUL multiplied, then the §2.2 floor. `peer_id` = the player the stat is
## read for; crew-wide Effects (target_id 0) count unless `include_crew` is false.
func get_stat(stat: StringName, peer_id: int, base: float, include_crew := true) -> float:
	var add := 0.0
	var mul := 1.0
	var touched := false
	for le in _live:
		if le.is_rail_scoped() or not _matches(le, peer_id, include_crew):
			continue
		for m in le.effect.stat_modifiers:
			if m.stat != stat:
				continue
			touched = true
			if m.op == StatMod.Op.ADD:
				add += m.value
			else:
				mul *= m.value
	if not touched:
		return base
	var v := (base + add) * mul
	return maxf(v, Stats.FLOORS[stat]) if Stats.FLOORS.has(stat) else v


## Product of the MUL mods on one rail's cushion restitution (lean_on_rail).
func rail_restitution_mult(rail_id: int) -> float:
	var mult := 1.0
	for le in _live:
		if le.is_rail_scoped() and le.target_id == rail_id:
			for m in le.effect.stat_modifiers:
				if m.stat == &"cushion_restitution_mult":
					mult *= m.value
	return mult


func _matches(le: LiveEffect, peer_id: int, include_crew: bool) -> bool:
	if peer_id == ALL_PEERS or not le.is_player_scoped():
		return true
	return le.target_id == peer_id or (include_crew and le.target_id == 0)


# --- Reward_Multiplier (03 §3.1) ---------------------------------------------------------------

func get_reward_multiplier() -> float:
	var drink_mult := 1.0
	for d in _drinks:
		drink_mult *= d.reward_mult
	var event_mult := 1.0
	for a in _events:
		event_mult *= a.event.reward_mult
	return clampf(drink_mult, 1.0, DRINK_MULT_CAP) * clampf(event_mult, 1.0, EVENT_MULT_CAP)


## Opportunity Events' targeted payoff for the Shot being resolved (crowd_roar, pocket_jackpot).
## Separate from get_reward_multiplier(): those Events carry reward_mult 1.0 by design (03 §3.6).
## Shot-level until ECON prices each pot on its own.
func pot_bonus() -> float:
	var bonus := 1.0
	for a in _events:
		match a.event.opportunity:
			Event.Opportunity.NEXT_POT:
				if not a.spent and not _shot_pockets.is_empty():
					bonus *= a.event.opportunity_mult
			Event.Opportunity.RANDOM_POCKET:
				if _shot_pockets.has(a.pocket):
					bonus *= a.event.opportunity_mult
	return bonus


# --- applying ----------------------------------------------------------------------------------

## Host: apply one Effect and broadcast it. `target_id` = subject peer (PLAYER/CUE/VIEW) or rail id.
func apply(effect_id: StringName, owner_peer_id: int, target_id := 0) -> void:
	assert(_is_host(), "EffectManager.apply is host-only")
	var e := FxCatalog.effect(effect_id)
	if e == null:
		push_error("EffectManager.apply: unknown effect '%s'" % effect_id)
		return
	apply_effect.rpc(effect_id, owner_peer_id, target_id, duration_ms_of(e))


## duration_ms: 0 instant, -1 until Round end, -2 until the Shot resolves (tick rate changes at rest).
@rpc("authority", "call_local", "reliable", 3)
func apply_effect(effect_id: StringName, owner_peer_id: int, target_id: int, duration_ms: int) -> void:
	var e := FxCatalog.effect(effect_id)
	if e != null:
		apply_local(e, owner_peer_id, target_id, duration_ms)


## Host: a client came back from the background (RoundDirector.send_full_state). Effects it is missing are
## added, the ones it has get the host's remaining time; a client never loses an Effect it applied locally.
func resync_peer(peer_id: int) -> void:
	var ids := PackedStringArray()
	var owners := PackedInt32Array()
	var targets := PackedInt32Array()
	var durations := PackedInt32Array()
	var remaining := PackedFloat32Array()
	for le in _live:
		ids.append(le.effect.id)
		owners.append(le.owner_peer_id)
		targets.append(le.target_id)
		durations.append(le.duration_ms)
		remaining.append(le.remaining)
	_resync_effects_rpc.rpc_id(peer_id, ids, owners, targets, durations, remaining)


@rpc("authority", "call_remote", "reliable", 3)
func _resync_effects_rpc(ids: PackedStringArray, owners: PackedInt32Array, targets: PackedInt32Array, durations: PackedInt32Array, remaining: PackedFloat32Array) -> void:
	for i in ids.size():
		var e := FxCatalog.effect(StringName(ids[i]))
		if e == null:
			continue
		var le := _find(e.id, targets[i])
		if le == null:
			le = apply_local(e, owners[i], targets[i], durations[i])
		if le != null:
			le.remaining = remaining[i]
	_changed()


static func duration_ms_of(e: Effect) -> int:
	return roundi(e.duration_sec * 1000.0) if e.duration_sec > 0.0 else int(e.duration_sec)


## What every peer runs for an applied Effect. Returns the live instance, or null when the Effect was
## instant, ignored, or is a VIEW Effect landing on another player.
func apply_local(e: Effect, owner_peer_id: int, target_id: int, duration_ms: int) -> LiveEffect:
	if e.target == Effect.Target.VIEW and target_id != 0 and target_id != multiplayer.get_unique_id():
		return null
	if e.clears_tag != &"":
		_clear_tag(e.clears_tag, target_id)
	if duration_ms == 0:
		effect_applied.emit(e.id, e.target, owner_peer_id, 0.0)
		_changed()
		return null
	var le := _find(e.id, target_id)
	if le != null:
		if e.stacking_rule == Effect.Stacking.REFRESH:
			le.owner_peer_id = owner_peer_id
			le.remaining = maxf(duration_ms / 1000.0, 0.0)
			effect_applied.emit(e.id, e.target, owner_peer_id, le.remaining)
		return le
	if e.exclusive_group != &"":
		for i in range(_live.size() - 1, -1, -1):
			if _live[i].effect.exclusive_group == e.exclusive_group and _live[i].target_id == target_id:
				_remove(_live[i])
	le = LiveEffect.new()
	le.effect = e
	le.owner_peer_id = owner_peer_id
	le.target_id = target_id
	le.duration_ms = duration_ms
	le.remaining = maxf(duration_ms / 1000.0, 0.0)
	_live.append(le)
	if duration_ms > 0:
		set_process(true)
	if e.visual_hook != &"":
		_hook_start(e.visual_hook)
	effect_applied.emit(e.id, e.target, owner_peer_id, le.remaining)
	_changed()
	return le


func _find(effect_id: StringName, target_id: int) -> LiveEffect:
	for le in _live:
		if le.effect.id == effect_id and le.target_id == target_id:
			return le
	return null


func is_live(effect_id: StringName, target_id := 0) -> bool:
	return _find(effect_id, target_id) != null


func live_count() -> int:
	return _live.size()


## The Drinks in effect as [{drink: Drink, peer_id: int, gift: bool}]; a neighbour's gift is listed under the player it lands on.
func live_drinks() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in _drinks:
		out.append({drink = r.drink, peer_id = r.peer_id, gift = r.gift})
	return out


## The Events running this Round (cleared when it ends).
func live_events() -> Array[Event]:
	var out: Array[Event] = []
	for a in _events:
		out.append(a.event)
	return out


func _remove(le: LiveEffect) -> void:
	_live.erase(le)
	var hook := le.effect.visual_hook
	if hook != &"" and _hooks.has(hook) and not _live.any(func(o: LiveEffect) -> bool: return o.effect.visual_hook == hook):
		_hook_stop(hook)
	effect_expired.emit(le.effect.id, le.effect.target, le.owner_peer_id)
	_prune_drinks()
	_changed()


func _clear_tag(tag: StringName, target_id: int) -> void:
	for i in range(_live.size() - 1, -1, -1):
		if _live[i].effect.tag == tag and _live[i].target_id == target_id:
			_remove(_live[i])


## `sentinel` = ROUND or SHOT.
func _expire(sentinel: int) -> void:
	for i in range(_live.size() - 1, -1, -1):
		if _live[i].duration_ms == sentinel:
			_remove(_live[i])


func _on_shot_ended(_shot_id: String, _shooter_id: int, _raw_points: int, _trick_ids: Array[StringName], foul: bool) -> void:
	_expire(SHOT)
	_finish_shot.call_deferred(foul)  # after every shot_ended handler has read pot_bonus()


func _finish_shot(foul: bool) -> void:
	if not foul and not _shot_pockets.is_empty():
		for a in _events:
			if a.event.opportunity == Event.Opportunity.NEXT_POT:
				a.spent = true
	_shot_pockets.clear()
	_refresh_table_stats()  # the shooter has rotated
	var shooter := current_shooter()
	if shooter != _last_shooter:
		_last_shooter = shooter
		shooter_changed.emit(shooter)


func _on_ball_potted(ball: Ball, _shot_id: String, pocket_id: StringName) -> void:
	if ball != null and not ball.is_cue_ball:
		_shot_pockets.append(pocket_id)


func _on_round_ended(_reason: StringName, _round_points: int) -> void:
	_expire(ROUND)
	_drinks.clear()
	_events.clear()
	_changed()


func _changed() -> void:
	live_changed.emit()
	_refresh_table_stats()
	var reward := get_reward_multiplier()
	if not is_equal_approx(reward, _last_reward):
		_last_reward = reward
		reward_multiplier_changed.emit(reward)


# --- Events (driven by EventScheduler, run on every peer) -------------------------------------

func begin_event(event: Event, pocket := &"") -> void:
	var a := ActiveEvent.new()
	a.event = event
	a.pocket = pocket
	_events.append(a)
	for e in event.effects:
		apply_local(e, 0, 0, duration_ms_of(e))
	_changed()


## Round length delta from live Effects (energy_drink), every subject; Events add theirs via EventScheduler.
func round_time_add() -> float:
	return get_stat(&"round_time_add_sec", ALL_PEERS, 0.0)


# --- Drinks (03 §3.3, §3.5) --------------------------------------------------------------------

## Host. Returns &"" when served, else the refusal reason (also emitted as `drink_refused`).
func serve_drink(drink_id: StringName, drinker_peer_id: int, server_peer_id := 0) -> StringName:
	assert(_is_host(), "EffectManager.serve_drink is host-only")
	var d := FxCatalog.drink(drink_id)
	var reason := _refusal(d, drinker_peer_id)
	if reason != &"":
		drink_refused.emit(drink_id, drinker_peer_id, reason)
		return reason
	if d.night_limit > 0:
		var key := "%d:%s" % [drinker_peer_id, drink_id]
		_night_uses[key] = int(_night_uses.get(key, 0)) + 1
	var rec := _record_of(d.id, drinker_peer_id)
	if rec == null:
		rec = LiveDrink.new()
		rec.drink = d
		rec.peer_id = drinker_peer_id
		rec.reward_mult = d.reward_mult
		_drinks.append(rec)
	var causer := server_peer_id if server_peer_id != 0 else drinker_peer_id
	for e in d.effects:
		if not rec.effect_ids.has(e.id):
			rec.effect_ids.append(e.id)
		apply(e.id, causer, drinker_peer_id)
	if d.neighbour_reward_mult != 1.0:
		var gift := LiveDrink.new()
		gift.drink = d
		gift.peer_id = _left_of(drinker_peer_id)
		gift.reward_mult = d.neighbour_reward_mult
		gift.gift = true
		_drinks.append(gift)
	_prune_drinks()
	_changed()
	return &""


func _refusal(d: Drink, peer_id: int) -> StringName:
	if d == null:
		return &"unknown_drink"
	if game_loop != null and game_loop.phase == GameLoop.Phase.ROUND_LIVE and not d.mid_round:
		return &"intermission_only"
	if d.night_limit > 0 and int(_night_uses.get("%d:%s" % [peer_id, d.id], 0)) >= d.night_limit:
		return &"night_limit"
	if _record_of(d.id, peer_id) == null and _drink_count(peer_id) >= MAX_LIVE_DRINKS:
		return &"drink_cap"  # a repeat of a live drink refreshes it, so it needs no slot
	return &""


func _drink_count(peer_id: int) -> int:
	var n := 0
	for r in _drinks:
		if r.peer_id == peer_id and not r.gift:
			n += 1
	return n


func _record_of(drink_id: StringName, peer_id: int) -> LiveDrink:
	for r in _drinks:
		if r.drink.id == drink_id and r.peer_id == peer_id and not r.gift:
			return r
	return null


## A drink whose Effects have all ended (ice_water, timers) stops counting for its slot and reward.
func _prune_drinks() -> void:
	for i in range(_drinks.size() - 1, -1, -1):
		var r := _drinks[i]
		if r.gift or r.effect_ids.is_empty():
			continue
		if not r.effect_ids.any(func(id: StringName) -> bool: return _find(id, r.peer_id) != null):
			_drinks.remove_at(i)


func _left_of(peer_id: int) -> int:
	var order: PackedInt32Array = seat_order_source.call()
	var i := order.find(peer_id)
	return peer_id if i < 0 else order[(i + 1) % order.size()]


func _net_seat_order() -> PackedInt32Array:
	var net := get_node_or_null(^"/root/NetManager")
	if net != null and net.has_method(&"seat_order"):
		return net.call(&"seat_order")
	return PackedInt32Array([multiplayer.get_unique_id()])


# --- table sink (host) -------------------------------------------------------------------------

func set_tilt_direction(dir: Vector2) -> void:
	_tilt_dir = dir
	if sim != null and _is_host():
		sim.call(&"set_tilt_direction", dir)


func current_shooter() -> int:
	var id: Variant = round_director.get(&"current_shooter_id") if round_director != null else null  # SYNC's rotation; null until it lands
	return int(id) if id != null else multiplayer.get_unique_id()


## Pushes the stats PhysicsSim owns, resolved for whoever is shooting, whenever they change.
func _refresh_table_stats() -> void:
	if sim == null or not _is_host():
		return
	var shooter := current_shooter()
	for stat in Stats.SIM_PUSHED:
		var v := get_stat(stat, shooter, Stats.BASE[stat])
		if not is_equal_approx(v, float(_pushed.get(stat, Stats.BASE[stat]))):
			_pushed[stat] = v
			sim.call(&"set_stat", stat, v)
	var rails := {}
	for le in _live:
		if le.is_rail_scoped():
			rails[le.target_id] = true
	for rail_id in _pushed_rails.keys():
		rails[rail_id] = true
	for rail_id: int in rails:
		var m := rail_restitution_mult(rail_id)
		if not is_equal_approx(m, float(_pushed_rails.get(rail_id, 1.0))):
			_pushed_rails[rail_id] = m
			sim.call(&"set_rail_restitution_mult", Stats.RAILS[rail_id - 1], m)


# --- visual hooks (03 §3.8): budget only, consumers pool the visuals ---------------------------

func _hook_start(tag: StringName) -> void:
	if _hooks.has(tag):
		return
	var full := Stats.FULLSCREEN_HOOKS.has(tag)
	var victim := &""
	for h in _hooks:  # oldest first
		if Stats.FULLSCREEN_HOOKS.has(h) == full:
			victim = h
			break
	if victim != &"" and (full or _hooks.size() >= MAX_HOOKS):
		_hook_stop(victim)
	elif _hooks.size() >= MAX_HOOKS:
		_hook_stop(_hooks[0])
	_hooks.append(tag)
	visual_hook_started.emit(tag)


func _hook_stop(tag: StringName) -> void:
	_hooks.erase(tag)
	visual_hook_stopped.emit(tag)


func live_hooks() -> Array[StringName]:
	return _hooks
