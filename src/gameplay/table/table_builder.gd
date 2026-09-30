class_name TableBuilder
extends RefCounted

## Static bodies and drop-plane areas from a TableLayout — collision only (01 §2, plan.md T1.4).
## Cushion colliders sit at nose height; the angled facings replace the old free jaw cylinders
## so a ball approaching a pocket off-angle rattles against a shaped jaw, not a peg.
## Visuals are table_visuals.gd's job — this file never adds a MeshInstance3D.

# 07 §1 layer bits: balls 1, table (bed + rails) 2, pockets 3, world 4 (players, props). Ball mask = 1|2|3.
const LAYER_TABLE := 1 << 1
const LAYER_POCKET := 1 << 2
const BALL_LAYER := 1

const FACING_LENGTH_RATIO := 1.5  # facing-stub length as a multiple of ball radius


## A collider a fast ball could cross within one physics step is a tunnelling/ghost-collision
## risk even with CCD on (Godot 4.7 docs: CCD "prevents... tunneling" but the documented fix for
## a still-bad contact is "making static collision shapes thicker"; Jolt's own ghost-collision
## mitigation only works within one body, never at the seam between two separate StaticBody3D —
## exactly what a cushion meeting a facing is). `max_ball_speed_mps` is scale-invariant (matches
## CueSpec.power_cap_speed_mps), so this floor does not shrink away at a small `scale` the way
## `ball_radius_m`-derived thicknesses do (loop-1 T4.8, gamma H: 9 m/s into a side jaw at scale
## 1.0 launched clean over the rail — a ghost contact at the cushion/facing seam, the facing's own
## thickness only 28.6 mm against a 75 mm step).
static func _min_step_safe_thickness(spec: TableSpec) -> float:
	return spec.max_ball_speed_mps / PhysicsSim.LIVE_TICK


