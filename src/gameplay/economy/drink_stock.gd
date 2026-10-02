class_name DrinkStock
extends RefCounted
## The Bartender's random shelf (docs/plan/02 §3.6, 06 P17): `SIZE` distinct drinks, each offer's tier drawn by
## DrinkTier weight, then a drink of that tier. Pure function of the key, so a resume or a second signal gives the same shelf.

const SIZE := 5


## Drink ids for `key` (GameLoop.stock_key: campaign seed + Night + Round). No drink twice in one stock.
static func roll(key: int) -> Array[StringName]:
	var rng := RandomNumberGenerator.new()
	rng.seed = key
	var pools: Array = []  # per tier: the drinks still unpicked
	for t in DrinkTier.NAMES.size():
		pools.append(FxCatalog.drinks_of(t))
	var out: Array[StringName] = []
	while out.size() < SIZE:
		var open: Array[DrinkTier.Tier] = []
		for t in pools.size():
			if not pools[t].is_empty():
				open.append(t)
		if open.is_empty():
			break  # fewer drinks than SIZE: ship what exists
		var tier := DrinkTier.draw(rng, open)
		var pool: Array = pools[tier]
		out.append((pool.pop_at(rng.randi() % pool.size()) as Drink).id)
	return out
