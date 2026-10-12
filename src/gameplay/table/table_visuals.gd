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
## No seam is an edge-to-edge contact (06 P32): two meshes that merely touch can open a hairline under a phone GPU's
## rounding and show the lit room behind the table as a bright line. Every abutting visual is sunk `_sink` (half the
## slab) into its neighbour instead — the cushion wedge and the facing stubs run below the cloth plane and carry their
## slope on into the rail block, a plug ties each rail block to the apron under it, a leg runs up into its apron, the
## liner walls stand a full `_sink` behind the cloth's own rim wall (so a mesh a few mm off cannot slide in front of it
## and open a slot between the two), the cloth's top edge and rim wall run on into the cushion at each jaw tip
## (`_tucked`), and a side pocket's block ends run on into the pocket — so what a crack could show is always the dark
## rubber or liner, never the room. The checker is `src/tools/screenshot_table_seams.gd leaks=1 sweep=1 jitter=<mm>`
## (07 §2): 0 cracks over 94 views at jitter 0 / 1 / 2 / 4 mm.
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
## mouth boundary), only a block end that runs `_sink` on into the pocket, so the pocket's back wall crosses that end
## face at a real angle and not along its corner edge; `_build_side_horn` caps each of those four rail ends with a short wood nub
## along the same facing direction as the rubber jaw stub, so the flat end-cap face doesn't
## read as the plank "just stopping".

const CLOTH_COLOR := Color(0.05, 0.35, 0.15)
const CUSHION_COLOR := Color(0.03, 0.22, 0.10)
const RAIL_COLOR := Color(0.35, 0.20, 0.08)
const APRON_COLOR := Color(0.22, 0.12, 0.05)
const LEG_COLOR := Color(0.18, 0.10, 0.04)
const SIGHT_COLOR := Color(0.42, 0.38, 0.30)  # dim inlay: near-white sights under the lamp read as glints along the cushion gap (06 P32)
const LINER_COLOR := Color(0.12, 0.09, 0.07)

const SIGHT_SIZE_RATIO := 0.35       # sight marker size as a multiple of ball radius

## PBR sets (Poly Haven CC0, src/tools/make_textures.py): the felt's nap and the rails' wood grain. Both albedos are detail
## maps that multiply the part's colour (the felt's is bright, mean 0.9, so a BarSkin felt colour stays what it says).
const FELT_DIR := "res://assets/textures/felt/"
const WOOD_DIR := "res://assets/textures/wood/"
const FELT_TILE_M := 0.6   # metres per texture repeat
const WOOD_TILE_M := 1.2


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


## 07 §2: one MeshInstance3D per kind of part instead of one per rail/leg/sight/liner (63 -> 4 draw calls with the cloth):
## `Visual_wood` (rail blocks, apron, legs, horns, plugs: wood PBR, per-part vertex colour), `Visual_dark` (cushion rubber and
## sights: matte flat colour) and `Visual_liner` (the pockets' double-sided cups). Runs last, over the meshes built above;
## children are table-local so their own transforms carry over.
static func _merge_by_material(parent: Node3D) -> void:
	var groups: Dictionary = {}  # part -> SurfaceTool
	var merged: Array[MeshInstance3D] = []
	for c in parent.get_children():
		var mi := c as MeshInstance3D
		if mi == null or not mi.material_override is StandardMaterial3D or mi.name == &"Cloth":
			continue  # the cloth keeps its node so a skin can recolour it
		var color := (mi.material_override as StandardMaterial3D).albedo_color
		var part := _part_of(color)
		if not groups.has(part):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[part] = st
		_append_part(groups[part], mi.mesh, mi.transform, color)
		merged.append(mi)
	for mi in merged:
		parent.remove_child(mi)
		mi.free()
	for part: StringName in groups:
		var out := MeshInstance3D.new()
		out.name = "Visual_" + part
		out.mesh = (groups[part] as SurfaceTool).commit()
		match part:
			&"wood":
				out.material_override = _wood_material()
			&"liner":
				var m := _material(Color.WHITE)
				m.vertex_color_use_as_albedo = true
				m.vertex_color_is_srgb = true
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
				out.material_override = m
			_:
				var m := _material(Color.WHITE)
				m.vertex_color_use_as_albedo = true
				m.vertex_color_is_srgb = true
				out.material_override = m
		parent.add_child(out)


static func _part_of(color: Color) -> StringName:
	if color in [RAIL_COLOR, APRON_COLOR, LEG_COLOR]:
		return &"wood"
	return &"liner" if color == LINER_COLOR else &"dark"


