class_name EconomyManager
extends Node
## Cash ledger, the Night reckoning and the Bartender's Shop (docs/plan/02 §3.2, §3.4, §3.6).
## Host writes every number; clients mirror absolute values (04 §5) and never run the rules.

signal cash_changed(new_balance: int, delta: int, reason: StringName)  # reason: shot | tip | quota | shop | ...
signal quota_evaluated(paid: int, demand: int, is_game_over: bool)
signal item_purchased(item_id: StringName, buyer_peer_id: int)
signal purchase_rejected(item_id: StringName, reason: StringName)  # on the requesting peer only
signal owned_changed()  # owned items changed (buy, resume, wipe): the Shop and Cameras re-read
signal cue_spec_changed(spec: CueSpec)

const POINT_TO_CASH_RATE := 0.3
const BUYOUT_MULT := 1.5  # final Night's demand replaces its quota (02 §3.4)
const BASE_RIGS := 2
const MAX_RIGS := 4

@export var stream: StreamManager
@export var game_loop: GameLoop  # optional: the economy probe runs without one
@export var world: WorldInteractions  # optional: bar_buy / bar_serve arrive here

var cash := 0
var owned: Dictionary = {}  # item id -> count
var last_refusal := &""

var _night_bought: Dictionary = {}  # one_per_night ids bought this Night
var _persistent: Array[StringName] = []


func _ready() -> void:
	if world != null:
		world.bar_purchase_requested.connect(_on_bar_purchase)
	if game_loop != null:
		game_loop.night_started.connect(func(_n: int, _q: int) -> void: _night_bought.clear())
		game_loop.round_started.connect(_on_round_started)


## Shot_Cash = Raw_Points × Trick_Mult × Camera_Mult × Event_Mult × Viewer_Scalar × Rate, integer Cash.
## Caller passes 0 / [] on a foul. Must run before StreamManager.on_shot_ended (Viewer_Scalar is pre-shot).
func award_shot_reward(raw_points: int, trick_ids: Array[StringName], pocket_id: StringName) -> int:
	var trick_mult := TrickShot.multiplier_for(trick_ids[0]) if not trick_ids.is_empty() else 1.0
	var cameras := get_node_or_null(^"../Cameras")  # duck-typed: the economy probe runs without one
	var camera_mult: float = cameras.camera_mult(pocket_id) if cameras != null else 1.0
	var fx := get_node_or_null(^"../EffectManager")
	var event_mult: float = fx.get_reward_multiplier() * fx.pot_bonus() if fx != null else 1.0
	var scalar := stream.viewer_scalar() if stream != null else 1.0
	var reward := roundi(raw_points * trick_mult * camera_mult * event_mult * scalar * POINT_TO_CASH_RATE)
	add_cash(reward, &"shot")
	return reward


## False (nothing spent) when Cash does not cover it. WorldInteractions costs go through here (03 §3.4).
func try_spend_cash(amount: int, reason: StringName) -> bool:
	if amount > cash:
		return false
	add_cash(-amount, reason)
	return true


## Host: the only writer of `cash`. Clients get the absolute balance through update_cash.
func add_cash(amount: int, reason: StringName) -> void:
	if amount == 0:
		return
	cash += amount
	cash_changed.emit(cash, amount, reason)
	if is_inside_tree() and multiplayer.is_server():
		update_cash.rpc(cash, amount, reason)


@rpc("authority", "call_local", "reliable", 3)
func update_cash(absolute_balance: int, delta: int, reason: StringName) -> void:
	if multiplayer.is_server():
		return  # add_cash already applied it here
	cash = absolute_balance
	cash_changed.emit(cash, delta, reason)


func demand_for(config: NightConfig, is_final := false) -> int:
	return roundi(config.quota * BUYOUT_MULT) if is_final else config.quota


## Pays the demand out of Cash when covered (overpay stays in Cash, so it banks); a miss ends the run.
func evaluate_quota(config: NightConfig, is_final := false) -> bool:
	var demand := demand_for(config, is_final)
	var passed := cash >= demand
	if passed:
		add_cash(-demand, &"quota")
	quota_evaluated.emit(demand if passed else 0, demand, not passed)
	if is_inside_tree() and multiplayer.is_server():
		quota_result.rpc(demand if passed else 0, demand, not passed)
	return passed


@rpc("authority", "call_remote", "reliable", 3)
func quota_result(paid: int, demand: int, is_game_over: bool) -> void:
	quota_evaluated.emit(paid, demand, is_game_over)


