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

## Effect-reaction tags (03) per trick id. Pure of the id, so a client rebuilds them from the wire id alone.
const TAGS := {
	&"Combo": [&"combo", &"pot"],
	&"Combo3": [&"combo", &"pot"],
	&"BankShot": [&"bank", &"rail"],
	&"KickShot": [&"kick", &"rail"],
	&"Carom": [&"carom", &"ball"],
	&"RailRunner": [&"rail"],
}

var id: StringName
var multiplier: float
var shot_id: String
var tags: Array[StringName] = []


## A TrickShot from its id: what the host detects and what a client rebuilds are the same object.
static func make(trick_id: StringName, p_shot_id: String) -> TrickShot:
	var t := TrickShot.new()
	t.id = trick_id
	t.multiplier = multiplier_for(trick_id)
	t.shot_id = p_shot_id
	t.tags.assign(TAGS.get(trick_id, []))
	return t


static func multiplier_for(trick_id: StringName) -> float:
	return MULTIPLIERS.get(trick_id, 1.0)


## Highest multiplier first, so consumers pay `ids[0]` only.
static func sort_desc(ids: Array[StringName]) -> Array[StringName]:
	var out := ids.duplicate()
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return multiplier_for(a) > multiplier_for(b))
	return out
