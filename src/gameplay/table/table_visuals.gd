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
## (`_tucked`), and the two halves of a side rail overlap across the pocket axis — so what a crack could show is always the dark
## rubber or liner, never the room. The checker is `src/tools/screenshot_table_seams.gd leaks=1 sweep=1 jitter=<mm>`
## (07 §2): 0 cracks over 94 views at jitter 0 / 1 / 2 / 4 mm.
##
## Pocket holes (06 P30): the cloth is the nose rectangle with every pocket's hole cut out of it (the same outline
## the bed collider is built from), and each hole is lined by a dark cup — floor, walls, and a back wall on the arc
## outside the nose rectangle. Moving Pockets adds a cloth-coloured cover ring per pocket, slid by table.gd.
##
## Pocket cut (adhoc-1013c W1, replaces the T3.2 picture-frame wrap): the rail wood is one continuous frame round the nose
## rectangle — every rail block and apron runs out to the table's outer footprint at a corner and, at a side pocket, on through
## the pocket to the other half (`_wood_extent`) — and each pocket is then *cut out of it* (`_wood_slab`): the same ring the
## liner stands on, grown by `_sink + CUT_GAP`, so the wood's cut wall is hidden behind the liner's. That leaves a real rail top
## round every pocket (the side pocket used to be an open notch behind its liner, the corner pocket's outer half capped by the
## apron top at cloth height) and nothing above or beside the pit but the liner and the jaws. `tests/physics/table_top_probe.gd`
## checks both: wood top everywhere outside the cuts, no wood or cloth over a pit.
##
## Normal maps: every part that carries one (felt, wood) gets tangents (`generate_tangents`) — a procedural mesh without them
## feeds the shader a degenerate tangent frame, which a phone GPU shades black with bright edges (07 §2 glare notes).

const CLOTH_COLOR := Color(0.05, 0.35, 0.15)
const CUSHION_COLOR := Color(0.03, 0.22, 0.10)
const RAIL_COLOR := Color(0.35, 0.20, 0.08)
const APRON_COLOR := Color(0.22, 0.12, 0.05)
const LEG_COLOR := Color(0.18, 0.10, 0.04)
const SIGHT_COLOR := Color(0.42, 0.38, 0.30)  # dim inlay: near-white sights under the lamp read as glints along the cushion gap (06 P32)
const LINER_COLOR := Color(0.12, 0.09, 0.07)

const SIGHT_SIZE_RATIO := 0.35       # sight marker size as a multiple of ball radius
const CUT_GAP := 0.002               # the wood's pocket cut stands this far behind the liner wall (hidden, never touching)
const EDGE_INSET := 0.0015           # a pocket ring never reaches the outer footprint: a sliver of wood stays outside it

## PBR sets (Poly Haven CC0, src/tools/make_textures.py): the felt's nap and the rails' wood grain. Both albedos are detail
## maps that multiply the part's colour (the felt's is bright, mean 0.9, so a BarSkin felt colour stays what it says).
const FELT_DIR := "res://assets/textures/felt/"
const WOOD_DIR := "res://assets/textures/wood/"
const FELT_TILE_M := 0.6   # metres per texture repeat
const WOOD_TILE_M := 1.2


static func build(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float, osc_m := 0.0) -> void:
	var cloth := _build_cloth(parent, spec, layout, y)
	var cuts := _wood_cuts(spec, layout)
	for rail in layout.rails:
		_build_cushion(parent, spec, rail, y)
		_build_rail_block(parent, spec, rail, y, cuts)
		_build_facing_visual(parent, spec, rail.a, rail.facing_a, rail.inward_normal, y)
		_build_facing_visual(parent, spec, rail.b, rail.facing_b, rail.inward_normal, y)
	for pos in layout.sights:
		_build_sight(parent, spec, pos, y)
	for pocket in layout.pockets:
		var hole: TableLayout.Hole = layout.holes[pocket.id]
		_build_pocket_liner(parent, spec, hole, y)
		if osc_m > 0.0:
			_build_cover_mesh(parent, spec, hole, cloth.material_override)
	_build_apron_and_legs(parent, spec, layout, y, cuts)
	_merge_by_material(parent)


## 07 §2: one MeshInstance3D per kind of part instead of one per rail/leg/sight/liner (63 -> 4 draw calls with the cloth):
## `Visual_wood` (rail blocks, apron, legs, plugs: wood PBR, per-part vertex colour), `Visual_dark` (cushion rubber and
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
		if part == &"wood":
			(groups[part] as SurfaceTool).generate_tangents()  # the wood PBR set has a normal map
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


