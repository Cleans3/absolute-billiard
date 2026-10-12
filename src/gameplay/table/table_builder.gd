class_name TableBuilder
extends RefCounted

## Static bodies and pocket sensors from a TableLayout — collision only (01 §2, 06 P30). Cushion colliders sit at
## nose height; the angled facings replace the old free jaw cylinders so a ball approaching a pocket off-angle
## rattles against a shaped jaw, not a peg. The bed is the nose rectangle with a hole cut at every pocket (convex
## pieces, never a trimesh), a cup hangs under each hole, and a ball is potted by reaching the cup (table.gd).
## Visuals are table_visuals.gd's job — this file never adds a MeshInstance3D.

# 07 §1 layer bits: balls 1, table (bed + rails) 2, pockets 3, world 4 (players, props). Ball mask = 1|2|3.
const LAYER_TABLE := 1 << 1
const LAYER_POCKET := 1 << 2
const BALL_LAYER := 1

const FACING_LENGTH_RATIO := 1.5  # facing-stub length as a multiple of ball radius
const COVER_LIFT_M := 0.0015      # Moving Pockets cover top above the cloth: never coplanar with the bed (E2)
const COVER_BEVEL_M := 0.015      # ... and ramped down to the cloth over this width, so a ball rolls up it unbothered
const COVER_OVERLAP_M := 0.02     # cover reaches this far past the widest cut, onto the bed
const COVER_SEGMENTS := 32
const BACK_WALL_TRIM_SEGS := 2     # ... and it starts this many arc segments past each cushion tip (the facing stub covers those)
const BACK_WALL_RADII := 4.0      # pocket back wall height above the cloth: past a ball's top, so no edge kicks one upward


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


## `osc_m` > 0 (Moving Pockets) adds one sliding cover per pocket over the widened cut (see `_build_cover`).
static func build(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float, osc_m := 0.0) -> void:
	_build_bed(parent, spec, layout, y)
	for rail in layout.rails:
		_build_cushion(parent, spec, rail, y)
	for pocket in layout.pockets:
		var hole: TableLayout.Hole = layout.holes[pocket.id]
		_build_cup(parent, spec, hole, y)
		_build_sensor(parent, spec, hole, y)
		if osc_m > 0.0:
			_build_cover(parent, spec, hole, y)
	_build_safety_floor(parent, spec, y)


## Contact materials. Jolt sums the two bounces (clamped to 1) and an `absorbent` side subtracts, against balls that carry
## TableSpec.BASE_BOUNCE: cloth e = 0, cushion e = e0, cup e = cup_bounce. `rough` makes the table's friction win over the
## ball's (the combine is MIN otherwise). `apply_materials` redoes the numbers on live bodies: no rebuild.
static func _cloth_material(spec: TableSpec) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.rough = true
	m.absorbent = true
	_set_cloth(m, spec, 1.0)
	return m


static func _set_cloth(m: PhysicsMaterial, spec: TableSpec, friction_mult: float) -> void:
	m.friction = spec.cloth_friction * friction_mult
	m.bounce = TableSpec.BASE_BOUNCE


static func _set_cushion(m: PhysicsMaterial, spec: TableSpec) -> void:
	m.bounce = TableSpec.BASE_BOUNCE - spec.cushion_restitution
	m.friction = spec.cushion_friction


## A spinning ball hitting a grippy wall climbs it; the cup only has to hold the ball, a felt pouch it dies in.
static func _set_cup(m: PhysicsMaterial, spec: TableSpec) -> void:
	m.bounce = TableSpec.BASE_BOUNCE - spec.cup_bounce
	m.friction = spec.cup_friction


## Re-applies the spec's contact numbers to the bodies `build()` made. `cloth_mult` = PhysicsSim's cloth_friction_mult.
static func apply_materials(parent: Node3D, spec: TableSpec, cloth_mult: float) -> void:
	for c in parent.get_children():
		if not (c is PhysicsBody3D) or c.physics_material_override == null:
			continue
		var n := String(c.name)
		if n == "Bed" or n.begins_with("Cover_"):
			_set_cloth(c.physics_material_override, spec, cloth_mult)
		elif n.begins_with("Cup_"):
			_set_cup(c.physics_material_override, spec)
		elif c.has_meta(&"rail_normal"):
			_set_cushion(c.physics_material_override, spec)


