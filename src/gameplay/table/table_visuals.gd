class_name TableVisuals
extends RefCounted

## Meshes for a TableLayout — cushion profile, rail frame, sights, pocket liners, apron and legs
## (01 §2, plan.md T1.5). Plain MeshInstance3D, no CSG: visuals never own collision, and a static
## mesh is cheaper per-frame than a baked CSG shape on the mobile budget (07).
##
## Rail cross-section, outward from the nose line (X = table_geometry.rail_basis' local +X):
##   [0, cushion depth)        cushion wedge  — rubber, nose tall, sloping back to the cloth
##   [cushion depth, rail_width_m)  rail block — solid wood, full rail_height_m
## so the two never overlap and there is no gap between them.
##
## Pocket holes (06 P30): the cloth is the nose rectangle with every pocket's hole cut out of it (the same outline
## the bed collider is built from), and each hole is lined by a dark cup — floor, walls, and a back wall on the arc
## outside the nose rectangle. Moving Pockets adds a cloth-coloured cover ring per pocket, slid by table.gd.
##
## Pocket wrap (plan.md T3.2, visual only — no collider changes, cushions/facings unchanged): each rail block's wood is length-extended past its cushion-truncated end at a
## corner (table_geometry.gd's `c`), all the way out to the table's outer footprint. Two
## adjacent rails' extended blocks overlap along the outer edge of the corner square but each
## keeps its own cross-section width, so their union is an L that leaves the inner square
## nearest the pocket open — a picture-frame closing the two rails at 90° without covering the
## mouth. Side pockets need no length extension (the two rails already meet exactly at the
## mouth boundary); `_build_side_horn` caps each of those four rail ends with a short wood nub
## along the same facing direction as the rubber jaw stub, so the flat end-cap face doesn't
## read as the plank "just stopping".

const CLOTH_COLOR := Color(0.05, 0.35, 0.15)
const CUSHION_COLOR := Color(0.03, 0.22, 0.10)
const RAIL_COLOR := Color(0.35, 0.20, 0.08)
const APRON_COLOR := Color(0.22, 0.12, 0.05)
const LEG_COLOR := Color(0.18, 0.10, 0.04)
const SIGHT_COLOR := Color(0.92, 0.88, 0.75)
const LINER_COLOR := Color(0.12, 0.09, 0.07)

const SIGHT_SIZE_RATIO := 0.35       # sight marker size as a multiple of ball radius


static func build(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float, osc_m := 0.0) -> void:
	var cloth := _build_cloth(parent, spec, layout, y)
	for rail in layout.rails:
		_build_cushion(parent, spec, rail, y)
		_build_rail_block(parent, spec, rail, y)
		_build_facing_visual(parent, spec, rail.a, rail.facing_a, rail.inward_normal, y)
		_build_facing_visual(parent, spec, rail.b, rail.facing_b, rail.inward_normal, y)
		match rail.id:
			&"rail_n_w", &"rail_s_w":
				_build_side_horn(parent, spec, rail.b, rail.facing_b, rail.inward_normal, y)
			&"rail_n_e", &"rail_s_e":
				_build_side_horn(parent, spec, rail.a, rail.facing_a, rail.inward_normal, y)
	for pos in layout.sights:
		_build_sight(parent, spec, pos, y)
	for pocket in layout.pockets:
		var hole: TableLayout.Hole = layout.holes[pocket.id]
		_build_pocket_liner(parent, spec, hole, y)
		if osc_m > 0.0:
			_build_cover_mesh(parent, spec, hole, cloth.material_override)
	_build_apron_and_legs(parent, spec, layout, y)
	_merge_by_material(parent)


