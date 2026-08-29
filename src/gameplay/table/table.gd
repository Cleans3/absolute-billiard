class_name Table
extends Node3D

## Builds bed, rails, jaw cylinders and drop planes from a TableSpec at _ready.
## A pot is a ball entering a drop plane; jaws make rattle/reject emerge (01 §2).

signal ball_dropped(ball: Ball, pocket_id: StringName)

@export var spec: TableSpec = TableSpec.new()

var pockets: Dictionary = {}  # StringName -> PocketSpec


func cloth_y() -> float:
	return spec.bed_height_m


func get_pocket(id: StringName) -> PocketSpec:
	return pockets.get(id)


func _ready() -> void:
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var r := spec.ball_radius_m
	var y := spec.bed_height_m
	# corner mouth is measured on the diagonal; along an edge it spans c
	var c := spec.corner_mouth_m / sqrt(2.0)
	var s := spec.side_mouth_m * 0.5
	var out := 0.03  # pocket centre sits just outside the playfield corner

	_build_bed(hl, hw, y)

	var specs := [
		[&"corner_nw", Vector3(-hl - out, y, -hw - out), Vector2(1, 1), spec.corner_mouth_m],
		[&"corner_ne", Vector3(hl + out, y, -hw - out), Vector2(-1, 1), spec.corner_mouth_m],
		[&"corner_sw", Vector3(-hl - out, y, hw + out), Vector2(1, -1), spec.corner_mouth_m],
		[&"corner_se", Vector3(hl + out, y, hw + out), Vector2(-1, -1), spec.corner_mouth_m],
		[&"side_n", Vector3(0, y, -hw - out), Vector2(0, 1), spec.side_mouth_m],
		[&"side_s", Vector3(0, y, hw + out), Vector2(0, -1), spec.side_mouth_m],
	]
	for p in specs:
		var ps := PocketSpec.new()
		ps.id = p[0]
		ps.position = p[1]
		ps.mouth_normal = p[2]
		ps.mouth_width_m = p[3]
		pockets[ps.id] = ps
		_build_drop_plane(ps, r)

	# rail segments: [id, from, to] along the playfield edge, jaws at both ends
	var rails := [
		[&"rail_n_w", Vector3(-hl + c, y, -hw), Vector3(-s, y, -hw)],
		[&"rail_n_e", Vector3(s, y, -hw), Vector3(hl - c, y, -hw)],
		[&"rail_s_w", Vector3(-hl + c, y, hw), Vector3(-s, y, hw)],
		[&"rail_s_e", Vector3(s, y, hw), Vector3(hl - c, y, hw)],
		[&"rail_w", Vector3(-hl, y, -hw + c), Vector3(-hl, y, hw - c)],
		[&"rail_e", Vector3(hl, y, -hw + c), Vector3(hl, y, hw - c)],
	]
	for rl in rails:
		_build_rail(rl[0], rl[1], rl[2], r)


func _build_bed(hl: float, hw: float, y: float) -> void:
	var bed := CSGCombiner3D.new()
	bed.name = "Bed"
	add_child(bed)
	var box := CSGBox3D.new()
	box.size = Vector3(hl * 2 + 0.3, 0.12, hw * 2 + 0.3)
	box.position = Vector3(0, y - 0.06, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.35, 0.15)
	box.material = mat
	bed.add_child(box)
	# pocket throats: subtract a cylinder at each pocket
	var out := 0.03
	for pos in [Vector3(-hl - out, 0, -hw - out), Vector3(hl + out, 0, -hw - out),
			Vector3(-hl - out, 0, hw + out), Vector3(hl + out, 0, hw + out),
			Vector3(0, 0, -hw - out), Vector3(0, 0, hw + out)]:
		var hole := CSGCylinder3D.new()
		hole.operation = CSGShape3D.OPERATION_SUBTRACTION
		hole.radius = 0.075
		hole.height = 0.2
		hole.position = Vector3(pos.x, y - 0.06, pos.z)
		bed.add_child(hole)
	# legs
	for lx in [-hl + 0.1, hl - 0.1]:
		for lz in [-hw + 0.1, hw - 0.1]:
			var leg := CSGBox3D.new()
			leg.size = Vector3(0.12, y - 0.12, 0.12)
			leg.position = Vector3(lx, (y - 0.12) * 0.5, lz)
			leg.material = mat
			bed.add_child(leg)
	# CSG has no physics material, so bake its mesh into a StaticBody3D that does
	var body := StaticBody3D.new()
	body.name = "BedBody"
	var cloth_mat := PhysicsMaterial.new()
	cloth_mat.friction = spec.cloth_friction
	cloth_mat.bounce = 0.0
	body.physics_material_override = cloth_mat
	var shape := CollisionShape3D.new()
	shape.shape = bed.bake_collision_shape()
	body.add_child(shape)
	add_child(body)


func _build_rail(id: StringName, a: Vector3, b: Vector3, r: float) -> void:
	var body := StaticBody3D.new()
	body.name = String(id)
	body.set_meta(&"rail_id", id)
	var pm := PhysicsMaterial.new()
	pm.bounce = spec.cushion_restitution
	pm.friction = spec.cushion_friction
	body.physics_material_override = pm
	var mid := (a + b) * 0.5
	var along := b - a
	var thick := 0.06
	var h := r * 1.4  # cushion nose meets the ball just above its equator
	# push the rail outward so its inner face sits on the playfield edge
	var normal := Vector3(0, 0, signf(mid.z)) if is_zero_approx(along.z) else Vector3(signf(mid.x), 0, 0)
	body.position = mid + normal * thick * 0.5 + Vector3(0, h * 0.5, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(along.length(), h, thick) if is_zero_approx(along.z) else Vector3(thick, h, along.length())
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.2, 0.08)
	mesh.material_override = mat
	body.add_child(mesh)
	add_child(body)
	_build_jaw(a, r)
	_build_jaw(b, r)


func _build_jaw(at: Vector3, r: float) -> void:
	var body := StaticBody3D.new()
	body.set_meta(&"jaw", true)
	var pm := PhysicsMaterial.new()
	pm.bounce = spec.jaw_restitution
	pm.friction = 0.6
	body.physics_material_override = pm
	body.position = at + Vector3(0, r, 0)
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = spec.jaw_radius_m
	cyl.height = r * 2.0
	shape.shape = cyl
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = cyl.radius
	cm.bottom_radius = cyl.radius
	cm.height = cyl.height
	mesh.mesh = cm
	body.add_child(mesh)
	add_child(body)


func _build_drop_plane(ps: PocketSpec, r: float) -> void:
	var area := Area3D.new()
	area.name = "Drop_" + String(ps.id)
	# overlap begins once the ball centre has fallen past cloth level
	area.position = ps.position + Vector3(0, -2.0 * r, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.16, 0.02, 0.16)
	shape.shape = box
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(func(body: Node3D) -> void:
		if body is Ball and not body.is_pocketed:
			body.pocket(ps.id)
			ball_dropped.emit(body, ps.id))
