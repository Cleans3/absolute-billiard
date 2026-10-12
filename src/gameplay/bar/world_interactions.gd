class_name WorldInteractions
extends Node
## Host-validated free-roam interactions and the griefing guard (docs/plan/03 §3.4, contract §6).
## Order: toggle → live Round → prop + reach → per-interactor cooldown → per-Turn hostile cap → cost (spent
## last, so a rejection never costs anything) → Effect + payoffs → broadcast.

enum HostilePolicy { ON, FRIENDS_ONLY, OFF }

signal interaction_applied(peer_id: int, kind: StringName, target_id: int, payload: Dictionary)
signal interaction_rejected(kind: StringName, reason: StringName)
## bar_buy / bar_serve: validated, nothing charged. The Shop (ECON) owns purchasing and calls serve_drink.
## go_live: the pedestal between Rounds; validated, then GameLoop.toggle_ready (02 §3.1).
signal bar_purchase_requested(kind: StringName, buyer_peer_id: int, drink_id: StringName, target_peer_id: int)
signal camera_move_requested(peer_id: int, target_id: int, payload: Dictionary)  # Cameras (M5) consume

const MAX_HOSTILE_PER_TURN := 2
const REACH_M := 2.0  # [tune]

@export var effects: EffectManager
@export var stream: StreamManager
@export var economy: EconomyManager
@export var game_loop: GameLoop
@export var round_director: Node  # RoundDirector
@export var table: Node3D  # bump direction points at its centre

var hostile_policy := HostilePolicy.ON  # host toggle `hostile_world_interactions`
var friends := PackedInt32Array()  # peers allowed hostile actions under FRIENDS_ONLY (host always is)
## peer_id -> Vector3 (INF when unknown); PlayerSpawner.get_player_position once NET lands.
var player_position_source: Callable = _spawner_position
var clock: Callable = Time.get_ticks_msec

## Seconds the last rejection says to wait (> 0 only for `cooldown`); it rides world_interaction_rejected, the signal keeps its shape.
var last_wait_sec := 0.0
var _cooldown_until := {}  # "peer:kind" -> msec
var _hostile_this_turn := 0
var _round_used := {}  # once_per_round kinds
var _pending: Array[PoolDelta] = []  # payoffs waiting on the Shot's outcome
var slot_house := SlotHouse.new()  # slot_spin's host rules (docs/plan/02 §3.8)


func _ready() -> void:
	add_to_group(&"world_interactions")
	slot_house.world = self
	add_child(slot_house)
	if round_director != null:
		round_director.connect(&"shot_ended", _on_shot_ended)
	if game_loop != null:
		game_loop.round_ended.connect(func(_r: StringName, _p: int) -> void:
			_round_used.clear()
			_pending.clear()
			_hostile_this_turn = 0)


func _is_host() -> bool:
	return multiplayer.is_server()


## Entry for the local player (Interactable.try_use): the host validates directly, a client asks.
func request(kind: StringName, target_id: int, payload := {}) -> void:
	if _is_host():
		_handle(multiplayer.get_unique_id(), kind, target_id, payload)
	else:
		request_world_interaction.rpc_id(1, kind, target_id, payload)


@rpc("any_peer", "call_remote", "reliable", 3)
func request_world_interaction(kind: StringName, target_id: int, payload: Dictionary) -> void:
	if _is_host():
		_handle(multiplayer.get_remote_sender_id(), kind, target_id, payload)


