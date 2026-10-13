class_name TableGeometry
extends RefCounted

## Pure derivation from a TableSpec to a TableLayout (01 §2, plan.md contract): no scene nodes,
## no physics, deterministic and headless-callable (tests/physics/geometry_probe.gd).

const DROP_CHUTE_RATIO := 40.0  # SafetyFloor depth, a multiple of ball radius (the net under everything)
const ARC_SEG_RADII := 1.0      # hole polygon edge length, in ball radii (the back wall's arc)
const LIP_SEG_RADII := 0.5      # ... the cloth lip's (inner arc), where a ball rolls over the edge: see `_hole`
const MIN_ARC_SEGS := 3
const SEAM_EPS := 1e-6
## THE pocket-position knob (06 P40): how far a pocket's centre sits outside the cloth's nose corner (corner pockets, on both
## axes) or nose line (side pockets), in ball radii. 0 = the hole is centred ON the cloth's corner / on the nose line, the
## user's reading ("centered from the corner table surface"); 1 was the old reading (one ball radius out, a hole mostly under
## the rail wood). The radii, the crossing points (`_hole`), the cup, sensor, wood cuts, liner, lid and keepouts all follow.
const POCKET_OUT_RADII := 0.0


## `pocket_mult` scales both mouth widths (03 `pocket_radius_mult`, e.g. the magnetic_pockets shop row). `osc_m` is
## the Moving Pockets amplitude: the bed is cut that much wider so a sliding cover (table_builder.gd) can move the
## opening inside the cut.
static func layout(spec: TableSpec, pocket_mult := 1.0, osc_m := 0.0) -> TableLayout:
	var out := TableLayout.new()
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var r := spec.ball_radius_m
	# mouths are tip-to-tip nose gaps: along an edge a corner's tip sits `c` from the nose corner, and the two tips
	# of one corner are c·√2 apart; a side pocket's tips are ±s from its axis
	var corner_mouth := spec.corner_mouth_m * pocket_mult
	var side_mouth := spec.side_mouth_m * pocket_mult
	var c := corner_mouth / sqrt(2.0)
	var s := side_mouth * 0.5
	var pocket_out := r * POCKET_OUT_RADII

	out.kitchen_line_x = spec.kitchen_line_x
	out.spots = {
		head = Vector3(spec.kitchen_line_x, 0.0, 0.0),
		foot = Vector3(spec.foot_spot_x, 0.0, 0.0),
		centre = Vector3.ZERO,
	}

	# [id, centre, tip-to-tip mouth, nominal hole radius = centre to a cushion tip]. A corner's tips are c from the nose corner
	# on each axis and its centre `pocket_out` outside it on both; a side's are s from the axis, its centre `pocket_out` outside
	# the nose line. With pocket_out = 0 the radius is just c (corner) / s (side).
	var corner_r := sqrt((c + pocket_out) * (c + pocket_out) + pocket_out * pocket_out)
	var side_r := sqrt(s * s + pocket_out * pocket_out)
	var pocket_defs := [
		[&"corner_nw", Vector3(-hl - pocket_out, 0.0, -hw - pocket_out), corner_mouth, corner_r],
		[&"corner_ne", Vector3(hl + pocket_out, 0.0, -hw - pocket_out), corner_mouth, corner_r],
		[&"corner_sw", Vector3(-hl - pocket_out, 0.0, hw + pocket_out), corner_mouth, corner_r],
		[&"corner_se", Vector3(hl + pocket_out, 0.0, hw + pocket_out), corner_mouth, corner_r],
		[&"side_n", Vector3(0.0, 0.0, -hw - pocket_out), side_mouth, side_r],
		[&"side_s", Vector3(0.0, 0.0, hw + pocket_out), side_mouth, side_r],
	]
	for p in pocket_defs:
		var id: StringName = p[0]
		var pos: Vector3 = p[1]
		var ps := PocketSpec.new()
		ps.id = id
		ps.position = pos
		ps.mouth_normal = Vector2(-signf(pos.x), -signf(pos.z))  # points inward, toward table centre
		ps.mouth_width_m = p[2]
		out.pockets.append(ps)
		var hole := _hole(spec, id, Vector2(pos.x, pos.z), float(p[3]), float(p[3]) + osc_m, pocket_out, hl, hw)
		out.holes[id] = hole

	# rail segments: [id, a, b, inward_normal, pocket at a, pocket at b]
	var rail_defs := [
		[&"rail_n_w", Vector3(-hl + c, 0.0, -hw), Vector3(-s, 0.0, -hw), Vector3(0, 0, 1), &"corner_nw", &"side_n"],
		[&"rail_n_e", Vector3(s, 0.0, -hw), Vector3(hl - c, 0.0, -hw), Vector3(0, 0, 1), &"side_n", &"corner_ne"],
		[&"rail_s_w", Vector3(-hl + c, 0.0, hw), Vector3(-s, 0.0, hw), Vector3(0, 0, -1), &"corner_sw", &"side_s"],
		[&"rail_s_e", Vector3(s, 0.0, hw), Vector3(hl - c, 0.0, hw), Vector3(0, 0, -1), &"side_s", &"corner_se"],
		[&"rail_w", Vector3(-hl, 0.0, -hw + c), Vector3(-hl, 0.0, hw - c), Vector3(1, 0, 0), &"corner_nw", &"corner_sw"],
		[&"rail_e", Vector3(hl, 0.0, -hw + c), Vector3(hl, 0.0, hw - c), Vector3(-1, 0, 0), &"corner_ne", &"corner_se"],
	]
	for rd in rail_defs:
		var seg := TableLayout.RailSegment.new()
		seg.id = rd[0]
		seg.a = rd[1]
		seg.b = rd[2]
		seg.inward_normal = rd[3]
		var half_a := deg_to_rad((180.0 - _facing_deg(rd[4])) * 0.5)
		var half_b := deg_to_rad((180.0 - _facing_deg(rd[5])) * 0.5)
		seg.facing_a = _facing_dir((seg.a - seg.b).normalized(), -seg.inward_normal, half_a)
		seg.facing_b = _facing_dir((seg.b - seg.a).normalized(), -seg.inward_normal, half_b)
		out.rails.append(seg)

	out.sights = _sights(hl, hw, c, s, spec.rail_width_m, spec.rail_height_m)
	_bed(out, hl, hw)
	return out


