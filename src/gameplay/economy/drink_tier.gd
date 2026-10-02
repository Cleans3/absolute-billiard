class_name DrinkTier
extends RefCounted
## Bartender drink rarity (docs/plan/02 §3.6, 06 P17): draw weight, frame colour and units per offer.
## Colours are the polish contract's palette; MYSTERY is also the one that glitches (BartenderMenu).

enum Tier { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY, MYSTERY }

const NAMES: Array[String] = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mystery"]
const WEIGHTS: Array[float] = [50.0, 26.0, 13.0, 6.0, 2.0, 3.0]  # relative chance an offer is this tier (sum 100)
const STOCK: Array[int] = [3, 2, 1, 1, 1, 1]  # units of one offer the crew can buy before it sells out
const COLOURS: Array[Color] = [
	Color("B8BEC6"), Color("4CC46A"), Color("3D8BFF"), Color("A64DFF"), Color("FFB020"), Color("FF2A3C"),
]


static func colour(tier: Tier) -> Color:
	return COLOURS[tier]


static func label(tier: Tier) -> String:
	return NAMES[tier]


## Weighted pick among `allowed` tiers (a tier with no drink left to offer is excluded by the caller).
static func draw(rng: RandomNumberGenerator, allowed: Array[Tier]) -> Tier:
	var total := 0.0
	for t in allowed:
		total += WEIGHTS[t]
	var r := rng.randf() * total
	for t in allowed:
		r -= WEIGHTS[t]
		if r < 0.0:
			return t
	return allowed[allowed.size() - 1]
