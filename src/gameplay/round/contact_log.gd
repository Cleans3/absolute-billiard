class_name ContactLog
extends RefCounted

## Ordered record of one Shot (01 §2): the only input to foul and trick detection. Entry =
## {tick: int, kind: BALL|RAIL|POCKET|OFF_TABLE, a: Ball, b: Ball|null, pocket_id: StringName,
## rail_id: StringName}. A BALL entry puts the cue ball in `a` when it is one of the pair.

const BALL := &"BALL"
const RAIL := &"RAIL"
const POCKET := &"POCKET"
const OFF_TABLE := &"OFF_TABLE"

var entries: Array[Dictionary] = []


func clear() -> void:
	entries.clear()


func add_ball(a: Ball, b: Ball) -> void:
	if a == b or _pair_logged_this_tick(a, b):
		return  # Jolt reports one contact from both bodies; keep a single entry
	if b.is_cue_ball:
		var t := a
		a = b
		b = t
	_add(BALL, a, b)


func add_rail(a: Ball, rail_id: StringName) -> void:
	_add(RAIL, a, null, &"", rail_id)


func add_pocket(a: Ball, pocket_id: StringName) -> void:
	_add(POCKET, a, null, pocket_id)


func add_off_table(a: Ball) -> void:
	_add(OFF_TABLE, a)


static func touches(entry: Dictionary, ball: Ball) -> bool:
	return entry.a == ball or entry.b == ball


func _add(kind: StringName, a: Ball, b: Ball = null, pocket_id := &"", rail_id := &"") -> void:
	entries.append({tick = Engine.get_physics_frames(), kind = kind, a = a, b = b, pocket_id = pocket_id, rail_id = rail_id})


func _pair_logged_this_tick(a: Ball, b: Ball) -> bool:
	var tick := Engine.get_physics_frames()
	for i in range(entries.size() - 1, -1, -1):
		var e := entries[i]
		if e.tick != tick:
			return false
		if e.kind == BALL and touches(e, a) and touches(e, b):
			return true
	return false
