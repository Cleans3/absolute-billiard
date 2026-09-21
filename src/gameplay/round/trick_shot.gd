class_name TrickShot
extends RefCounted
## One detected trick (docs/plan/01 §3). Multipliers are disjoint: a Shot pays only the highest.

const MULTIPLIERS := {
	&"Combo": 1.15,
	&"Combo3": 1.30,
	&"BankShot": 1.20,
	&"KickShot": 1.25,
	&"Carom": 1.35,
	&"RailRunner": 1.60,
}

var id: StringName
var multiplier: float
var shot_id: String
var tags: Array[StringName] = []


static func multiplier_for(trick_id: StringName) -> float:
	return MULTIPLIERS.get(trick_id, 1.0)


## Highest multiplier first, so consumers pay `ids[0]` only.
static func sort_desc(ids: Array[StringName]) -> Array[StringName]:
	var out := ids.duplicate()
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return multiplier_for(a) > multiplier_for(b))
	return out
