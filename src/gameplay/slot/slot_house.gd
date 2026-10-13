class_name SlotHouse
extends Node
## Host rules of the bar slot (docs/plan/02 §3.9). WorldInteractions owns the one instance and runs a `slot_spin` through
## validate → charge → spin; the payout and the chaos land when the last drum does, or at once when the phase changes,
## so a win is never lost or paid into the next Night. The result rides the interaction's payload to every peer.

signal revealed(peer_id: int, win: StringName, payout: int)  ## host: Cash paid and chaos fired

const HYPE_KICK := 0.3
const VIEWERS_KICK := 150
const ZAP_MPS := 3.5
const PROP_KIND := &"slot_spin"

var world: WorldInteractions
var rng := RandomNumberGenerator.new()

var _pending: Array[Dictionary] = []
var _busy_until_msec := 0


func _ready() -> void:
	rng.randomize()
	if world != null and world.game_loop != null:
		world.game_loop.phase_changed.connect(func(_p: int) -> void: flush())


## The reason a spin is refused, or &"" (reach is WorldInteractions' own gate). Nothing is charged here. On success `payload[&"bet"]`
## holds the stake the host will take (see `_stake`).
func validate(peer_id: int, payload: Dictionary) -> StringName:
	var loop := world.game_loop
	if loop == null or loop.nights.is_empty():
		return &"slot_closed"
	var why := _stake(payload, loop.current_night().quota)
	if why != &"":
		return why
	if not (loop.phase in [GameLoop.Phase.INTERMISSION, GameLoop.Phase.ROUND_LIVE]):
		return &"slot_closed"
	if loop.phase == GameLoop.Phase.ROUND_LIVE and world.effects.current_shooter() == peer_id and _shot_in_flight():
		return &"shooter_busy"
	if Time.get_ticks_msec() < _busy_until_msec:
		return &"busy"
	return &""


## The stake of a request, written to `payload[&"bet"]`; or why not. Two shapes: `{bet, cash}`, a custom stake (plain int, snapped down to the
## $5 step, inside [$10, SlotMath.bet_cap] of this Night; `cash` is the asker's view of their purse and must still be the host's number),
## or `{tier}`, a preset (SlotMath.bets). Anything else is `bad_payload`; a stake outside the range is `bad_bet`; a purse that moved is
## `stale_cash` (the asker re-reads it and pulls again).
func _stake(payload: Dictionary, quota: int) -> StringName:
	if payload.has(&"bet"):
		if typeof(payload[&"bet"]) != TYPE_INT or typeof(payload.get(&"cash")) != TYPE_INT:
			return &"bad_payload"
		var bet := SlotMath.snap_bet(payload[&"bet"], quota)
		if bet < 0:
			return &"bad_bet"
		if int(payload[&"cash"]) != world.economy.cash:
			return &"stale_cash"
		payload[&"bet"] = bet
		return &""
	var tier: Variant = payload.get(&"tier")
	if typeof(tier) != TYPE_INT or int(tier) < 0 or int(tier) >= SlotMath.BET_RATES.size():
		return &"bad_payload"
	payload[&"bet"] = SlotMath.bets(quota)[int(tier)]
	return &""


## Takes the stake, last gate: a refusal above never costs anything.
func charge(payload: Dictionary) -> StringName:
	return &"" if world.economy.try_spend_cash(int(payload[&"bet"]), &"slot") else &"cant_afford"


## Rolls the reels and queues the reveal. `payload` is rebuilt from scratch (a client's extra keys never reach the others)
## and then carries the whole result for the broadcast: tier (the preset equal to the stake, else -1), bet, stops, win, payout, chaos.
func spin(peer_id: int, payload: Dictionary) -> void:
	var bet := int(payload[&"bet"])  # validate() wrote it
	var tier := Array(SlotMath.bets(world.game_loop.current_night().quota)).find(bet)
	var stops := SlotMath.roll(rng)
	var win := SlotMath.evaluate(stops)
	var chaos: Array[Dictionary] = []
	for kind: StringName in SlotMath.WINS[win].chaos:
		var c := _plan(kind, peer_id)
		if not c.is_empty():
			chaos.append(c)
	payload.clear()
	payload[&"tier"] = tier
	payload[&"bet"] = bet
	payload[&"stops"] = stops
	payload[&"win"] = win
	payload[&"payout"] = SlotMath.payout(win, bet)
	payload[&"chaos"] = chaos
	_busy_until_msec = Time.get_ticks_msec() + int(SlotMath.spin_sec(stops) * 1000.0)
	var entry := {peer = peer_id, win = win, payout = int(payload[&"payout"]), chaos = chaos}
	_pending.append(entry)
	get_tree().create_timer(SlotMath.reveal_sec(stops)).timeout.connect(_reveal.bind(entry))


