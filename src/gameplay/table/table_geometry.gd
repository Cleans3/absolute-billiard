class_name TableGeometry
extends RefCounted

## Pure derivation from a TableSpec to a TableLayout (01 §2, plan.md contract): no scene nodes,
## no physics, deterministic and headless-callable (tests/physics/geometry_probe.gd).


static func layout(spec: TableSpec) -> TableLayout:
	var out := TableLayout.new()
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var r := spec.ball_radius_m
	# corner mouth is measured on the diagonal; along an edge from the nose corner it spans this
	# much before the extra radius below — the straight cushion keeps its full outward depth (2R)
	# right up to where it is truncated, so without the extra margin a dead-centre shot at the
	# pocket grazes the outward corner of the cushion box with exactly zero clearance
	var c := spec.corner_mouth_m / sqrt(2.0) + r
	var s := spec.side_mouth_m * 0.5
	var pocket_out := r  # pocket centre sits just outside the playfield nose corner

	out.kitchen_line_x = spec.kitchen_line_x
	out.spots = {
		head = Vector3(spec.kitchen_line_x, 0.0, 0.0),
		foot = Vector3(spec.foot_spot_x, 0.0, 0.0),
		centre = Vector3.ZERO,
	}

	var pocket_defs := [
		[&"corner_nw", Vector3(-hl - pocket_out, 0.0, -hw - pocket_out), spec.corner_mouth_m],
		[&"corner_ne", Vector3(hl + pocket_out, 0.0, -hw - pocket_out), spec.corner_mouth_m],
		[&"corner_sw", Vector3(-hl - pocket_out, 0.0, hw + pocket_out), spec.corner_mouth_m],
		[&"corner_se", Vector3(hl + pocket_out, 0.0, hw + pocket_out), spec.corner_mouth_m],
		[&"side_n", Vector3(0.0, 0.0, -hw - pocket_out), spec.side_mouth_m],
		[&"side_s", Vector3(0.0, 0.0, hw + pocket_out), spec.side_mouth_m],
	]
	var pockets_by_id := {}
	for p in pocket_defs:
		var id: StringName = p[0]
		var pos: Vector3 = p[1]
		var ps := PocketSpec.new()
		ps.id = id
		ps.position = pos
		ps.mouth_normal = Vector2(-signf(pos.x), -signf(pos.z))  # points inward, toward table centre
		ps.mouth_width_m = p[2]
		out.pockets.append(ps)
		pockets_by_id[id] = ps
		var shelf: float = spec.corner_shelf_m if String(id).begins_with("corner") else spec.side_shelf_m
		out.drop_zones.append({
			pocket_id = id,
			position = pos,
			size = Vector2(ps.mouth_width_m + shelf * 2.0, ps.mouth_width_m + shelf * 2.0),
		})

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
		var pocket_a: PocketSpec = pockets_by_id[rd[4]]
		var pocket_b: PocketSpec = pockets_by_id[rd[5]]
		var half_a := deg_to_rad((180.0 - _facing_deg(rd[4])) * 0.5)
		var half_b := deg_to_rad((180.0 - _facing_deg(rd[5])) * 0.5)
		seg.facing_a = _facing_dir((seg.a - seg.b).normalized(), (pocket_a.position - seg.a).normalized(), half_a)
		seg.facing_b = _facing_dir((seg.b - seg.a).normalized(), (pocket_b.position - seg.b).normalized(), half_b)
		out.rails.append(seg)

	out.sights = _sights(hl, hw, c, s, spec.rail_width_m, spec.rail_height_m)
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
## pocket) by `half_angle_rad` around Y, whichever sign brings it closer to `bisector` (the
## direction from the rail end toward the pocket centre) — the angled cushion-nose facing.
static func _facing_dir(rail_inward: Vector3, bisector: Vector3, half_angle_rad: float) -> Vector3:
	var a := rail_inward.rotated(Vector3.UP, half_angle_rad)
	var b := rail_inward.rotated(Vector3.UP, -half_angle_rad)
	return a if a.dot(bisector) > b.dot(bisector) else b


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
