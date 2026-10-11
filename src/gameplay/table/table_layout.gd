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

## One pocket's hole in the bed (06 P30), table-local xz. A circle round the pocket centre whose rim passes through
## the two cushion tips at 1.0 x mouths; the bed is cut along `inner`, the part inside the nose rectangle.
class Hole:
	extends RefCounted
	var pocket_id: StringName
	var center: Vector2
	var radius: float      # the opening: what balls fall into
	var cup_radius: float  # radius + the Moving Pockets amplitude: the bed cut, the cup and the pot sensor
	var inner: PackedVector2Array  # cup circle's arc inside the nose rectangle, nose-line point to nose-line point
	var outer: PackedVector2Array  # the rest of the circle, same end points: the pocket's back wall stands on it
	var ring: PackedVector2Array   # inner + outer, one closed polygon
	var apothem: float             # centre to the nearest ring edge: a ball centre inside this is inside the hole

var pockets: Array[PocketSpec] = []
var rails: Array[RailSegment] = []
var spots: Dictionary = {}  # {head, foot, centre}: Vector3
var kitchen_line_x: float = 0.0
var sights: Array[Vector3] = []
var holes: Dictionary = {}  # pocket id -> Hole
## The playing surface: the nose rectangle minus every hole (one simple polygon), and the convex pieces it is built
## from. table_builder.gd builds the bed from the pieces, table_visuals.gd the cloth from the outline: one source.
var bed_outline := PackedVector2Array()
var bed_pieces: Array[PackedVector2Array] = []
