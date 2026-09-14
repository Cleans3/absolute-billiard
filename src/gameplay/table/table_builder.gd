class_name TableBuilder
extends RefCounted

## Static bodies and drop-plane areas from a TableLayout — collision only (01 §2, plan.md T1.4).
## Cushion colliders sit at nose height; the angled facings replace the old free jaw cylinders
## so a ball approaching a pocket off-angle rattles against a shaped jaw, not a peg.
## Visuals are table_visuals.gd's job — this file never adds a MeshInstance3D.

const FACING_LENGTH_RATIO := 1.5  # facing-stub length as a multiple of ball radius
const DROP_CHUTE_RATIO := 40.0    # drop-zone chute depth as a multiple of ball radius


static func build(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> void:
	_build_bed(parent, spec, y)
	for rail in layout.rails:
		_build_cushion(parent, spec, rail, y)
		_build_facing(parent, spec, rail.a, rail.facing_a, rail.inward_normal, y)
		_build_facing(parent, spec, rail.b, rail.facing_b, rail.inward_normal, y)
	for pocket in layout.pockets:
		_build_drop_zone(parent, spec, layout, pocket, y)
	_build_safety_floor(parent, spec, y)


static func _cloth_material(spec: TableSpec) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.friction = spec.cloth_friction
	m.rough = true  # friction combine is MIN; rough makes the cloth value win over the ball's
	m.bounce = spec.ball_restitution  # bounce combine is MAX; absorbent subtracts -> 0 on cloth
	m.absorbent = true
	return m


static func _build_bed(parent: Node3D, spec: TableSpec, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "Bed"
	body.physics_material_override = _cloth_material(spec)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(spec.length_m, spec.clearance_margin_m * 2.0, spec.width_m)
	shape.shape = box
	shape.position = Vector3(0, y - box.size.y * 0.5, 0)
	body.add_child(shape)
	parent.add_child(body)


## Box at nose height, inner face on the playfield edge (rail.a/b), extending outward by 2R —
## the ball's own diameter is the natural depth for the contact face.
static func _build_cushion(parent: Node3D, spec: TableSpec, rail: TableLayout.RailSegment, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = String(rail.id)
	body.set_meta(&"rail_id", rail.id)
	body.set_meta(&"rail_normal", rail.inward_normal)
	var pm := PhysicsMaterial.new()
	pm.bounce = spec.ball_restitution - spec.cushion_restitution  # absorbent: effective e = cushion_restitution
	pm.absorbent = true
	pm.friction = spec.cushion_friction
	pm.rough = true
	body.physics_material_override = pm
	var mid := (rail.a + rail.b) * 0.5
	var depth := spec.ball_radius_m * 2.0
	var h := spec.cushion_nose_h_m
	var basis := TableGeometry.rail_basis(rail)
	body.transform = Transform3D(basis, mid - rail.inward_normal * depth * 0.5 + Vector3(0, y + h * 0.5, 0))
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(depth, h, rail.a.distance_to(rail.b))
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)


## Angled jaw stub at a rail end, oriented along the layout's facing direction — the part of the
## cushion that turns a ball toward (or away from) the pocket instead of a bare peg. `inward` is
## the parent straight cushion's own inward_normal (constant along the whole rail, valid at either
## end): the box's thickness is shifted entirely to the outward side of it so the inner face sits
## flush with the nose line — never inside the playfield rectangle — instead of straddling it (F2:
## a box centred on the facing line pokes thick/2 back into the rail's own lane and rejects a
## moderate-speed ball before it ever reaches the pocket).
static func _build_facing(parent: Node3D, spec: TableSpec, at: Vector3, dir: Vector3, inward: Vector3, y: float) -> void:
	if dir.is_zero_approx():
		return
	var body := StaticBody3D.new()
	body.set_meta(&"jaw", true)
	var pm := PhysicsMaterial.new()
	pm.bounce = spec.ball_restitution - spec.jaw_restitution
	pm.absorbent = true
	pm.friction = 0.6
	pm.rough = true
	body.physics_material_override = pm
	var length := spec.ball_radius_m * FACING_LENGTH_RATIO
	var h := spec.cushion_nose_h_m
	# thick enough that a full-power ball (a jaw rattle is exactly the fast, off-angle case this
	# body exists for) cannot cross it within one physics step and tunnel through; jaw_radius_m
	# alone is a few centimetres — fine for the old free-standing cylinder, too thin for a wall
	var thick := maxf(spec.jaw_radius_m * 2.0, spec.ball_radius_m)
	var z := dir.normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x.dot(inward) > 0.0:
		x = -x  # x now points outward, away from the playfield interior
	var anchor := at + x * thick * 0.5
	body.transform = Transform3D(Basis(x, Vector3.UP, z), anchor + z * length * 0.5 + Vector3(0, y + h * 0.5, 0))
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(thick, h, length)
	shape.shape = box
	body.add_child(shape)
	parent.add_child(body)


## A pot is a ball's centre actually leaving the bed (01 §2): the bed and straight cushions are
## exactly the nose-to-nose rectangle (spec.length_m × spec.width_m), so a centre is off it —
## genuinely unsupported, falling — the moment EITHER its x or its z (not necessarily both) passes
## hl/hw. A corner pocket therefore gets two flush strips, one per axis, unioned in a single
## Area3D: each strip sits entirely outside the rectangle on its own axis alone (so neither one
## ever has any part inside it — 01 §2, "never past the nose line into the playfield"), and a ball
## hugging a rail into the corner (only ever off on the ONE axis it left the rail on, its z or x
## unchanged) still lands in the matching strip the instant it clears that edge — it doesn't need
## to also have drifted across the other axis first (gamma F1 negatives A/B/D vs. F2 positive F).
## A side pocket only sits outside on one axis to begin with, so one strip covers it.
static func _build_drop_zone(parent: Node3D, spec: TableSpec, layout: TableLayout, pocket: PocketSpec, y: float) -> void:
	var size := Vector2(pocket.mouth_width_m * 1.4, pocket.mouth_width_m * 1.4)
	for dz in layout.drop_zones:
		if dz.pocket_id == pocket.id:
			size = dz.size
			break
	var area := Area3D.new()
	area.name = "Drop_" + String(pocket.id)
	area.set_meta(&"pocket_id", pocket.id)

	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var sign_x := signf(pocket.position.x)
	var sign_z := signf(pocket.position.z)
	# Tall capture chute below, not a thin slab, so a fast fall can't tunnel past a one-frame-thin
	# trigger between steps.
	var chute := spec.ball_radius_m * DROP_CHUTE_RATIO
	# Top reaches up to the ball's own resting centre height (01 §2 / T1.4 original design): there
	# is no bed under a strip's footprint (it never overlaps the nose-to-nose rectangle — see
	# above), so a ball centred there belongs to the pocket immediately. Tried pulling this down to
	# cloth − R instead (catch only once a centre has actually fallen a radius) and it breaks fast
	# shots outright: an 8 m/s ball crosses a strip's ~0.3 m footprint in ~0.04 s but takes ~0.15 s
	# to fall one radius under gravity, so it flies straight over the strip while still above the
	# lowered top and is never caught at all (reproduced live: tests/physics/probe.gd's jaw-hit
	# case, unrelated to jaws, free-fell to y ≈ -468 m uncaught). The footprint fix above already
	# excludes every gamma A/B/D negative on its own (they never enter a strip's x/z range, whole
	# question of top height is moot for them); keeping top here is what makes a fast shot pot at
	# all.
	var top := y + spec.ball_radius_m
	var mid_y := top - chute * 0.5

	if sign_x != 0.0:
		var cx := sign_x * (hl + size.x * 0.5)
		_add_drop_strip(area, Vector3(size.x, chute, size.y), Vector3(cx, mid_y, pocket.position.z))
	if sign_z != 0.0:
		var cz := sign_z * (hw + size.y * 0.5)
		_add_drop_strip(area, Vector3(size.x, chute, size.y), Vector3(pocket.position.x, mid_y, cz))
	parent.add_child(area)


static func _add_drop_strip(area: Area3D, size: Vector3, position: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = position
	area.add_child(shape)


## Every drop-zone chute above this depth has already caught a genuinely potted ball; anything
## that reaches here fell through a gap in the rail/bed coverage instead of a real pocket and
## should stop, not free-fall forever accelerating under gravity.
static func _build_safety_floor(parent: Node3D, spec: TableSpec, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "SafetyFloor"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var chute_depth := spec.ball_radius_m * DROP_CHUTE_RATIO  # drop zone bottom, see _build_drop_zone
	# thick, not a thin slab: even CCD can miss a one-step-thin static shape at very high speed,
	# and a ball that reaches this point has already been falling uncaught for a while
	var thickness := spec.ball_radius_m * DROP_CHUTE_RATIO
	box.size = Vector3((spec.length_m + spec.rail_width_m * 4.0), thickness, (spec.width_m + spec.rail_width_m * 4.0))
	shape.shape = box
	shape.position = Vector3(0, y - chute_depth - box.size.y * 0.5, 0)
	body.add_child(shape)
	parent.add_child(body)
