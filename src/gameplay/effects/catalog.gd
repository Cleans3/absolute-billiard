class_name FxCatalog
extends RefCounted
## Every Drink / Event / WorldInteraction .tres (docs/plan/03 §3.5–3.7) and the Effect registry built
## from them. Explicit preloads, not a DirAccess scan: exports remap resource paths.

const DRINKS: Array[Drink] = [  # grouped by DrinkTier, Common first
	preload("res://src/resources/drink/beer.tres"),
	preload("res://src/resources/drink/bar_nuts.tres"),
	preload("res://src/resources/drink/ice_water.tres"),
	preload("res://src/resources/drink/soda_pop.tres"),
	preload("res://src/resources/drink/pretzels.tres"),
	preload("res://src/resources/drink/pickle_juice.tres"),
	preload("res://src/resources/drink/whiskey_shot.tres"),
	preload("res://src/resources/drink/energy_drink.tres"),
	preload("res://src/resources/drink/neighbours_round.tres"),
	preload("res://src/resources/drink/pale_ale.tres"),
	preload("res://src/resources/drink/rum_and_cola.tres"),
	preload("res://src/resources/drink/tequila_line.tres"),
	preload("res://src/resources/drink/flaming_shot.tres"),
	preload("res://src/resources/drink/vodka_tonic.tres"),
	preload("res://src/resources/drink/green_fairy.tres"),
	preload("res://src/resources/drink/house_special.tres"),
	preload("res://src/resources/drink/tiki_torch.tres"),
	preload("res://src/resources/drink/blue_lagoon.tres"),
	preload("res://src/resources/drink/moonshine.tres"),
	preload("res://src/resources/drink/dragons_breath.tres"),
	preload("res://src/resources/drink/gold_flake_champagne.tres"),
	preload("res://src/resources/drink/static_shot.tres"),
	preload("res://src/resources/drink/back_alley_brew.tres"),
	preload("res://src/resources/drink/void_juice.tres"),
	preload("res://src/resources/drink/cursed_cola.tres"),
	preload("res://src/resources/drink/quantum_ale.tres"),
]
const EVENTS: Array[Event] = [
	preload("res://src/resources/event/tilted_table.tres"),
	preload("res://src/resources/event/glass_cushions.tres"),
	preload("res://src/resources/event/bouncer.tres"),
	preload("res://src/resources/event/crowd_roar.tres"),
	preload("res://src/resources/event/moving_pockets.tres"),
	preload("res://src/resources/event/ball_swap_chaos.tres"),
	preload("res://src/resources/event/lights_out.tres"),
	preload("res://src/resources/event/pocket_jackpot.tres"),
]
const INTERACTIONS: Array[WorldInteraction] = [
	preload("res://src/resources/world/bump_table.tres"),
	preload("res://src/resources/world/throw_drink.tres"),
	preload("res://src/resources/world/move_camera.tres"),
	preload("res://src/resources/world/kick_stool.tres"),
	preload("res://src/resources/world/jukebox.tres"),
	preload("res://src/resources/world/flick_lights.tres"),
	preload("res://src/resources/world/lean_on_rail.tres"),
	preload("res://src/resources/world/heckle.tres"),
	preload("res://src/resources/world/chalk_the_cue.tres"),
]

static var _effects: Dictionary = {}  # StringName -> Effect
static var _drinks: Dictionary = {}  # StringName -> Drink


static func effect(id: StringName) -> Effect:
	_build()
	return _effects.get(id)


static func drink(id: StringName) -> Drink:
	_build()
	return _drinks.get(id)


## A fresh array of one tier's Drinks, catalog order (the stock roll pops from it).
static func drinks_of(tier: int) -> Array[Drink]:
	var out: Array[Drink] = []
	for d in DRINKS:
		if d.tier == tier:
			out.append(d)
	return out


static func event(id: StringName) -> Event:
	for e in EVENTS:
		if e.id == id:
			return e
	return null


static func interaction(id: StringName) -> WorldInteraction:
	for w in INTERACTIONS:
		if w.id == id:
			return w
	return null


static func _build() -> void:
	if not _effects.is_empty():
		return
	for d in DRINKS:
		_add_drink(d)
	for e in EVENTS:
		for x in e.effects:
			_add_effect(x)
	for w in INTERACTIONS:
		if w.effect != null:
			_add_effect(w.effect)


static func _add_drink(d: Drink) -> void:
	assert(not _drinks.has(d.id), "duplicate Drink id '%s'" % d.id)
	_drinks[d.id] = d
	for x in d.effects:
		_add_effect(x)


static func _add_effect(x: Effect) -> void:
	assert(not _effects.has(x.id), "duplicate Effect id '%s'" % x.id)
	_effects[x.id] = x