@rpc("authority", "call_local", "reliable", 3)
func world_interaction_applied(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> void:
	interaction_applied.emit(peer_id, kind, target_id, payload)


@rpc("authority", "call_remote", "reliable", 3)
func world_interaction_rejected(kind: StringName, reason: StringName, wait_sec: float) -> void:
	last_wait_sec = wait_sec
	interaction_rejected.emit(kind, reason)


func _reject(peer_id: int, kind: StringName, reason: StringName) -> void:
	var wait := cooldown_left_sec(peer_id, kind) if reason == &"cooldown" else 0.0
	if peer_id == multiplayer.get_unique_id():
		last_wait_sec = wait
		interaction_rejected.emit(kind, reason)
	else:
		world_interaction_rejected.rpc_id(peer_id, kind, reason, wait)


## Host: how long `peer_id` still waits before `kind` works for them again.
func cooldown_left_sec(peer_id: int, kind: StringName) -> float:
	return maxf(float(int(_cooldown_until.get("%d:%s" % [peer_id, kind], 0)) - int(clock.call())) / 1000.0, 0.0)


func _handle(peer_id: int, kind: StringName, target_id: int, payload: Dictionary) -> void:
	var w := FxCatalog.interaction(kind)
	var reason := _validate(peer_id, kind, w, target_id, payload)
	if reason != &"":
		_reject(peer_id, kind, reason)
		return
	if w == null:
		_apply_bar(peer_id, kind, payload)
	else:
		_apply(peer_id, w, target_id, payload)
	world_interaction_applied.rpc(peer_id, kind, target_id, payload)


func _validate(peer_id: int, kind: StringName, w: WorldInteraction, target_id: int, payload: Dictionary) -> StringName:
	if w == null:
		if kind == &"go_live":
			if game_loop == null or game_loop.phase != GameLoop.Phase.INTERMISSION:
				return &"not_intermission"
			return _reach(peer_id, kind, target_id)
		if kind == &"answer_phone":  # 09 §3.2: ringing, and not yet answered this Night, is StoryDirector's to say
			if game_loop == null or game_loop.phase != GameLoop.Phase.INTERMISSION:
				return &"not_ringing"
			var near := _reach(peer_id, kind, target_id)
			if near != &"":
				return near
			var story := get_tree().get_first_node_in_group(&"story_director")
			return story.call(&"answer_block") if story != null else &"not_ringing"
		if kind == SlotHouse.PROP_KIND:  # reach, then the machine's own rules, then the stake: a refusal never costs
			var close := _reach(peer_id, kind, target_id)
			if close != &"":
				return close
			var why := slot_house.validate(peer_id, payload)
			return why if why != &"" else slot_house.charge(payload)
		if kind != &"bar_buy" and kind != &"bar_serve":
			return &"unknown_kind"
		var drink := FxCatalog.drink(payload.get(&"drink_id", &""))
		if drink == null:
			return &"bad_payload"
		if _live() and not drink.mid_round:
			return &"intermission_only"
		return _reach(peer_id, kind, target_id)
	if w.hostile:
		if hostile_policy == HostilePolicy.OFF:
			return &"hostile_off"
		if hostile_policy == HostilePolicy.FRIENDS_ONLY and peer_id != 1 and not friends.has(peer_id):
			return &"hostile_friends_only"
		if peer_id == effects.current_shooter():
			return &"shooter_cant_grief"
	if w.requires_live_shot and not _live():
		return &"not_live"
	if w.once_per_round and _round_used.has(kind):
		return &"once_per_round"
	var near := _reach(peer_id, kind, target_id)
	if near != &"":
		return near
	if int(_cooldown_until.get("%d:%s" % [peer_id, kind], 0)) > int(clock.call()):
		return &"cooldown"
	if w.hostile and _hostile_this_turn >= MAX_HOSTILE_PER_TURN:
		return &"hostile_cap"
	return _spend(peer_id, w, payload)


func _live() -> bool:
	return game_loop != null and game_loop.phase == GameLoop.Phase.ROUND_LIVE


func _prop_for(kind: StringName, target_id: int) -> Interactable:
	for n in get_tree().get_nodes_in_group(&"interactable"):
		var p := n as Interactable
		if p != null and p.effective_kind() == kind and p.target_id == target_id:
			return p
	return null


func _reach(peer_id: int, kind: StringName, target_id: int) -> StringName:
	var prop := _prop_for(kind, target_id)
	if prop == null:
		return &"no_prop"
	var pos: Vector3 = player_position_source.call(peer_id)
	if not pos.is_finite():
		return &"no_position"
	return &"" if pos.distance_to(prop.global_position) <= REACH_M else &"too_far"


func _spawner_position(peer_id: int) -> Vector3:
	var spawner := get_node_or_null(^"../PlayerSpawner")
	if spawner == null:
		return Vector3.INF
	return spawner.call(&"get_player_position", peer_id)


## Cost is the last gate: HYPE/VIEWERS are checked then taken here, CASH is one atomic try_spend_cash.
func _spend(peer_id: int, w: WorldInteraction, payload: Dictionary) -> StringName:
	var cost := w.cost
	if w.id == &"throw_drink":  # it buys the thrown drink off the shelf
		var drink := FxCatalog.drink(payload.get(&"drink_id", &""))
		if drink == null:
			return &"bad_payload"
		return economy.try_throw(drink.id)  # takes a unit off the Bartender's shelf and pays its price
	if cost == null:
		return &""
	match cost.kind:
		PoolDelta.Kind.HYPE:
			if stream.hype < cost.amount:
				return &"cant_afford"
			stream.add_hype(-cost.amount)
		PoolDelta.Kind.VIEWERS:
			if stream.viewers < int(cost.amount):
				return &"cant_afford"
			stream.add_viewers(-int(cost.amount))
		PoolDelta.Kind.CASH:
			if not economy.try_spend_cash(int(cost.amount), w.id):
				return &"cant_afford"
	return &""


func _apply(peer_id: int, w: WorldInteraction, target_id: int, payload: Dictionary) -> void:
	if w.hostile:
		_hostile_this_turn += 1
	_cooldown_until["%d:%s" % [peer_id, w.id]] = int(clock.call()) + int(w.cooldown_sec * 1000.0)
	if w.once_per_round:
		_round_used[w.id] = true
	if w.effect != null:
		var subject := 0
		match w.effect.target:
			Effect.Target.TABLE:
				subject = target_id
				if w.effect.stat_modifiers.any(func(m: StatMod) -> bool: return m.stat == &"table_tilt_deg"):
					_tilt_away_from(peer_id)
			Effect.Target.PLAYER, Effect.Target.CUE, Effect.Target.VIEW:
				subject = effects.current_shooter()
		effects.apply(w.effect.id, peer_id, subject)
	if w.id == &"throw_drink":
		_soak_shooter(peer_id)
	for p in w.payoffs:
		if p.condition == &"always":
			_pay(p)
		else:
			_pending.append(p)
	if w.id == &"move_camera":
		camera_move_requested.emit(peer_id, target_id, payload)


## A thrown drink hits the shooter: knocked away from the thrower (06 P15). Nobody soaks themselves.
func _soak_shooter(thrower: int) -> void:
	var spawner := get_tree().get_first_node_in_group(&"player_spawner")  # by group, see RoundDirector._detonate
	var shooter := effects.current_shooter()
	if spawner != null and shooter != thrower:
		spawner.call(&"knock_away", shooter, player_position_source.call(thrower))


func _apply_bar(peer_id: int, kind: StringName, payload: Dictionary) -> void:
	if kind == &"go_live":
		game_loop.toggle_ready(peer_id)
		return
	if kind == &"answer_phone":
		return  # nothing to apply on the host: every peer's StoryDirector reacts to the broadcast
	if kind == SlotHouse.PROP_KIND:
		slot_house.spin(peer_id, payload)  # fills `payload` with the result: the broadcast carries it to every peer
		return
	var target := int(payload.get(&"target_peer", peer_id)) if kind == &"bar_serve" else peer_id
	bar_purchase_requested.emit(kind, peer_id, payload[&"drink_id"], target)


## The tilt pushes the balls the way the interactor shoved: from them toward the table's centre.
func _tilt_away_from(peer_id: int) -> void:
	var pos: Vector3 = player_position_source.call(peer_id)
	if table == null or not pos.is_finite():
		return
	var d := table.global_position - pos
	effects.set_tilt_direction(Vector2(d.x, d.z).normalized())


func _pay(p: PoolDelta) -> void:
	match p.kind:
		PoolDelta.Kind.HYPE:
			stream.add_hype(p.amount)
		PoolDelta.Kind.VIEWERS:
			stream.add_viewers(int(p.amount))
		PoolDelta.Kind.CASH:
			economy.add_cash(int(p.amount), &"world")


## A Turn ends with its Shot: payoffs settle on the outcome, the hostile budget refills.
func _on_shot_ended(_shot_id: String, _shooter_id: int, raw_points: int, _tricks: Array[StringName], foul: bool) -> void:
	var potted := raw_points > 0 and not foul
	for p in _pending:
		if (p.condition == &"shot_potted") == potted:
			_pay(p)
	_pending.clear()
	_hostile_this_turn = 0
