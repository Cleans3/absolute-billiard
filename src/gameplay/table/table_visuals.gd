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

const CLOTH_COLOR := Color(0.05, 0.35, 0.15)
const CUSHION_COLOR := Color(0.03, 0.22, 0.10)
const RAIL_COLOR := Color(0.35, 0.20, 0.08)
const APRON_COLOR := Color(0.22, 0.12, 0.05)
const LEG_COLOR := Color(0.18, 0.10, 0.04)
const SIGHT_COLOR := Color(0.92, 0.88, 0.75)
const LINER_COLOR := Color(0.12, 0.09, 0.07)

const PLANK_THICKNESS_RATIO := 0.25  # rail-top visual thickness as a fraction of rail_height_m
const SIGHT_SIZE_RATIO := 0.35       # sight marker size as a multiple of ball radius


static func build(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> void:
	_build_cloth(parent, spec, y)
	for rail in layout.rails:
		_build_cushion(parent, spec, rail, y)
		_build_rail_block(parent, spec, rail, y)
		_build_facing_visual(parent, spec, rail.a, rail.facing_a, y)
		_build_facing_visual(parent, spec, rail.b, rail.facing_b, y)
	for pos in layout.sights:
		_build_sight(parent, spec, pos, y)
	for pocket in layout.pockets:
		_build_pocket_liner(parent, spec, pocket, y)
	_build_apron_and_legs(parent, spec, layout, y)


static func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


static func _cushion_depth(spec: TableSpec) -> float:
	return spec.ball_radius_m * 2.0  # must match table_builder.gd's cushion collider depth


static func _build_cloth(parent: Node3D, spec: TableSpec, y: float) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Cloth"
	var box := BoxMesh.new()
	box.size = Vector3(spec.length_m, spec.clearance_margin_m, spec.width_m)
	mesh.mesh = box
	mesh.material_override = _material(CLOTH_COLOR)
	mesh.position = Vector3(0, y - box.size.y * 0.5, 0)
	parent.add_child(mesh)


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


static func _build_rail_block(parent: Node3D, spec: TableSpec, rail: TableLayout.RailSegment, y: float) -> void:
	var depth0 := _cushion_depth(spec)
	var width := spec.rail_width_m - depth0
	if width <= 0.0:
		return
	var mesh := MeshInstance3D.new()
	mesh.name = "RailBlock_" + String(rail.id)
	var box := BoxMesh.new()
	box.size = Vector3(width, spec.rail_height_m, rail.a.distance_to(rail.b))
	mesh.mesh = box
	mesh.material_override = _material(RAIL_COLOR)
	var mid := (rail.a + rail.b) * 0.5
	var basis := TableGeometry.rail_basis(rail)
	# local +X centre sits at depth0 + width/2, local +Y centre at rail_height_m/2 (block rests on cloth)
	mesh.transform = Transform3D(basis, mid - rail.inward_normal * (depth0 + width * 0.5) + Vector3(0, y + spec.rail_height_m * 0.5, 0))
	parent.add_child(mesh)


static func _build_facing_visual(parent: Node3D, spec: TableSpec, at: Vector3, dir: Vector3, y: float) -> void:
	if dir.is_zero_approx():
		return
	var mesh := MeshInstance3D.new()
	mesh.name = "Facing"
	var length := spec.ball_radius_m * TableBuilder.FACING_LENGTH_RATIO
	var box := BoxMesh.new()
	box.size = Vector3(spec.jaw_radius_m * 2.0, spec.cushion_nose_h_m, length)
	mesh.mesh = box
	mesh.material_override = _material(CUSHION_COLOR)
	var z := dir.normalized()
	var x := Vector3.UP.cross(z).normalized()
	mesh.transform = Transform3D(Basis(x, Vector3.UP, z), at + z * length * 0.5 + Vector3(0, y + spec.cushion_nose_h_m * 0.5, 0))
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


## The cup sits mostly below cloth level (a real liner is a leather pouch under the slate) but its
## rim rises a little above so it reads as a visible dark ring inside the mouth, not an empty hole.
static func _build_pocket_liner(parent: Node3D, spec: TableSpec, pocket: PocketSpec, y: float) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "Liner_" + String(pocket.id)
	var cyl := CylinderMesh.new()
	cyl.top_radius = pocket.mouth_width_m * 0.5
	cyl.bottom_radius = cyl.top_radius * 0.8
	cyl.height = spec.ball_radius_m * 1.2
	mesh.mesh = cyl
	mesh.material_override = _material(LINER_COLOR)
	var rim := spec.ball_radius_m * 0.15
	mesh.position = pocket.position + Vector3(0, y + rim - cyl.height * 0.5, 0)
	parent.add_child(mesh)


static func _build_apron_and_legs(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> void:
	for rail in layout.rails:
		var mesh := MeshInstance3D.new()
		mesh.name = "Apron_" + String(rail.id)
		var box := BoxMesh.new()
		box.size = Vector3(spec.rail_width_m, spec.apron_h_m, rail.a.distance_to(rail.b))
		mesh.mesh = box
		mesh.material_override = _material(APRON_COLOR)
		var mid := (rail.a + rail.b) * 0.5
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