## Flat convex prisms, one body: Jolt's internal-edge removal works within a body, so a ball rolls over the seams
## between pieces exactly as over one slab (tests/physics/probe.gd roll-out and seam probe hold that).
static func _build_bed(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "Bed"
	body.collision_layer = LAYER_TABLE
	body.collision_mask = 0
	body.physics_material_override = _cloth_material(spec)
	for piece in layout.bed_pieces:
		var shape := CollisionShape3D.new()
		shape.shape = _prism(piece, y - spec.bed_thickness_m, y)
		body.add_child(shape)
	parent.add_child(body)


## Convex prism over `poly` (table-local xz, convex) from `y0` up to `y1`.
static func _prism(poly: PackedVector2Array, y0: float, y1: float) -> ConvexPolygonShape3D:
	var pts := PackedVector3Array()
	for p in poly:
		pts.append(Vector3(p.x, y0, p.y))
		pts.append(Vector3(p.x, y1, p.y))
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	return shape


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
	pm.absorbent = true
	pm.rough = true
	_set_cushion(pm, spec)
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


## The pocket cup under a hole: a floor `cup_depth_m` below the cloth and a wall all round it up to the cloth plane,
## then — on the outer arc, outside the nose rectangle, where the rail wood stands — a back wall so a fast ball
## cannot skip across the hole and out of the table. Walls are thick (a full-power step cannot cross them)
## and stand outward of the ring; one body, felt-like (absorbent) so a ball that drops stays dropped.
static func _build_cup(parent: Node3D, spec: TableSpec, hole: TableLayout.Hole, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "Cup_" + String(hole.pocket_id)
	body.collision_layer = LAYER_TABLE
	body.collision_mask = 0
	var pm := PhysicsMaterial.new()
	pm.rough = true
	pm.absorbent = true
	_set_cup(pm, spec)
	body.physics_material_override = pm
	var t := maxf(spec.ball_radius_m * 2.0, _min_step_safe_thickness(spec))
	var floor_y := y - spec.cup_depth_m
	var floor_shape := CollisionShape3D.new()
	floor_shape.shape = _prism(hole.ring, floor_y - t, floor_y)
	body.add_child(floor_shape)
	# The cup's own tops stay off the playing surface: a second body's coplanar edge on the cloth is a ghost bump (the
	# same seam the cushion/facing comment above fights). Under the bed the slab rim is the hole's wall; outside the
	# nose rectangle there is no bed, so the wall climbs to back-wall height there.
	_add_wall(body, hole.ring, true, hole.center, t, floor_y, y - spec.bed_thickness_m)
	_add_wall(body, hole.outer, false, hole.center, t, y - spec.bed_thickness_m, y + BACK_WALL_RADII * spec.ball_radius_m, BACK_WALL_TRIM_SEGS)
	parent.add_child(body)


## Thick wall along the polyline `pts` (closed ring or open arc), standing on the outward side of it, from `y0` to `y1`.
## `trim` drops that many segments off each end of an open arc: at a cushion tip the ring's outward normal leans back
## into the playfield, and a wall extruded there would stand on the cloth beside the rail.
static func _add_wall(body: StaticBody3D, pts: PackedVector2Array, closed: bool, center: Vector2, t: float, y0: float, y1: float, trim := 0) -> void:
	var n := pts.size()
	for i in range(trim, (n if closed else n - 1 - trim)):
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var na := (a - center).normalized() * t
		var nb := (b - center).normalized() * t
		var shape := CollisionShape3D.new()
		shape.shape = _prism(PackedVector2Array([a, b, b + nb, a + na]), y0, y1)
		body.add_child(shape)


## Pot sensor (06 P30 pot rule): a cylinder in the cup whose top sits `pot_depth_m + R` under the cloth, so the ball's
## own sphere touches it exactly when its CENTRE is `pot_depth_m` below the cloth top. Anything that deep is in a cup.
static func _build_sensor(parent: Node3D, spec: TableSpec, hole: TableLayout.Hole, y: float) -> void:
	var area := Area3D.new()
	area.name = "Drop_" + String(hole.pocket_id)
	area.set_meta(&"pocket_id", hole.pocket_id)
	area.collision_layer = LAYER_POCKET
	area.collision_mask = BALL_LAYER
	area.monitorable = false
	var top := y - spec.pot_depth_m - spec.ball_radius_m
	var bottom := y - spec.cup_depth_m
	var cyl := CylinderShape3D.new()
	cyl.radius = hole.apothem
	cyl.height = top - bottom
	var shape := CollisionShape3D.new()
	shape.shape = cyl
	shape.position = Vector3(hole.center.x, (top + bottom) * 0.5, hole.center.y)
	area.add_child(shape)
	parent.add_child(area)


## Moving Pockets (E2): the bed hole is cut as wide as the whole sweep, and this kinematic ring — an annulus whose
## inner circle is the real opening — slides over the cut on the shared pocket clock, so the opening moves and
## everything else of the cut stays cloth. Its top is lifted above the cloth and ramped down at the rim, never
## coplanar with the bed. Local origin = the hole centre at cloth height; table.gd slides it along the rail.
static func _build_cover(parent: Node3D, spec: TableSpec, hole: TableLayout.Hole, y: float) -> void:
	var body := AnimatableBody3D.new()
	body.name = "Cover_" + String(hole.pocket_id)
	body.sync_to_physics = true
	body.collision_layer = LAYER_TABLE
	body.collision_mask = 0
	body.physics_material_override = _cloth_material(spec)
	body.position = Vector3(hole.center.x, y, hole.center.y)
	for ring in cover_rings(spec, hole):
		for k in COVER_SEGMENTS:
			var a0 := TAU * k / COVER_SEGMENTS
			var a1 := TAU * (k + 1) / COVER_SEGMENTS
			var d0 := Vector2.from_angle(a0)
			var d1 := Vector2.from_angle(a1)
			var pts := PackedVector3Array()
			for e in [[d0, ring.r_in, ring.top_in], [d1, ring.r_in, ring.top_in], [d1, ring.r_out, ring.top_out], [d0, ring.r_out, ring.top_out]]:
				var v: Vector2 = e[0] * float(e[1])
				pts.append(Vector3(v.x, -spec.bed_thickness_m, v.y))
				pts.append(Vector3(v.x, float(e[2]), v.y))
			var shape := ConvexPolygonShape3D.new()
			shape.points = pts
			var cs := CollisionShape3D.new()
			cs.shape = shape
			body.add_child(cs)
	parent.add_child(body)


## The cover's profile, shared by collider and mesh: [{r_in, r_out, top_in, top_out}], tops relative to the cloth.
static func cover_rings(spec: TableSpec, hole: TableLayout.Hole) -> Array[Dictionary]:
	var outer := hole.cup_radius + (hole.cup_radius - hole.radius) + COVER_OVERLAP_M
	return [
		{r_in = hole.radius, r_out = outer - COVER_BEVEL_M, top_in = COVER_LIFT_M, top_out = COVER_LIFT_M},
		{r_in = outer - COVER_BEVEL_M, r_out = outer, top_in = COVER_LIFT_M, top_out = 0.0002},
	]


## Every cup floor sits above this; anything that reaches here fell through a gap in the rail/bed
## coverage instead of a real pocket and should stop, not free-fall forever accelerating under gravity.
static func _build_safety_floor(parent: Node3D, spec: TableSpec, y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "SafetyFloor"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var chute_depth := spec.ball_radius_m * TableGeometry.DROP_CHUTE_RATIO
	# thick, not a thin slab: even CCD can miss a one-step-thin static shape at very high speed,
	# and a ball that reaches this point has already been falling uncaught for a while
	var thickness := spec.ball_radius_m * TableGeometry.DROP_CHUTE_RATIO
	box.size = Vector3((spec.length_m + spec.rail_width_m * 4.0), thickness, (spec.width_m + spec.rail_width_m * 4.0))
	shape.shape = box
	shape.position = Vector3(0, y - chute_depth - box.size.y * 0.5, 0)
	body.add_child(shape)
	parent.add_child(body)
