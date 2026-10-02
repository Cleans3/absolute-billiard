class_name EconomyManager
extends Node
## Cash ledger, the Night reckoning and the Bartender (docs/plan/02 §3.2, §3.4, §3.6).
## Host writes every number; clients mirror absolute values (04 §5) and never run the rules.

signal cash_changed(new_balance: int, delta: int, reason: StringName)  # reason: shot | tip | quota | shop | scratch | ...
signal quota_evaluated(paid: int, demand: int, is_game_over: bool)
signal item_purchased(item_id: StringName, buyer_peer_id: int)
signal purchase_rejected(item_id: StringName, reason: StringName)  # on the requesting peer only
signal owned_changed()  # owned items changed (buy, resume, wipe): the Bartender's Upgrades and Cameras re-read
signal stock_changed()  # the Drinks shelf was rolled, sold from or restored
signal fined(reason: StringName, amount: int)  # P16 scratch fine, on every peer; reason is the Cash reason (&"scratch", off-table included)
signal cue_spec_changed(spec: CueSpec)

const POINT_TO_CASH_RATE := 0.3
const BUYOUT_MULT := 1.5  # final Night's demand replaces its quota (02 §3.4)
const BASE_RIGS := 2
const MAX_RIGS := 4
const FINE_RATE := 0.10  # scratch fine = this share of the Night's Quota (06 P16)
const FINE_STEP := 5
const FINE_MIN := 25
const FINE_REASONS: Array[StringName] = [&"scratch", &"off_table"]  # RoundDirector.cue_respawned reasons that cost Cash

@export var stream: StreamManager
@export var game_loop: GameLoop  # optional: the economy probe runs without one
@export var world: WorldInteractions  # optional: bar_buy / bar_serve arrive here

var cash := 0  # may go negative: a scratch fine is not capped by the purse (P16)
var owned: Dictionary = {}  # item id -> count
var last_refusal := &""
var stock_key := -1  # GameLoop.stock_key() of the Intermission the shelf was rolled for

var _night_bought: Dictionary = {}  # one_per_night ids bought this Night
var _persistent: Array[StringName] = []
var _stock_ids: Array[StringName] = []  # the Bartender's Drinks shelf, parallel arrays
var _stock_left: Array[int] = []


func _ready() -> void:
	if world != null:
		world.bar_purchase_requested.connect(_on_bar_purchase)
	if game_loop != null:
		game_loop.night_started.connect(func(_n: int, _q: int) -> void: _night_bought.clear())
		game_loop.round_started.connect(_on_round_started)
		game_loop.intermission_started.connect(_on_intermission)
		game_loop.cue_respawned.connect(_on_cue_respawned)


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
	if amount > maxi(cash, 0):  # in debt nothing positive is affordable, a free action still is
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
	if reason == &"scratch":
		fined.emit(reason, -delta)


## Scratch / off-table fine: FINE_RATE of the Night's Quota to the nearest FINE_STEP, never under FINE_MIN (06 P16).
static func fine_for(quota: int) -> int:
	return maxi(FINE_MIN, roundi(quota * FINE_RATE / FINE_STEP) * FINE_STEP)


## Host: a Shot that scratched or put the cue ball off the table. A whiff or clock foul never gets here (it is
## not a cue_respawned reason). Cash may end negative; evaluate_quota then fails it like any shortfall.
func _on_cue_respawned(reason: StringName) -> void:
	if not FINE_REASONS.has(reason) or not multiplayer.is_server() or game_loop.phase != GameLoop.Phase.ROUND_LIVE:
		return
	var fine := fine_for(game_loop.current_night().quota)
	add_cash(-fine, &"scratch")
	fined.emit(&"scratch", fine)


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


# --- Bartender (02 §3.6) ----------------------------------------------------------------------

## &"" when `buyer` may buy `item_id` right now, else why not. Clients call it on mirrored state to grey rows out.
## Drinks must be on the shelf with a unit left; mid-Round only `mid_round` Drinks; Upgrades only in Intermission.
func can_buy(item_id: StringName) -> StringName:
	var it := ShopCatalog.item(item_id)
	if it == null:
		return &"unknown_item"
	var live := game_loop != null and game_loop.phase == GameLoop.Phase.ROUND_LIVE
	if game_loop != null:
		if not (game_loop.phase == GameLoop.Phase.INTERMISSION or (live and it.category == &"drink")):
			return &"closed"
		if not game_loop.nights.is_empty() and it.min_night > game_loop.current_night().night_number:
			return &"locked"
	if it.category == &"drink":
		var why := stock_refusal(item_id)
		if why != &"":
			return why
		if live and not (it.payload as Drink).mid_round:
			return &"intermission_only"
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
		_take_stock(item_id)
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