## Where the apron's top starts, outward from the nose line: under the cushion wedge, never on the nose line itself. On the line its inner wall was
## coplanar with the wedge's sunk nose face, and its top (the cloth plane) with the cloth's tucked jaw-tip edge (06 P40 glare audit: same-facing,
## 0.00 mm apart, z-fighting under a GPU's depth rounding); half a cushion depth in is inside the rubber, where nothing can see it.
static func _apron_near(spec: TableSpec) -> float:
	return _cushion_depth(spec) * 0.5


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
	st.generate_tangents()  # the felt has a nap normal map
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


## Where a rail's wood runs (cushion and facings are the rail's own a/b): a corner-adjacent end is extended out to the table's
## outer footprint (the picture frame closing at 90°); a side-pocket-adjacent end runs on past the pocket axis by `_sink`, so
## the two halves overlap there and the pocket is cut out of one continuous rail (see the file header).
static func _wood_extent(spec: TableSpec, rail: TableLayout.RailSegment) -> Array:
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var rw := spec.rail_width_m
	var sink := _sink(spec)
	match rail.id:
		&"rail_w", &"rail_e":
			return [Vector3(rail.a.x, 0.0, -hw - rw), Vector3(rail.a.x, 0.0, hw + rw)]
		&"rail_n_w", &"rail_s_w":
			return [Vector3(-hl - rw, 0.0, rail.a.z), Vector3(sink, 0.0, rail.b.z)]
		&"rail_n_e", &"rail_s_e":
			return [Vector3(-sink, 0.0, rail.a.z), Vector3(hl + rw, 0.0, rail.b.z)]
		_:
			return [rail.a, rail.b]


static func _build_rail_block(parent: Node3D, spec: TableSpec, rail: TableLayout.RailSegment, y: float, cuts: Array[PackedVector2Array]) -> void:
	var depth0 := _cushion_depth(spec)
	if spec.rail_width_m - depth0 <= 0.0:
		return
	var ext := _wood_extent(spec, rail)
	var a: Vector3 = ext[0]
	var b: Vector3 = ext[1]
	var out := -rail.inward_normal
	_wood_slab(parent, "RailBlock_" + String(rail.id), _strip(a, b, out, depth0, spec.rail_width_m), cuts, y, y + spec.rail_height_m, RAIL_COLOR)
	# The block and the apron under it meet at one plane: a plug straddling it (`sink` each way, inset so none of its faces
	# is coplanar with theirs) keeps a hairline there from opening onto the room — it would show wood.
	var inset := _sink(spec) * 0.2
	var along := (b - a).normalized() * inset
	_wood_slab(parent, "RailPlug_" + String(rail.id), _strip(a + along, b - along, out, depth0 + inset, spec.rail_width_m - inset), cuts, y - _sink(spec) + inset, y + _sink(spec), RAIL_COLOR)


## Table-local xz rectangle along a rail from `a` to `b`, `near`..`far` metres outward (`out`) from the nose line.
static func _strip(a: Vector3, b: Vector3, out: Vector3, near: float, far: float) -> PackedVector2Array:
	var rect := PackedVector2Array()
	for e: Array in [[a, near], [b, near], [b, far], [a, far]]:
		var v: Vector3 = e[0] + out * float(e[1])
		rect.append(Vector2(v.x, v.z))
	return rect


## The pockets' cut polygons for the wood: each hole's ring `_sink + CUT_GAP` out, which stands just behind the liner wall.
static func _wood_cuts(spec: TableSpec, layout: TableLayout) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for hole: TableLayout.Hole in layout.holes.values():
		var cut := PackedVector2Array()
		for p in hole.ring:
			cut.append(_grown(spec, hole, p, _sink(spec) + CUT_GAP, EDGE_INSET))
		out.append(cut)
	return out


## One wood part: the footprint `rect` (table-local xz) minus every pocket cut, extruded from `y0` to `y1` (top, bottom and a
## wall on every edge, the cut's included, so a slit between wood and liner shows wood and never the room behind).
static func _wood_slab(parent: Node3D, node_name: String, rect: PackedVector2Array, cuts: Array[PackedVector2Array], y0: float, y1: float, color: Color) -> void:
	var pieces: Array[PackedVector2Array] = [rect]
	for cut in cuts:
		var next: Array[PackedVector2Array] = []
		for piece in pieces:
			next.append_array(Geometry2D.clip_polygons(piece, cut))
		pieces = next
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for poly in pieces:
		var tris := Geometry2D.triangulate_polygon(poly)
		if tris.is_empty():  # ear clipping gave up on a thin neck: fan the convex parts instead
			tris = _fan_convex(poly)
		for i in range(0, tris.size(), 3):
			var t := [poly[tris[i]], poly[tris[i + 1]], poly[tris[i + 2]]]
			_facing_tri(st, _at(t[0], y1), _at(t[1], y1), _at(t[2], y1), Vector3.UP)
			_facing_tri(st, _at(t[0], y0), _at(t[1], y0), _at(t[2], y0), Vector3.DOWN)
		var area2 := 0.0
		for i in poly.size():
			var q := poly[(i + 1) % poly.size()]
			area2 += poly[i].x * q.y - q.x * poly[i].y
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var d := b - a
			if d.length() < 1e-5:
				continue
			var n2 := Vector2(d.y, -d.x).normalized() * (1.0 if area2 > 0.0 else -1.0)  # out of the wood, whichever way round it winds
			var n := Vector3(n2.x, 0.0, n2.y)
			_facing_tri(st, _at(a, y0), _at(b, y0), _at(b, y1), n)
			_facing_tri(st, _at(a, y0), _at(b, y1), _at(a, y1), n)
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = st.commit()
	mesh.material_override = _material(color)
	parent.add_child(mesh)


