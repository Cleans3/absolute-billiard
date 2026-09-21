class_name TrickDetector
extends RefCounted

## The five tricks of 01 §3 as counters over one Shot's ContactLog. Everything that fired is
## returned, highest multiplier first (payout uses [0] only); Combo3 replaces Combo at 3+ pots.

const COMBO3_MIN_POTS := 3
const RAIL_RUNNER_MIN_RAILS := 3


static func detect(log: ContactLog, cue: Ball, shot_id: String) -> Array[TrickShot]:
	var e := log.entries
	var potted: Array[Dictionary] = []  # {ball, index} of each object ball's POCKET entry
	var first_pocket := e.size()
	var first_object_hit := e.size()
	for i in e.size():
		var entry := e[i]
		if entry.kind == ContactLog.POCKET:
			first_pocket = mini(first_pocket, i)
			if entry.a != cue:
				potted.append({ball = entry.a, index = i})
		elif entry.kind == ContactLog.BALL and entry.a == cue:
			first_object_hit = mini(first_object_hit, i)

	var ids: Array[StringName] = []
	if potted.size() >= COMBO3_MIN_POTS:
		ids.append(&"Combo3")
	elif potted.size() >= 2:
		ids.append(&"Combo")
	if _cue_rail_before(e, cue, first_object_hit):
		ids.append(&"KickShot")
	if _distinct_cue_hits(e, cue, first_pocket) >= 2:
		ids.append(&"Carom")
	for p in potted:
		if _bank(e, p.ball, p.index) and not ids.has(&"BankShot"):
			ids.append(&"BankShot")
		if _rails_before(e, p.ball, p.index) >= RAIL_RUNNER_MIN_RAILS and not ids.has(&"RailRunner"):
			ids.append(&"RailRunner")

	var out: Array[TrickShot] = []
	for id in TrickShot.sort_desc(ids):
		var t := TrickShot.new()
		t.id = id
		t.multiplier = TrickShot.multiplier_for(id)
		t.shot_id = shot_id
		out.append(t)
	return out


static func _cue_rail_before(e: Array[Dictionary], cue: Ball, limit: int) -> bool:
	for i in mini(limit, e.size()):
		if e[i].kind == ContactLog.RAIL and e[i].a == cue:
			return true
	return false


static func _distinct_cue_hits(e: Array[Dictionary], cue: Ball, limit: int) -> int:
	var seen: Array[Ball] = []
	for i in mini(limit, e.size()):
		if e[i].kind == ContactLog.BALL and e[i].a == cue and not seen.has(e[i].b):
			seen.append(e[i].b)
	return seen.size()


## A RAIL touch by `ball` between its first BALL contact and `pocket_index`.
static func _bank(e: Array[Dictionary], ball: Ball, pocket_index: int) -> bool:
	var hit := false
	for i in pocket_index:
		if e[i].kind == ContactLog.BALL and ContactLog.touches(e[i], ball):
			hit = true
		elif hit and e[i].kind == ContactLog.RAIL and e[i].a == ball:
			return true
	return false


## Cushion bounces by `ball` before `pocket_index`; a run of touches on one rail segment (jaw
## rattle) is a single bounce unless another contact intervenes.
static func _rails_before(e: Array[Dictionary], ball: Ball, pocket_index: int) -> int:
	var n := 0
	var last := &""
	for i in pocket_index:
		if not ContactLog.touches(e[i], ball):
			continue
		if e[i].kind == ContactLog.RAIL:
			if e[i].rail_id != last:
				n += 1
			last = e[i].rail_id
		else:
			last = &""
	return n