## `mesh` through `xf` into `st`, every vertex `color`; wood parts are box-mapped (table-local metres) for the grain.
static func _append_part(st: SurfaceTool, mesh: Mesh, xf: Transform3D, color: Color) -> void:
	var a := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var order: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(v.size()))
	for i in order:
		var p := xf * v[i]
		var n := (xf.basis * nrm[i]).normalized()
		st.set_color(color)
		st.set_normal(n)
		st.set_uv(_uv(p, n, WOOD_TILE_M))
		st.add_vertex(p)


## Planar UV on the face's dominant axis, in repeats of `tile` metres (v runs down so grain stays level).
static func _uv(p: Vector3, n: Vector3, tile: float) -> Vector2:
	var a := n.abs()
	if a.y >= a.x and a.y >= a.z:
		return Vector2(p.x, p.z) / tile
	if a.x >= a.z:
		return Vector2(p.z, -p.y) / tile
	return Vector2(p.x, -p.y) / tile


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


## Felt: albedo detail + nap normal on the cloth colour. Still a StandardMaterial3D, its `albedo_color` is the felt colour.
static func _cloth_material() -> StandardMaterial3D:
	var m := _material(CLOTH_COLOR)
	m.albedo_texture = load(FELT_DIR + "albedo.webp")
	m.normal_enabled = true
	m.normal_texture = load(FELT_DIR + "normal.png")
	return m


## Rails, apron, legs: one wood PBR material, each part's colour in its vertex colour.
static func _wood_material() -> ORMMaterial3D:
	var m := ORMMaterial3D.new()
	m.albedo_texture = load(WOOD_DIR + "albedo.webp")
	m.orm_texture = load(WOOD_DIR + "orm.webp")
	m.ao_enabled = true
	m.normal_enabled = true
	m.normal_texture = load(WOOD_DIR + "normal.png")
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.metallic_specular = 0.15  # see `_material`: the lamp's white lobe is a glare, keep the wood's sheen low
	return m


static func _cushion_depth(spec: TableSpec) -> float:
	return spec.ball_radius_m * 2.0  # must match table_builder.gd's cushion collider depth


## How far a visual runs into the piece it abuts (see the file header).
static func _sink(spec: TableSpec) -> float:
	return spec.bed_thickness_m * 0.5