## Indices (into `poly`, three per triangle) of a fan over each convex piece of `poly`; the fallback when ear clipping fails.
static func _fan_convex(poly: PackedVector2Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for piece in Geometry2D.decompose_polygon_in_convex(poly):
		var ids := PackedInt32Array()
		for p in piece:
			ids.append(poly.find(p))
		for k in range(1, ids.size() - 1):
			out.append_array(PackedInt32Array([ids[0], ids[k], ids[k + 1]]))
	return out


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
	var zb := z
	if x.dot(inward) > 0.0:
		x = -x
		zb = -z  # (x, UP, zb) stays right-handed: a mirrored basis flips the winding, so under cull_back the wedge showed its back faces (06 P40)
	var facing := MeshInstance3D.new()
	facing.name = "Facing"
	facing.mesh = _wedge_mesh(depth, h, length, _sink(spec))
	facing.material_override = _material(CUSHION_COLOR)
	# Same outward shift as the collider (table_builder.gd): inner face flush with the nose line,
	# fused to the cushion end instead of straddling it with a visible gap or overlap. The wedge's
	# own nose face is at local X=0 (same convention `_build_cushion` uses), so this anchor lines
	# up with the cushion's own X=0 face with no extra offset.
	facing.transform = Transform3D(Basis(x, Vector3.UP, zb), at + z * length * 0.5 + Vector3(0, y, 0))
	parent.add_child(facing)


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
		ring.append(_grown(spec, hole, p, grow, EDGE_INSET + CUT_GAP))
	for i in ring.size():
		_wall_quad(st, ring[i], ring[(i + 1) % ring.size()], hole.center, floor_y, top)
		_facing_tri(st, _at(hole.center, floor_y), _at(ring[i], floor_y), _at(ring[(i + 1) % ring.size()], floor_y), Vector3.UP)
	for i in hole.outer.size() - 1:
		# starts well under the ring wall's top: outside the nose rectangle there is no cloth rim wall, so a back wall that
		# began at the cloth plane left a `bed_thickness_m` slit round the pocket's rear showing the room behind it
		_wall_quad(st, _grown(spec, hole, hole.outer[i], grow, EDGE_INSET + CUT_GAP), _grown(spec, hole, hole.outer[i + 1], grow, EDGE_INSET + CUT_GAP), hole.center, y - spec.bed_thickness_m * 1.5, y + spec.rail_height_m)
	var mesh := MeshInstance3D.new()
	mesh.name = "Liner_" + String(hole.pocket_id)
	mesh.mesh = st.commit()
	var mat := _material(LINER_COLOR)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	parent.add_child(mesh)


## `p` moved `by` away from the hole's axis, but never past `inset` short of the table's outer footprint: a corner pocket's ring
## would otherwise reach (and poke through) the rail's outer face at its two extreme points.
static func _grown(spec: TableSpec, hole: TableLayout.Hole, p: Vector2, by: float, inset: float) -> Vector2:
	var q := p + (p - hole.center).normalized() * by
	var lim := Vector2(spec.length_m * 0.5 + spec.rail_width_m, spec.width_m * 0.5 + spec.rail_width_m) - Vector2(inset, inset)
	return Vector2(clampf(q.x, -lim.x, lim.x), clampf(q.y, -lim.y, lim.y))


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
	st.generate_tangents()  # shares the felt material, normal map included
	var mesh := MeshInstance3D.new()
	mesh.name = "CoverMesh"
	mesh.mesh = st.commit()
	mesh.material_override = cloth_material
	body.add_child(mesh)


static func _build_apron_and_legs(parent: Node3D, spec: TableSpec, layout: TableLayout, y: float, cuts: Array[PackedVector2Array]) -> void:
	for rail in layout.rails:
		# Same extent as the rail block (`_wood_extent`): the corner turns and the side pocket's two halves meet (gamma F2, 05b)
		var ext := _wood_extent(spec, rail)
		_wood_slab(parent, "Apron_" + String(rail.id), _strip(ext[0], ext[1], -rail.inward_normal, _apron_near(spec), spec.rail_width_m), cuts, y - spec.apron_h_m, y, APRON_COLOR)

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