## 07 §2: one MeshInstance3D per colour instead of one per rail/leg/sight/liner (63 -> 7 draw calls).
## Runs last, over the meshes built above; children are table-local so their own transforms carry over.
static func _merge_by_material(parent: Node3D) -> void:
	var groups: Dictionary = {}  # albedo Color -> SurfaceTool
	var mats: Dictionary = {}
	var merged: Array[MeshInstance3D] = []
	for c in parent.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.material_override is StandardMaterial3D or mi.name == &"Cloth":
			continue  # the cloth keeps its node so a skin can recolour it
		var color := (mi.material_override as StandardMaterial3D).albedo_color
		if not groups.has(color):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[color] = st
			mats[color] = mi.material_override
		(groups[color] as SurfaceTool).append_from(mi.mesh, 0, mi.transform)
		merged.append(mi)
	for mi in merged:
		parent.remove_child(mi)
		mi.free()
	for color: Color in groups:
		var out := MeshInstance3D.new()
		out.name = "Visual_" + color.to_html(false)
		out.mesh = (groups[color] as SurfaceTool).commit()
		out.material_override = mats[color]
		parent.add_child(out)


## Recolours the cloth after `build` (BarSkin felt, 06 P18); the cloth is the one visual that is never merged. The
## Moving Pockets covers share its material, so they follow.
static func set_cloth_color(parent: Node3D, color: Color) -> void:
	var cloth := parent.get_node_or_null(^"Cloth") as MeshInstance3D
	if cloth != null:
		(cloth.material_override as StandardMaterial3D).albedo_color = color


## Matte on purpose (adhoc-1010a C8): the default `metallic_specular` 0.5 adds a white lobe from the table lamp that is
## independent of albedo, so on the near-black cushion rubber it showed as a bright desaturated band along the inner
## edges (measured: ~half of the cushion's lit brightness, 0.07 -> 0.03 median, peak 0.63 -> 0.25). Felt, rubber and wood
## are diffuse materials; the balls keep their own gloss.
static func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	m.metallic_specular = 0.0
	return m


static func _cushion_depth(spec: TableSpec) -> float:
	return spec.ball_radius_m * 2.0  # must match table_builder.gd's cushion collider depth