# --- Drinks shelf (06 P17) ---------------------------------------------------------------------

func stock_size() -> int:
	return _stock_ids.size()


func stock_id(i: int) -> StringName:
	return _stock_ids[i]


func stock_left(i: int) -> int:
	return _stock_left[i]


## Host: the shelf for this Intermission. The same key keeps the shelf as it is (resume, a repeated signal), so
## a sold-out offer stays sold out.
func roll_stock(key: int) -> void:
	if key == stock_key and not _stock_ids.is_empty():
		_push_stock()
		return
	var ids := DrinkStock.roll(key)
	var left: Array[int] = []
	for id in ids:
		left.append(DrinkTier.STOCK[FxCatalog.drink(id).tier])
	set_stock(key, ids, left)


## Host: replace the shelf outright (roll, checkpoint restore, tests) and mirror it.
func set_stock(key: int, ids: Array[StringName], left: Array[int]) -> void:
	stock_key = key
	_stock_ids = ids.duplicate()
	_stock_left = left.duplicate()
	stock_changed.emit()
	_push_stock()


## The reason a Drink cannot come off the shelf: not_stocked | sold_out, else &"".
func stock_refusal(drink_id: StringName) -> StringName:
	var i := _stock_ids.find(drink_id)
	if i < 0:
		return &"not_stocked"
	return &"sold_out" if _stock_left[i] <= 0 else &""


func _take_stock(drink_id: StringName) -> void:
	_stock_left[_stock_ids.find(drink_id)] -= 1
	stock_changed.emit()
	_push_stock()


## Throwing a Drink buys it off the shelf like a sale, but nobody drinks it (03 §3.7). &"" on success, else the refusal.
func try_throw(drink_id: StringName) -> StringName:
	var it := ShopCatalog.item(drink_id)
	if it == null or it.category != &"drink":
		return &"unknown_item"
	var why := stock_refusal(drink_id)
	if why == &"" and it.cost_cash > cash:
		why = &"cant_afford"
	if why != &"":
		return why
	_take_stock(drink_id)
	add_cash(-it.cost_cash, &"throw_drink")
	return &""


func _on_intermission() -> void:
	if multiplayer.is_server():
		roll_stock(game_loop.stock_key())


func _push_stock() -> void:
	if is_inside_tree() and multiplayer.is_server():
		update_stock.rpc(PackedStringArray(_stock_ids), PackedInt32Array(_stock_left), stock_key)


@rpc("authority", "call_remote", "reliable", 3)
func update_stock(ids: PackedStringArray, left: PackedInt32Array, key: int) -> void:
	stock_key = key
	_stock_ids.clear()
	_stock_left.clear()
	for i in ids.size():
		_stock_ids.append(StringName(ids[i]))
		_stock_left.append(left[i])
	stock_changed.emit()


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


## Host: a client came back from the background (RoundDirector.send_full_state).
func resync_peer(peer_id: int) -> void:
	update_cash.rpc_id(peer_id, cash, 0, &"resume")
	update_stock.rpc_id(peer_id, PackedStringArray(_stock_ids), PackedInt32Array(_stock_left), stock_key)
	var ids := PackedStringArray()
	var counts := PackedInt32Array()
	for id: StringName in owned:
		ids.append(id)
		counts.append(owned[id])
	update_owned.rpc_id(peer_id, ids, counts, &"", 0)


## New campaign: everything resets except the persistent unlocks (02 §3.7).
func wipe() -> void:
	cash = 0
	owned.clear()
	_night_bought.clear()
	stock_key = -1  # the next Intermission rolls a fresh shelf
	_stock_ids.clear()
	_stock_left.clear()
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
	stock_key = profile.stock_key
	_stock_ids = profile.stock_ids.duplicate()
	_stock_left = profile.stock_left.duplicate()
	if _stock_ids.any(func(id: StringName) -> bool: return FxCatalog.drink(id) == null):
		stock_key = -1  # a save from before a catalog change: roll a fresh shelf at the Intermission
		_stock_ids.clear()
		_stock_left.clear()
	_apply_upgrades()
	owned_changed.emit()
	stock_changed.emit()
	if is_inside_tree() and multiplayer.is_server():
		cash_changed.emit(cash, 0, &"resume")
		update_cash.rpc(cash, 0, &"resume")
		_push_owned(&"", 0)
		_push_stock()


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