# --- Shop (02 §3.6) ---------------------------------------------------------------------------

## &"" when `buyer` may buy `item_id` right now, else why not. Clients call it on mirrored state to grey rows out.
func can_buy(item_id: StringName) -> StringName:
	var it := ShopCatalog.item(item_id)
	if it == null:
		return &"unknown_item"
	if game_loop != null:
		var live := game_loop.phase == GameLoop.Phase.ROUND_LIVE
		if not (game_loop.phase == GameLoop.Phase.INTERMISSION or (live and it.category == &"drink")):
			return &"closed"
		if not game_loop.nights.is_empty() and it.min_night > game_loop.current_night().night_number:
			return &"locked"
	if it.max_owned > 0 and count_of(item_id) >= it.max_owned:
		return &"owned"
	if it.one_per_night and _night_bought.has(item_id):
		return &"once_per_night"
	if it.cost_cash > cash:
		return &"cant_afford"
	return &""


func count_of(item_id: StringName) -> int:
	return int(owned.get(item_id, 0))


## Host-authoritative and the only path Cash leaves the account for the Shop. `target_peer_id` is who drinks
## (0 = the buyer). Drinks are served first, so a refusal (night limit, drink cap) costs nothing.
func try_purchase(item_id: StringName, buyer_peer_id: int, target_peer_id := 0) -> bool:
	assert(multiplayer.is_server(), "EconomyManager.try_purchase is host-only")
	last_refusal = can_buy(item_id)
	if last_refusal != &"":
		return false
	var it := ShopCatalog.item(item_id)
	if it.category == &"drink":
		var fx := get_node_or_null(^"../EffectManager")
		if fx == null:
			last_refusal = &"no_effects"
			return false
		var drinker := target_peer_id if target_peer_id != 0 else buyer_peer_id
		last_refusal = fx.serve_drink(item_id, drinker, buyer_peer_id)
		if last_refusal != &"":
			return false
	add_cash(-it.cost_cash, &"shop")
	if it.category != &"drink":
		owned[item_id] = count_of(item_id) + 1
		if it.persistent and not _persistent.has(item_id):
			_persistent.append(item_id)
			SaveManager.save_persistent(_persistent)
		_apply_upgrades()
	if it.one_per_night:
		_night_bought[item_id] = true
	_announce(item_id, buyer_peer_id)
	return true


## Any peer asks; the host decides. A refusal comes back to the asker only.
@rpc("any_peer", "call_local", "reliable", 3)
func request_purchase(item_id: StringName, target_peer_id := 0) -> void:
	if not multiplayer.is_server():
		return
	var buyer := multiplayer.get_remote_sender_id()
	if buyer == 0:
		buyer = multiplayer.get_unique_id()
	if not try_purchase(item_id, buyer, target_peer_id):
		reject_purchase.rpc_id(buyer, item_id, last_refusal)


## The bar prop's route (03 §3.7): WorldInteractions has already checked reach and cooldown.
func _on_bar_purchase(kind: StringName, buyer_peer_id: int, drink_id: StringName, target_peer_id: int) -> void:
	if multiplayer.is_server() and not try_purchase(drink_id, buyer_peer_id, target_peer_id if kind == &"bar_serve" else 0):
		reject_purchase.rpc_id(buyer_peer_id, drink_id, last_refusal)


@rpc("authority", "call_local", "reliable", 3)
func reject_purchase(item_id: StringName, reason: StringName) -> void:
	purchase_rejected.emit(item_id, reason)


func _announce(item_id: StringName, buyer_peer_id: int) -> void:
	item_purchased.emit(item_id, buyer_peer_id)
	owned_changed.emit()
	_push_owned(item_id, buyer_peer_id)


func _push_owned(item_id: StringName, buyer_peer_id: int) -> void:
	if is_inside_tree() and multiplayer.is_server():
		var ids := PackedStringArray()
		var counts := PackedInt32Array()
		for id: StringName in owned:
			ids.append(id)
			counts.append(owned[id])
		update_owned.rpc(ids, counts, item_id, buyer_peer_id)


@rpc("authority", "call_remote", "reliable", 3)
func update_owned(ids: PackedStringArray, counts: PackedInt32Array, item_id: StringName, buyer_peer_id: int) -> void:
	owned.clear()
	for i in ids.size():
		owned[StringName(ids[i])] = counts[i]
	_apply_upgrades()
	if item_id != &"":
		item_purchased.emit(item_id, buyer_peer_id)
	owned_changed.emit()