## Reveal everything still pending now; the machine is free again.
func flush() -> void:
	for entry in _pending.duplicate():
		_reveal(entry)
	_busy_until_msec = 0


func is_busy() -> bool:
	return Time.get_ticks_msec() < _busy_until_msec


func _reveal(entry: Dictionary) -> void:
	if not _pending.has(entry):
		return
	_pending.erase(entry)
	if int(entry.payout) > 0:
		world.economy.add_cash(int(entry.payout), &"slot")
	for c: Dictionary in entry.chaos:
		_fire(int(entry.peer), c)
	revealed.emit(int(entry.peer), entry.win, int(entry.payout))


# --- chaos: decided at the spin (so the payload can name it), fired at the reveal -----------------------------------

func _plan(kind: StringName, peer_id: int) -> Dictionary:
	match kind:
		&"drink", &"mystery":
			var id := _pick_drink(peer_id, kind == &"mystery")
			return {kind = kind, id = id} if id != &"" else {}
		&"crew_round":
			var id := _pick_drink(peer_id, false)
			return {kind = kind, id = id} if id != &"" else {}
		&"event":
			var id := _pick_event()
			return {kind = kind, id = id} if id != &"" else {}
	return {kind = kind}  # hype, zap


func _fire(peer_id: int, c: Dictionary) -> void:
	match c.kind:
		&"drink", &"mystery":
			world.effects.serve_drink(c.id, peer_id, peer_id)
		&"crew_round":
			for crew_peer in world.effects.seat_order_source.call():
				world.effects.serve_drink(c.id, crew_peer, peer_id)
		&"hype":
			if world.stream != null:
				world.stream.add_hype(HYPE_KICK)
				world.stream.add_viewers(VIEWERS_KICK)
		&"event":
			var scheduler := world.get_node_or_null(^"../EventScheduler") as EventScheduler
			if scheduler != null:
				scheduler.trigger_now(c.id, world.game_loop.round_index)
		&"zap":
			var spawner := world.get_tree().get_first_node_in_group(&"player_spawner")
			if spawner != null:
				spawner.call(&"knock_away", peer_id, _machine_position(), ZAP_MPS)


## A Drink this player can take right now: no Legendary (night-limited), only mid-Round ones while a Round is live, a free
## slot or one they already hold (which refreshes), Mystery only when asked for.
func _pick_drink(peer_id: int, mystery: bool) -> StringName:
	var live := world.game_loop.phase == GameLoop.Phase.ROUND_LIVE
	var held := 0
	var own: Array[StringName] = []
	for r in world.effects.live_drinks():
		if r.peer_id == peer_id and not r.gift:
			held += 1
			own.append(r.drink.id)
	var pool: Array[StringName] = []
	for d in FxCatalog.DRINKS:
		if d.night_limit > 0 or (live and not d.mid_round) or (d.tier == DrinkTier.Tier.MYSTERY) != mystery:
			continue
		if held >= EffectManager.MAX_LIVE_DRINKS and not own.has(d.id):
			continue
		pool.append(d.id)
	return pool[rng.randi() % pool.size()] if not pool.is_empty() else &""


## A hazard Event for the live Round (never one already on the table); none between Rounds, where it would outlast its Round.
func _pick_event() -> StringName:
	var loop := world.game_loop
	if loop.phase != GameLoop.Phase.ROUND_LIVE:
		return &""
	var running := world.effects.live_events()
	var pool: Array[StringName] = []
	for e in FxCatalog.EVENTS:
		if e.min_night <= loop.current_night().night_number and not running.has(e):
			pool.append(e.id)
	return pool[rng.randi() % pool.size()] if not pool.is_empty() else &""


## Where the machine stands (its Interactable); INF when the bar has none, which knock_away reads as "any direction".
func _machine_position() -> Vector3:
	for n in world.get_tree().get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == PROP_KIND:
			return (n as Interactable).global_position
	return Vector3.INF


func _shot_in_flight() -> bool:
	return world.round_director != null and bool(world.round_director.get(&"shot_in_progress"))
