class_name StatMod
extends Resource
## The only way an Effect touches anything (docs/plan/03 §2.1).

enum Op { ADD, MUL }

@export var stat: StringName:
	set(v):
		assert(Stats.ALL.has(v), "StatMod: unknown stat '%s' (not in Stats.ALL)" % v)
		stat = v
@export var op: Op = Op.ADD
@export var value := 0.0