## The pocket's hole: a circle of `cup_radius` round `center`, cut into the nose rectangle where it overlaps it. The
## circle crosses the nose lines at two points (the cushion tips when cup_radius is the nominal radius); `inner` runs
## between them through the playfield, `outer` the other way round. `out` = how far `center` sits outside the nose line
## it crosses (0: on it, the circle then crosses at right angles, k = the radius).
static func _hole(spec: TableSpec, id: StringName, center: Vector2, radius: float, cup_radius: float, out: float, hl: float, hw: float) -> TableLayout.Hole:
	var r := spec.ball_radius_m
	var k := sqrt(cup_radius * cup_radius - out * out)  # half the chord the circle cuts on a nose line `out` away from its centre
	var sx := signf(center.x)
	var sz := signf(center.y)
	var p1: Vector2
	var p2: Vector2
	if sx == 0.0:  # side pocket: both crossings on the one nose line
		p1 = Vector2(-k, sz * hw)
		p2 = Vector2(k, sz * hw)
	else:  # corner: one crossing on each nose line
		p1 = Vector2(center.x - sx * k, sz * hw)
		p2 = Vector2(sx * hl, center.y - sz * k)
	var a1 := (p1 - center).angle()
	var sweep := wrapf((p2 - center).angle() - a1, -PI, PI)
	var mid := Vector2.from_angle(a1 + sweep * 0.5)
	if mid.dot(-center) < 0.0:  # the short way round faces away from the table: take the long one
		sweep -= signf(sweep) * TAU
	var hole := TableLayout.Hole.new()
	hole.pocket_id = id
	hole.center = center
	hole.radius = radius
	hole.cup_radius = cup_radius
	hole.inner = _arc(center, cup_radius, a1, sweep, p1, p2, r * LIP_SEG_RADII)
	hole.outer = _arc(center, cup_radius, a1 + sweep, signf(sweep) * (TAU - absf(sweep)), p2, p1, r * ARC_SEG_RADII)
	hole.ring = hole.inner.duplicate()
	for i in range(1, hole.outer.size() - 1):
		hole.ring.append(hole.outer[i])
	hole.apothem = INF
	for i in hole.ring.size():
		var seg_a := hole.ring[i]
		var seg_b := hole.ring[(i + 1) % hole.ring.size()]
		hole.apothem = minf(hole.apothem, center.distance_to(Geometry2D.get_closest_point_to_segment(center, seg_a, seg_b)))
	return hole


## Points on the circle from angle `a0` sweeping `sweep` radians, about `seg_len` apart, first and last pinned to `from`/`to` exactly.
static func _arc(center: Vector2, radius: float, a0: float, sweep: float, from: Vector2, to: Vector2, seg_len: float) -> PackedVector2Array:
	var n := maxi(MIN_ARC_SEGS, ceili(absf(sweep) * radius / seg_len))
	var out := PackedVector2Array()
	for i in n + 1:
		out.append(center + Vector2.from_angle(a0 + sweep * float(i) / float(n)) * radius)
	out[0] = from
	out[n] = to
	return out