## Cloth top = the bed outline triangulated at cloth height; each hole gets a rim wall `bed_thickness_m` deep so
## the cut reads as cloth over slate, not a paper-thin sheet.
static func _build_cloth(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tucked := {}  # tip vertex -> where the cloth really ends, run on into the cushion
	for hole: TableLayout.Hole in layout.holes.values():
		var arc := _tucked(spec, hole.inner)
		tucked[hole.inner[0]] = arc[0]
		tucked[hole.inner[hole.inner.size() - 1]] = arc[arc.size() - 1]
		for i in arc.size() - 1:
			_wall_quad(st, arc[i], arc[i + 1], hole.center, y - spec.bed_thickness_m, y)
	var outline := PackedVector2Array()
	for p in layout.bed_outline:
		outline.append(tucked.get(p, p))
	var idx := Geometry2D.triangulate_polygon(outline)
	for i in range(0, idx.size(), 3):
		_facing_tri(st, _at(outline[idx[i]], y), _at(outline[idx[i + 1]], y), _at(outline[idx[i + 2]], y), Vector3.UP)
	var mesh := MeshInstance3D.new()
	mesh.name = "Cloth"
	mesh.mesh = st.commit()
	mesh.material_override = _cloth_material()
	parent.add_child(mesh)
	return mesh


## `arc` with each end moved on past its nose-line point along the end chord, `2 x bed_thickness_m` further: that is into the
## cushion body, so the cloth's top edge and rim wall end deep inside the rubber instead of on the tip's one vertical line
## where cloth, cushion, facing and apron all meet (06 P32: a phone-GPU hairline there showed the room at the jaw tips).
## The end is replaced, not added to: the wall's top edge must stay the very edge the top triangles share (a vertex on the
## middle of that edge is a T-junction, a pinhole in the cloth).
static func _tucked(spec: TableSpec, arc: PackedVector2Array) -> PackedVector2Array:
	var n := arc.size()
	var by := spec.bed_thickness_m * 2.0
	var out := arc.duplicate()
	out[0] = arc[0] + (arc[0] - arc[1]).normalized() * by
	out[n - 1] = arc[n - 1] + (arc[n - 1] - arc[n - 2]).normalized() * by
	return out


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
		st.set_uv(_uv(v, normal, FELT_TILE_M))
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
	mesh.mesh = _wedge_mesh(_cushion_depth(spec), spec.cushion_nose_h_m, rail.a.distance_to(rail.b), _sink(spec))
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
	# A side pocket's block end runs `_sink` on into the pocket (see the header): the pocket's back wall then crosses the
	# end face at a real angle, where meeting the block's corner edge tangentially left a throat a jittered mesh opened.
	var run := (rail.b - rail.a).normalized() * _sink(spec)
	match rail.id:
		&"rail_n_w", &"rail_s_w":
			b += run
		&"rail_n_e", &"rail_s_e":
			a -= run
	var mesh := MeshInstance3D.new()
	mesh.name = "RailBlock_" + String(rail.id)
	var box := BoxMesh.new()
	box.size = Vector3(width, spec.rail_height_m, a.distance_to(b))
	mesh.mesh = box
	mesh.material_override = _material(RAIL_COLOR)
	var mid := (a + b) * 0.5
	var basis := TableGeometry.rail_basis(rail)
	# local +X centre sits at depth0 + width/2, local +Y centre at rail_height_m/2 (block rests on cloth)
	var at := mid - rail.inward_normal * (depth0 + width * 0.5)
	mesh.transform = Transform3D(basis, at + Vector3(0, y + spec.rail_height_m * 0.5, 0))
	parent.add_child(mesh)
	# The block and the apron under it meet at one plane: a plug straddling it (`sink` each way, inset so none of its faces
	# is coplanar with theirs) keeps a hairline there from opening onto the room — it would show wood.
	var inset := _sink(spec) * 0.2
	var plug := MeshInstance3D.new()
	plug.name = "RailPlug_" + String(rail.id)
	var pbox := BoxMesh.new()
	pbox.size = Vector3(width - 2.0 * inset, _sink(spec) * 2.0, a.distance_to(b) - 2.0 * inset)
	plug.mesh = pbox
	plug.material_override = mesh.material_override
	plug.transform = Transform3D(basis, at + Vector3(0, y, 0))
	parent.add_child(plug)


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
	facing.mesh = _wedge_mesh(depth, h, length, _sink(spec))
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
## Double-sided and unlit by the room's baked light: it is a pit, it should read as one. The ring stands `_sink`
## outside the cloth's own rim wall and reaches up to `_sink` under the cloth plane, so the cloth sheet overhangs it: the join
## is hidden (two coplanar walls z-fight cloth/dark), and no mesh a few mm off can bring the ring in front of the rim wall,
## which would leave a slot between the two for a sight line to run down and out under the cloth.
static func _build_pocket_liner(parent: Node3D, spec: TableSpec, hole: TableLayout.Hole, y: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var floor_y := y - spec.cup_depth_m
	var grow := _sink(spec)
	var top := y - grow
	var ring := PackedVector2Array()
	for p in hole.ring:
		ring.append(_grown(hole, p, grow))
	for i in ring.size():
		_wall_quad(st, ring[i], ring[(i + 1) % ring.size()], hole.center, floor_y, top)
		_facing_tri(st, _at(hole.center, floor_y), _at(ring[i], floor_y), _at(ring[(i + 1) % ring.size()], floor_y), Vector3.UP)
	for i in hole.outer.size() - 1:
		# starts well under the ring wall's top: outside the nose rectangle there is no cloth rim wall, so a back wall that
		# began at the cloth plane left a `bed_thickness_m` slit round the pocket's rear showing the room behind it
		_wall_quad(st, _grown(hole, hole.outer[i], grow), _grown(hole, hole.outer[i + 1], grow), hole.center, y - spec.bed_thickness_m * 1.5, y + spec.rail_height_m)
	var mesh := MeshInstance3D.new()
	mesh.name = "Liner_" + String(hole.pocket_id)
	mesh.mesh = st.commit()
	var mat := _material(LINER_COLOR)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	parent.add_child(mesh)


## `p` moved `by` away from the hole's axis.
static func _grown(hole: TableLayout.Hole, p: Vector2, by: float) -> Vector2:
	return p + (p - hole.center).normalized() * by


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


## The wedge runs `sink` below the cloth plane and its slope carries on down to there, so it crosses the cloth edge and the
## rail block face instead of touching them at an edge (the part under the plane is inside the rail block).
static func _wedge_mesh(depth: float, height: float, length: float, sink: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hz := length * 0.5
	var reach := depth * (height + sink) / height  # where the slope line through (depth, 0) meets the sunk base
	var p0 := Vector3(0.0, -sink, -hz)   # nose base
	var p1 := Vector3(0.0, height, -hz)  # nose tip (ball contact face is p0-p1)
	var p2 := Vector3(reach, -sink, -hz)   # outward base, inside the rail block
	var q0 := Vector3(0.0, -sink, hz)
	var q1 := Vector3(0.0, height, hz)
	var q2 := Vector3(reach, -sink, hz)
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