static func build(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> void:
	_build_bed(parent, spec, y)
	for rail in layout.rails:
		_build_cushion(parent, spec, rail, y)
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
	body.collision_layer = LAYER_TABLE
	body.collision_mask = 0
	body.physics_material_override = _cloth_material(spec)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(spec.length_m, spec.clearance_margin_m * 2.0, spec.width_m)
	shape.shape = box
	shape.position = Vector3(0, y - box.size.y * 0.5, 0)
	body.add_child(shape)
	parent.add_child(body)


## Box at nose height, inner face on the playfield edge (rail.a/b), extending outward by 2R — the
## ball's own diameter is the natural depth for the contact face. Both angled jaw facings are extra
## CollisionShape3D children of this SAME StaticBody3D (T5.1), not their own bodies: Jolt's own
## internal-edge removal (physics/jolt_physics_3d/simulation/use_enhanced_internal_edge_removal, on
## by default) only ever applies within a single body, never across two separate StaticBody3D
## (confirmed via context7, Jolt's Architecture.md "Ghost Collisions" + Godot's
## using_jolt_physics.rst) — and a separate facing body was exactly the loop-1 verdict F1 bug: a
## ball hugging the rail at a fraction of a ball-radius clearance sits continuously in Jolt's
## speculative-contact range of the nose the whole way, so it reaches the cushion/facing boundary
## already "in contact" rather than freely rolling up to it; empirically (loop-2 T5.1) even a
## *coplanar*, perfectly flush split of the cushion into "main span" + "corner stub" bodies still
## reproduced the exact same deflection, because the ball's nearest point on the short stub lands
## on the stub's own end-cap edge rather than a flat nose face — an ill-defined edge normal fought
## with the main cushion's clean one. One body, whole rail, was the only arrangement that didn't
## reproduce it in every offset/speed/scale combination tried. The cost: the facing stubs share the
## cushion's material instead of `jaw_restitution`'s duller one (PhysicsMaterial is body-level, not
## per-shape, in Godot) — logged as a deliberate trade-off, not an oversight; `jaw_restitution`
## stays in TableSpec as a now-inert tunable rather than a churny removal this late in the plan.
static func _build_cushion(parent: Node3D, spec: TableSpec, rail: TableLayout.RailSegment, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = String(rail.id)
	body.collision_layer = LAYER_TABLE
	body.collision_mask = 0
	body.set_meta(&"rail_id", rail.id)
	body.set_meta(&"rail_normal", rail.inward_normal)
	var pm := PhysicsMaterial.new()
	pm.bounce = spec.ball_restitution - spec.cushion_restitution  # absorbent: effective e = cushion_restitution
	pm.absorbent = true
	pm.friction = spec.cushion_friction
	pm.rough = true
	body.physics_material_override = pm
	var mid := (rail.a + rail.b) * 0.5
	# thick enough that a full-power ball cannot cross it within one physics step and tunnel
	# through, floored against a scale-invariant step-safe minimum (see _min_step_safe_thickness)
	# since ball_radius_m shrinks at a small `scale` while cue speed never does. Both facings below
	# share this same depth — "the cushion profile continued" (T5.2) means the same cross-section,
	# not a thinner one.
	var depth := maxf(spec.ball_radius_m * 2.0, _min_step_safe_thickness(spec))
	var h := spec.cushion_nose_h_m
	var basis := TableGeometry.rail_basis(rail)
	# Body stays at identity — the cushion box AND both facings are CollisionShape3D children,
	# each carrying its own full local (== world, since the body itself never rotates) transform.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(depth, h, rail.a.distance_to(rail.b))
	shape.shape = box
	shape.transform = Transform3D(basis, mid - rail.inward_normal * depth * 0.5 + Vector3(0, y + h * 0.5, 0))
	body.add_child(shape)

	for pair in [[rail.a, rail.facing_a], [rail.b, rail.facing_b]]:
		_add_facing_shape(body, spec, pair[0], pair[1], rail.inward_normal, depth, h, y)
	parent.add_child(body)


## Angled jaw stub at a rail end, oriented along the layout's facing direction — the part of the
## cushion that turns a ball toward (or away from) the pocket instead of a bare peg. `inward` is
## the parent straight cushion's own inward_normal (constant along the whole rail, valid at either
## end): the box's thickness is shifted entirely to the outward side of it so the inner face sits
## flush with the nose line — never inside the playfield rectangle — instead of straddling it (F2:
## a box centred on the facing line pokes thick/2 back into the rail's own lane and rejects a
## moderate-speed ball before it ever reaches the pocket). A plain CollisionShape3D child of the
## cushion's own body (see `_build_cushion`'s comment), positioned in that body's local space —
## the body transform carries no rotation, so this world-space transform is used directly.
static func _add_facing_shape(body: StaticBody3D, spec: TableSpec, at: Vector3, dir: Vector3, inward: Vector3, depth: float, h: float, y: float) -> void:
	if dir.is_zero_approx():
		return
	var length := spec.ball_radius_m * FACING_LENGTH_RATIO
	var z := dir.normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x.dot(inward) > 0.0:
		x = -x  # x now points outward, away from the playfield interior
	var anchor := at + x * depth * 0.5
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(depth, h, length)
	shape.shape = box
	shape.transform = Transform3D(Basis(x, Vector3.UP, z), anchor + z * length * 0.5 + Vector3(0, y + h * 0.5, 0))
	body.add_child(shape)


## A pot is a ball's centre actually leaving the bed (01 §2): the bed and straight cushions are
## exactly the nose-to-nose rectangle (spec.length_m × spec.width_m), so a centre is off it —
## genuinely unsupported, falling — the moment EITHER its x or its z (not necessarily both) passes
## hl/hw. TableGeometry.layout() is the single source of truth for the strip list (T5.3): this
## just builds exactly what it describes, no re-derivation, so the gizmo (which also reads
## layout.drop_zones directly) can never drift from what actually gets built.
static func _build_drop_zone(parent: Node3D, spec: TableSpec, layout: TableLayout, pocket: PocketSpec, y: float) -> void:
	var area := Area3D.new()
	area.name = "Drop_" + String(pocket.id)
	area.set_meta(&"pocket_id", pocket.id)
	area.collision_layer = LAYER_POCKET
	area.collision_mask = BALL_LAYER
	area.monitorable = false
	for dz in layout.drop_zones:
		if dz.pocket_id != pocket.id:
			continue
		var pos: Vector3 = dz.position
		var size: Vector3 = dz.size
		_add_drop_strip(area, size, pos + Vector3(0, y, 0))
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
	var chute_depth := spec.ball_radius_m * TableGeometry.DROP_CHUTE_RATIO  # drop zone bottom, see _build_drop_zone
	# thick, not a thin slab: even CCD can miss a one-step-thin static shape at very high speed,
	# and a ball that reaches this point has already been falling uncaught for a while
	var thickness := spec.ball_radius_m * TableGeometry.DROP_CHUTE_RATIO
	box.size = Vector3((spec.length_m + spec.rail_width_m * 4.0), thickness, (spec.width_m + spec.rail_width_m * 4.0))
	shape.shape = box
	shape.position = Vector3(0, y - chute_depth - box.size.y * 0.5, 0)
	body.add_child(shape)
	parent.add_child(body)