## Distance along the nose rectangle's perimeter, starting at the west edge's midpoint and going north then east:
## orders the pocket arcs round the outline without a wrap-around inside any of them.
static func _perimeter_t(p: Vector2, hl: float, hw: float) -> float:
	if absf(p.x + hl) < SEAM_EPS and p.y <= 0.0:
		return -p.y
	if absf(p.y + hw) < SEAM_EPS:
		return hw + p.x + hl
	if absf(p.x - hl) < SEAM_EPS:
		return hw + 2.0 * hl + p.y + hw
	if absf(p.y - hw) < SEAM_EPS:
		return hw + 2.0 * hl + 2.0 * hw + hl - p.x
	return hw + 2.0 * hl + 2.0 * hw + 2.0 * hl + hw - p.y


## Nose rectangle with every `inner` arc cut out of it: the outline plus its convex pieces.
static func _bed(out: TableLayout, hl: float, hw: float) -> void:
	var arcs: Array[PackedVector2Array] = []
	for hole: TableLayout.Hole in out.holes.values():
		var arc := hole.inner
		if _perimeter_t(arc[0], hl, hw) > _perimeter_t(arc[arc.size() - 1], hl, hw):
			arc = _reversed(arc)
		arcs.append(arc)
	arcs.sort_custom(func(a: PackedVector2Array, b: PackedVector2Array) -> bool: return _perimeter_t(a[0], hl, hw) < _perimeter_t(b[0], hl, hw))
	var outline := PackedVector2Array()
	for arc in arcs:
		outline.append_array(arc)
	if Geometry2D.is_polygon_clockwise(outline):
		outline = _reversed(outline)
	out.bed_outline = outline
	out.bed_pieces.clear()
	for piece in Geometry2D.decompose_polygon_in_convex(outline):
		out.bed_pieces.append(piece)


static func _reversed(a: PackedVector2Array) -> PackedVector2Array:
	var out := a.duplicate()
	out.reverse()
	return out


## Orthonormal basis for a rail-aligned box or mesh: local +X = outward (away from the table
## centre, i.e. `-inward_normal`), +Y = up, +Z = along the rail (sign arbitrary — every rail
## cross-section this basis is used for is symmetric along the rail's length).
static func rail_basis(rail: TableLayout.RailSegment) -> Basis:
	var x := -rail.inward_normal
	var y := Vector3.UP
	return Basis(x, y, x.cross(y))


static func _facing_deg(pocket_id: StringName) -> float:
	return TableSpec.REG_CORNER_FACING_DEG if String(pocket_id).begins_with("corner") else TableSpec.REG_SIDE_FACING_DEG


## Rotate `rail_inward` (the straight-rail direction pointing from the rail end toward the
## pocket) by `half_angle_rad` around Y, whichever sign turns it `away` (the rail's outward normal,
## away from the playfield, so the facing leans into the pocket) — the angled cushion-nose facing.
## Not toward the pocket centre: with the centre on the nose line (POCKET_OUT_RADII 0) that direction
## is the rail itself and the two signs tie.
static func _facing_dir(rail_inward: Vector3, away: Vector3, half_angle_rad: float) -> Vector3:
	var a := rail_inward.rotated(Vector3.UP, half_angle_rad)
	var b := rail_inward.rotated(Vector3.UP, -half_angle_rad)
	return a if a.dot(away) > b.dot(away) else b


## 18 sights: 3 per short rail, 3 per long-rail half, on the rail top at the nose line offset
## outward by half the rail width, at the standard 1/4-2/4-3/4 spacing along each segment.
static func _sights(hl: float, hw: float, c: float, s: float, rail_width: float, rail_height: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var off := rail_width * 0.5
	var long_halves := [[-hl + c, -s], [s, hl - c]]
	for seg in long_halves:
		for k in [0.25, 0.5, 0.75]:
			out.append(Vector3(lerpf(seg[0], seg[1], k), rail_height, -hw - off))
	for seg in long_halves:
		for k in [0.25, 0.5, 0.75]:
			out.append(Vector3(lerpf(seg[0], seg[1], k), rail_height, hw + off))
	for k in [0.25, 0.5, 0.75]:
		out.append(Vector3(-hl - off, rail_height, lerpf(-hw + c, hw - c, k)))
	for k in [0.25, 0.5, 0.75]:
		out.append(Vector3(hl + off, rail_height, lerpf(-hw + c, hw - c, k)))
	return out
