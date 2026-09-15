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
## One entry per strip actually built (T5.3): a corner pocket gets two (flush on x, flush on z),
## a side pocket one. {pocket_id, position: Vector3 (table-local, y=0 cloth), size: Vector3 (box
## dimensions — x width, y chute height, z depth)}. table_builder.gd builds exactly this, verbatim.
var drop_zones: Array[Dictionary] = []