## Cloth top = the bed outline triangulated at cloth height; each hole gets a rim wall `bed_thickness_m` deep so
## the cut reads as cloth over slate, not a paper-thin sheet.
static func _build_cloth(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := layout.bed_outline
	var idx := Geometry2D.triangulate_polygon(outline)
	for i in range(0, idx.size(), 3):
		_facing_tri(st, _at(outline[idx[i]], y), _at(outline[idx[i + 1]], y), _at(outline[idx[i + 2]], y), Vector3.UP)
	for hole: TableLayout.Hole in layout.holes.values():
		for i in hole.inner.size() - 1:
			_wall_quad(st, hole.inner[i], hole.inner[i + 1], hole.center, y - spec.bed_thickness_m, y)
	var mesh := MeshInstance3D.new()
	mesh.name = "Cloth"
	mesh.mesh = st.commit()
	mesh.material_override = _material(CLOTH_COLOR)
	parent.add_child(mesh)
	return mesh


static func _at(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)


## A triangle whose visible side faces `normal` (Godot draws clockwise-wound faces), with that normal on its vertices.
static func _facing_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_normal(normal)
		st.add_vertex(v)


## Vertical wall from `a` to `b` (table-local xz), `y0` to `y1`, facing toward `toward` (the hole axis).
static func _wall_quad(st: SurfaceTool, a: Vector2, b: Vector2, toward: Vector2, y0: float, y1: float) -> void:
	var mid := (a + b) * 0.5
	var dir := (toward - mid).normalized()
	var n := Vector3(dir.x, 0.0, dir.y)
	_facing_tri(st, _at(a, y0), _at(b, y0), _at(b, y1), n)
	_facing_tri(st, _at(a, y0), _at(b, y1), _at(a, y1), n)


## Triangular prism, cross-section (depth, height) in the rail's local XY: a near-vertical nose
## face at X=0 (the ball's contact face) sloping back down to the cloth at X=depth, extruded
## along Z by the rail length. Simplified K-66: real cushion rubber bulges, this is its wedge.
static func _build_cushion(parent: Node3D, spec: TableSpec, rail: TableLayout.RailSegment, y: float) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Cushion_" + String(rail.id)
	mesh.mesh = _wedge_mesh(_cushion_depth(spec), spec.cushion_nose_h_m, rail.a.distance_to(rail.b))
	mesh.material_override = _material(CUSHION_COLOR)
	var mid := (rail.a + rail.b) * 0.5
	mesh.transform = Transform3D(TableGeometry.rail_basis(rail), mid + Vector3(0, y, 0))
	parent.add_child(mesh)


## The wood block's own length axis is independent of the cushion's — it is extended past a
## corner-adjacent end (table_geometry.gd's `c` truncation) out to the table's outer footprint,
## per the pocket-wrap design in the file header. Side-adjacent ends are left at the rail's own
## a/b (the mouth boundary) since there is no gap to close there.
static func _wood_extent(spec: TableSpec, rail: TableLayout.RailSegment) -> Array:
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var rw := spec.rail_width_m
	match rail.id:
		&"rail_w", &"rail_e":
			return [Vector3(rail.a.x, 0.0, -hw - rw), Vector3(rail.a.x, 0.0, hw + rw)]
		&"rail_n_w", &"rail_s_w":
			return [Vector3(-hl - rw, 0.0, rail.a.z), rail.b]
		&"rail_n_e", &"rail_s_e":
			return [rail.a, Vector3(hl + rw, 0.0, rail.b.z)]
		_:
			return [rail.a, rail.b]


static func _build_rail_block(parent: Node3D, spec: TableSpec, rail: TableLayout.RailSegment, y: float) -> void:
	var depth0 := _cushion_depth(spec)
	var width := spec.rail_width_m - depth0
	if width <= 0.0:
		return
	var ext := _wood_extent(spec, rail)
	var a: Vector3 = ext[0]
	var b: Vector3 = ext[1]
	var mesh := MeshInstance3D.new()
	mesh.name = "RailBlock_" + String(rail.id)
	var box := BoxMesh.new()
	box.size = Vector3(width, spec.rail_height_m, a.distance_to(b))
	mesh.mesh = box
	mesh.material_override = _material(RAIL_COLOR)
	var mid := (a + b) * 0.5
	var basis := TableGeometry.rail_basis(rail)
	# local +X centre sits at depth0 + width/2, local +Y centre at rail_height_m/2 (block rests on cloth)
	mesh.transform = Transform3D(basis, mid - rail.inward_normal * (depth0 + width * 0.5) + Vector3(0, y + spec.rail_height_m * 0.5, 0))
	parent.add_child(mesh)


## Angled facing wedge, same cross-section as the cushion (T5.2: "the cushion profile continued
## ... turned by the facing angle ... no separate box") — matches table_builder.gd's
## `_add_facing_shape` exactly (same anchor/depth math, duplicated here the same way
## `_cushion_depth`'s own doc comment already flags for the plain cushion: visuals and collider
## are built in separate passes from the same layout, not from each other).
static func _build_facing_visual(parent: Node3D, spec: TableSpec, at: Vector3, dir: Vector3, inward: Vector3, y: float) -> void:
	if dir.is_zero_approx():
		return
	var depth := _cushion_depth(spec)
	var h := spec.cushion_nose_h_m
	var length := spec.ball_radius_m * TableBuilder.FACING_LENGTH_RATIO
	var z := dir.normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x.dot(inward) > 0.0:
		x = -x
	var facing := MeshInstance3D.new()
	facing.name = "Facing"
	facing.mesh = _wedge_mesh(depth, h, length)
	facing.material_override = _material(CUSHION_COLOR)
	# Same outward shift as the collider (table_builder.gd): inner face flush with the nose line,
	# fused to the cushion end instead of straddling it with a visible gap or overlap. The wedge's
	# own nose face is at local X=0 (same convention `_build_cushion` uses), so this anchor lines
	# up with the cushion's own X=0 face with no extra offset.
	facing.transform = Transform3D(Basis(x, Vector3.UP, z), at + z * length * 0.5 + Vector3(0, y, 0))
	parent.add_child(facing)


## Wood cap for a side-pocket-adjacent rail end (see file header) — same footprint/direction
## as the rubber jaw stub above it, just full rail_height_m tall and RAIL_COLOR, so the rail
## block's flat end-cap face doesn't read as the plank abruptly stopping. Wood only, above the
## rail top / outside the nose line: shifted entirely to the outward side of the nose, starting
## right where the rubber facing's own depth ends, so nothing sits on the cloth (T5.2; gamma F2:
## "wood V apex well onto the green below the rail edge").
static func _build_side_horn(parent: Node3D, spec: TableSpec, at: Vector3, dir: Vector3, inward: Vector3, y: float) -> void:
	if dir.is_zero_approx():
		return
	var mesh := MeshInstance3D.new()
	mesh.name = "SideHorn"
	var length := spec.ball_radius_m * TableBuilder.FACING_LENGTH_RATIO
	var width := spec.rail_width_m - _cushion_depth(spec)
	var box := BoxMesh.new()
	box.size = Vector3(width, spec.rail_height_m, length)
	mesh.mesh = box
	mesh.material_override = _material(RAIL_COLOR)
	var z := dir.normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x.dot(inward) > 0.0:
		x = -x
	var anchor := at + x * (_cushion_depth(spec) + width * 0.5)
	mesh.transform = Transform3D(Basis(x, Vector3.UP, z), anchor + z * length * 0.5 + Vector3(0, y + spec.rail_height_m * 0.5, 0))
	parent.add_child(mesh)


static func _build_sight(parent: Node3D, spec: TableSpec, pos: Vector3, y: float) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Sight"
	var size := spec.ball_radius_m * SIGHT_SIZE_RATIO
	var box := BoxMesh.new()
	box.size = Vector3(size, spec.clearance_margin_m * 4.0, size)
	mesh.mesh = box
	mesh.material_override = _material(SIGHT_COLOR)
	mesh.transform = Transform3D(Basis(Vector3.UP, PI / 4.0), pos + Vector3(0, y, 0))  # diamond, 45° in plan view
	parent.add_child(mesh)


## The hole's cup, seen from above: dark walls from the cloth plane down to the floor `cup_depth_m` below, the floor,
## and a back wall to rail height on the arc outside the nose rectangle (table_builder.gd's `_build_cup`, same ring).
## Double-sided and unlit by the room's baked light: it is a pit, it should read as one.
static func _build_pocket_liner(parent: Node3D, spec: TableSpec, hole: TableLayout.Hole, y: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var floor_y := y - spec.cup_depth_m
	var ring := hole.ring
	for i in ring.size():
		_wall_quad(st, ring[i], ring[(i + 1) % ring.size()], hole.center, floor_y, y)
		_facing_tri(st, _at(hole.center, floor_y), _at(ring[i], floor_y), _at(ring[(i + 1) % ring.size()], floor_y), Vector3.UP)
	for i in hole.outer.size() - 1:
		_wall_quad(st, hole.outer[i], hole.outer[i + 1], hole.center, y, y + spec.rail_height_m)
	var mesh := MeshInstance3D.new()
	mesh.name = "Liner_" + String(hole.pocket_id)
	mesh.mesh = st.commit()
	var mat := _material(LINER_COLOR)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	parent.add_child(mesh)


## Moving Pockets cover: top ring (flat, then ramped down at its rim) plus the inner rim wall, local to the
## `Cover_<id>` body table_builder.gd made (origin = hole centre at cloth height). Shares the cloth's material.
static func _build_cover_mesh(parent: Node3D, spec: TableSpec, hole: TableLayout.Hole, cloth_material: Material) -> void:
	var body := parent.get_node_or_null(NodePath("Cover_" + String(hole.pocket_id)))
	if body == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := TableBuilder.cover_rings(spec, hole)
	for ring in rings:
		for k in TableBuilder.COVER_SEGMENTS:
			var d0 := Vector2.from_angle(TAU * k / TableBuilder.COVER_SEGMENTS)
			var d1 := Vector2.from_angle(TAU * (k + 1) / TableBuilder.COVER_SEGMENTS)
			var ai := _at(d0 * float(ring.r_in), float(ring.top_in))
			var bi := _at(d1 * float(ring.r_in), float(ring.top_in))
			var bo := _at(d1 * float(ring.r_out), float(ring.top_out))
			var ao := _at(d0 * float(ring.r_out), float(ring.top_out))
			var n := (bi - ai).cross(ao - ai).normalized()
			if n.y < 0.0:
				n = -n
			_facing_tri(st, ai, bi, bo, n)
			_facing_tri(st, ai, bo, ao, n)
	var inner: Dictionary = rings[0]
	for k in TableBuilder.COVER_SEGMENTS:
		var d0 := Vector2.from_angle(TAU * k / TableBuilder.COVER_SEGMENTS) * float(inner.r_in)
		var d1 := Vector2.from_angle(TAU * (k + 1) / TableBuilder.COVER_SEGMENTS) * float(inner.r_in)
		_wall_quad(st, d0, d1, Vector2.ZERO, -spec.bed_thickness_m, float(inner.top_in))
	var mesh := MeshInstance3D.new()
	mesh.name = "CoverMesh"
	mesh.mesh = st.commit()
	mesh.material_override = cloth_material
	body.add_child(mesh)


static func _build_apron_and_legs(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> void:
	for rail in layout.rails:
		var mesh := MeshInstance3D.new()
		mesh.name = "Apron_" + String(rail.id)
		var box := BoxMesh.new()
		# Same corner extension as the rail block (T3.2 `_wood_extent`): without it the apron stops
		# at the cushion truncation like the old rail block did, leaving a gap at every corner turn
		# that the background shows through (gamma F2, 05b).
		var ext := _wood_extent(spec, rail)
		var a: Vector3 = ext[0]
		var b: Vector3 = ext[1]
		box.size = Vector3(spec.rail_width_m, spec.apron_h_m, a.distance_to(b))
		mesh.mesh = box
		mesh.material_override = _material(APRON_COLOR)
		var mid := (a + b) * 0.5
		var basis := TableGeometry.rail_basis(rail)
		mesh.transform = Transform3D(basis, mid - rail.inward_normal * spec.rail_width_m * 0.5 + Vector3(0, y - spec.apron_h_m * 0.5, 0))
		parent.add_child(mesh)

	var hl := spec.length_m * 0.5 + spec.rail_width_m * 0.6
	var hw := spec.width_m * 0.5 + spec.rail_width_m * 0.6
	var leg_top := y - spec.apron_h_m
	var leg_size := spec.rail_width_m * 0.3
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var mesh := MeshInstance3D.new()
			mesh.name = "Leg"
			var box := BoxMesh.new()
			box.size = Vector3(leg_size, leg_top, leg_size)
			mesh.mesh = box
			mesh.material_override = _material(LEG_COLOR)
			mesh.position = Vector3(sx * hl, leg_top * 0.5, sz * hw)
			parent.add_child(mesh)


static func _wedge_mesh(depth: float, height: float, length: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := length * 0.5
	var p0 := Vector3(0.0, 0.0, -hz)   # nose base
	var p1 := Vector3(0.0, height, -hz)  # nose tip (ball contact face is p0-p1)
	var p2 := Vector3(depth, 0.0, -hz)   # outward base, where the rail block continues
	var q0 := Vector3(0.0, 0.0, hz)
	var q1 := Vector3(0.0, height, hz)
	var q2 := Vector3(depth, 0.0, hz)
	_tri(st, p0, p2, p1)   # -Z end cap
	_tri(st, q0, q1, q2)   # +Z end cap
	_quad(st, p0, p1, q1, q0)  # nose face
	_quad(st, p1, p2, q2, q1)  # sloped back face
	_quad(st, p2, p0, q0, q2)  # base
	st.generate_normals()
	return st.commit()


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)
