class_name RackLayout
extends Resource
## One hand-authored Round rack (01 §3, 06 P-list: Night 1 and Night 5 are not a dice roll).
## `positions` are fractions of the playfield interior's half-extents (x along the length, y across),
## each in [-1, 1], so a layout survives any `TableSpec.scale`. `type_ids[i]` is the BallType at `positions[i]`.

@export var type_ids: Array[StringName] = []
@export var positions := PackedVector2Array()
