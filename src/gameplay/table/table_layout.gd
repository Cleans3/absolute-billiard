class_name TableLayout
extends RefCounted

## Pure geometry output of TableGeometry.layout(spec) — plain data, no nodes (01 §2, plan.md
## contract). Every position is table-local at cloth height (y = 0); Table adds bed_height_m
## when it builds bodies and visuals from this.

class RailSegment:
	extends RefCounted
	var id: StringName
	var a: Vector3
	var b: Vector3
	var inward_normal: Vector3
	var facing_a: Vector3  # angled cushion-nose direction at end `a`, into the pocket it meets
	var facing_b: Vector3  # angled cushion-nose direction at end `b`

var pockets: Array[PocketSpec] = []
var rails: Array[RailSegment] = []
var spots: Dictionary = {}  # {head, foot, centre}: Vector3
var kitchen_line_x: float = 0.0
var sights: Array[Vector3] = []
var drop_zones: Array[Dictionary] = []  # {pocket_id, position, size: Vector2}