## New campaign: everything resets except the persistent unlocks (02 §3.7).
func wipe() -> void:
	cash = 0
	owned.clear()
	_night_bought.clear()
	_persistent = SaveManager.load_persistent()
	for id in _persistent:
		owned[id] = 1
	_apply_upgrades()
	owned_changed.emit()
	_push_owned(&"", 0)


## Resume from a checkpoint (host and, through update_owned, every client).
func restore(profile: SaveProfile) -> void:
	cash = profile.crew_cash
	owned.clear()
	for id: StringName in profile.owned_items:
		if ShopCatalog.item(id) != null:
			owned[id] = profile.owned_items[id]
	_persistent = profile.persistent_unlocks.duplicate()
	_night_bought.clear()
	_apply_upgrades()
	owned_changed.emit()
	if is_inside_tree() and multiplayer.is_server():
		cash_changed.emit(cash, 0, &"resume")
		update_cash.rpc(cash, 0, &"resume")
		_push_owned(&"", 0)


func persistent_unlocks() -> Array[StringName]:
	return _persistent


# --- folded upgrades ---------------------------------------------------------------------------

func _deltas() -> Array[ItemDelta]:
	var out: Array[ItemDelta] = []
	for id: StringName in owned:
		var it := ShopCatalog.item(id)
		if it != null and it.payload is ItemDelta:
			for i in int(owned[id]):
				out.append(it.payload)
	return out


func build_cue_spec() -> CueSpec:
	var spec := CueSpec.new()
	var power := 0.0
	var spin := 0.0
	for d in _deltas():
		power += d.cue_power_cap_add
		spin += d.cue_spin_radius_add
		spec.jump_unlocked = spec.jump_unlocked or d.cue_jump
		spec.masse_unlocked = spec.masse_unlocked or d.cue_masse
		spec.wobble_reduction += d.cue_wobble_reduction
	spec.power_cap_speed_mps *= 1.0 + power
	spec.spin_offset_radius *= 1.0 + spin
	return spec


## Replacement base values for bought tier upgrades; RULES applies them when it builds the rack.
func ball_overrides() -> Array[BallTypeOverride]:
	var out: Array[BallTypeOverride] = []
	for d in _deltas():
		for id: StringName in d.ball_values:
			out.append(BallTypeOverride.make(id, int(d.ball_values[id])))
	return out


## `base` (the Night's own pool) plus every bought type that exists as a BallType resource yet.
func unlocked_ball_types(base: Array[StringName]) -> Array[StringName]:
	var out := base.duplicate()
	for d in _deltas():
		for id in d.ball_types:
			if not out.has(id) and ResourceLoader.exists(RackDropper.TYPE_DIR + String(id) + ".tres"):
				out.append(id)
	return out


## The config the Round is dropped from: the Night's numbers with the Shop's drop pool.
func round_config(base: NightConfig) -> NightConfig:
	var cfg: NightConfig = base.duplicate()
	cfg.unlocked_ball_types = unlocked_ball_types(base.unlocked_ball_types)
	return cfg


func camera_tier() -> int:
	var tier := 1
	for d in _deltas():
		tier = maxi(tier, d.camera_tier)
	return tier


func rig_count() -> int:
	var n := BASE_RIGS
	for d in _deltas():
		n += d.extra_rigs
	return mini(n, MAX_RIGS)


func base_viewers_bonus() -> int:
	var n := 0
	for d in _deltas():
		n += d.base_viewers_add
	return n


func tip_rate_mult() -> float:
	var m := 1.0
	for d in _deltas():
		m *= d.tip_rate_mult
	return m


func _apply_upgrades() -> void:
	var spec := build_cue_spec()
	var sim := get_node_or_null(^"../Table/PhysicsSim")
	if sim != null and "active_cue" in sim:
		sim.set(&"active_cue", spec)
	cue_spec_changed.emit(spec)
	if stream != null:
		stream.apply_upgrades(base_viewers_bonus(), tip_rate_mult())


## Every peer, every Round: table mods are duration -1 Effects, so EffectManager expires them at Round end.
func _on_round_started(_round_index: int, _time_limit: float, _hazard_tier: int) -> void:
	var fx := get_node_or_null(^"../EffectManager")
	if fx == null:
		return
	for d in _deltas():
		for e in d.effects:
			fx.apply_local(e, 0, 0, -1)
