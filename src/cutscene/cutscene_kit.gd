class_name CutsceneKit
extends RefCounted
## Procedural-geometry helpers the cutscenes share (docs/plan/09 §4.4). A `Soup` merges many vertex-coloured boxes, cylinders and
## cones into ONE mesh = one draw call; the rest is plain materials, a night Environment and light makers. No scene state.

const TEXTURE_DIR := "res://assets/textures/%s/albedo.webp"  ## the CC0 detail maps (assets/textures/SOURCE.md)

static var _vertex_material: StandardMaterial3D


## Vertex-coloured solids merged into one mesh. `xf` (rotation + translation only) is applied to whatever is added next. Triangles go
## straight into packed arrays (adhoc-1014b C8: a SurfaceTool call per vertex, a GDScript call per triangle and a transform per corner per
## triangle were the build). Every solid has a general path (list the triangles, `_emit` winds each toward its normal and drops slivers) and,
## for the well-conditioned solids that are nearly all of them, a fast one that knows the result: a rotation keeps a solid's winding, and a
## solid that no sliver can come from keeps every triangle. The arrays equal the old SurfaceTool builder's, bit for bit, whichever path
## ran (tests/cutscene/soup_probe.gd fuzzes both against it).
class Soup extends RefCounted:
	const CAP_BOTTOM := 1
	const CAP_TOP := 2
	const BOX_FACES := [[0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6], [0, 1, 3, 2], [4, 5, 7, 6]]
	const BOX_NORMALS: Array[Vector3] = [Vector3.LEFT, Vector3.RIGHT, Vector3.DOWN, Vector3.UP, Vector3.FORWARD, Vector3.BACK]
	const SLIVER_SQ := 0.0000001  ## a triangle whose cross product is shorter than sqrt of this is dropped
	const SAFE_CROSS := 0.001  ## the fast paths need every triangle's cross product at least this long: 3x the drop threshold

	static var _box_unit := PackedVector3Array()  ## a box's 36 vertices on the +-1 cube, wound, in the order the general path writes them
	static var _box_axes := PackedVector3Array()  ## ... and their 36 normals (+-axes) before `xf`, six to a face
	static var _rings: Array = []  ## by sides: [the unit ring (sides + 1 points: the last is not the first, cos / sin of TAU, as one segment at a time had it), 2 sin(pi / sides), cos(pi / sides)]

	var xf := Transform3D.IDENTITY:
		set(v):
			xf = v
			_rot_ok = absf(v.basis.determinant() - 1.0) < 0.001
	var _rot_ok := true  # xf is a rotation and a translation, as the fast paths need
	var _pos := PackedVector3Array()
	var _nrm := PackedVector3Array()
	var _col := PackedColorArray()
	var _n := 0
	var _tris := 0

	func triangles() -> int:
		return _tris

	## One triangle with outward normal `n`, wound the way Godot front-faces it (clockwise seen from outside) whatever the order given.
	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
		_emit(PackedVector3Array([xf * a, xf * b, xf * c]), PackedVector3Array([(xf.basis * n).normalized()]), col)

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
		var pa := xf * a
		var pc := xf * c
		var nn := (xf.basis * n).normalized()
		_emit(PackedVector3Array([pa, xf * b, pc, pa, pc, xf * d]), PackedVector3Array([nn, nn]), col)

	func box(centre: Vector3, half: Vector3, col: Color) -> void:
		if _box_unit.is_empty():
			var unit := Soup.new()
			unit._box_general(Vector3.ZERO, Vector3.ONE, Color.WHITE)
			_box_unit = unit._pos
			_box_axes = unit._nrm
		if _rot_ok and minf(minf(half.x * half.y, half.y * half.z), half.x * half.z) >= 0.25 * SAFE_CROSS and minf(minf(half.x, half.y), half.z) > 0.0:
			# every face is a rectangle of cross product 4ab: none is a sliver, and a rotation keeps the unit box's winding
			# `centre + (+-half)`, then `xf`: the same two float operations per corner as one at a time, but in bulk
			_pos.append_array(xf * (Transform3D(Basis.from_scale(half), centre) * _box_unit))
			# a face's normal is +-xf's column, normalized: the unit box's 36 normals (+-axes) through the matrix of the three normalized columns
			var cx := (xf.basis * Vector3.RIGHT).normalized()
			var cy := (xf.basis * Vector3.UP).normalized()
			var cz := (xf.basis * Vector3.BACK).normalized()
			_nrm.append_array(Transform3D(Basis(cx, cy, cz), Vector3.ZERO) * _box_axes)
			_fill(36, col)
			_tris += 12
		else:
			_box_general(centre, half, col)

	func _box_general(centre: Vector3, half: Vector3, col: Color) -> void:
		var p: Array[Vector3] = []
		for n in 8:
			p.append(xf * (centre + Vector3(half.x if n & 1 else -half.x, half.y if n & 2 else -half.y, half.z if n & 4 else -half.z)))
		var tp := PackedVector3Array()
		var tn := PackedVector3Array()
		for f in 6:
			var idx: Array = BOX_FACES[f]
			var nn := (xf.basis * BOX_NORMALS[f]).normalized()
			for k in [0, 1, 2, 0, 2, 3]:
				tp.append(p[idx[k]])
			tn.append(nn)
			tn.append(nn)
		_emit(tp, tn, col)

	## Vertical frustum from `base` up by `h`; elliptical radii (x, z) at the bottom and the top; r1 = 0 is a cone.
	func cyl(base: Vector3, h: float, r0: Vector2, r1: Vector2, sides: int, col: Color, caps := CAP_BOTTOM | CAP_TOP) -> void:
		var top := base + Vector3(0.0, h, 0.0)
		var slope := Vector3.UP * ((r0.x + r0.y - r1.x - r1.y) * 0.5)
		var bottom := caps & CAP_BOTTOM != 0
		var lid := caps & CAP_TOP != 0 and r1.x > 0.0
		var pbase := xf * base if bottom else Vector3.ZERO
		var ptop := xf * top if lid else Vector3.ZERO
		var n_down := (xf.basis * Vector3.DOWN).normalized() if bottom else Vector3.ZERO
		var n_up := (xf.basis * Vector3.UP).normalized() if lid else Vector3.ZERO
		var info := _ring(sides)
		var dir: PackedVector3Array = info[0]
		# `base + (d.x * r0.x, 0, d.z * r0.y)`: the same float operations per point as one at a time, but in bulk
		var rb: PackedVector3Array = xf * (Transform3D(Basis.from_scale(Vector3(r0.x, 1.0, r0.y)), base) * dir)
		var rt: PackedVector3Array = xf * (Transform3D(Basis.from_scale(Vector3(r1.x, 1.0, r1.y)), top) * dir)
		var hh := maxf(h, 0.001)
		var cone := r1.x == 0.0 and r1.y == 0.0  # its upper triangle is a point: always dropped
		# The fast path needs a solid no triangle of which can be a sliver, and a rotation to keep the winding of each kind of triangle: a side's
		# lower one (b0 b1 t1) is a base `chord_b` over a height of at least `h`, its upper one (b0 t1 t0) a base `chord_t` over at least `h`, a
		# cap's one a chord over the inradius (an ellipse's polygon contains the circle of its short radius times cos(pi / sides)). Every segment is
		# wound like the first only while the two ends are alike: each ring nearly round (long radius at most 1.5x the short one), both stretched
		# the same way.
		var b := minf(r0.x, r0.y)
		var t := minf(r1.x, r1.y)
		var chord: float = info[1]
		var inner: float = info[2]
		if _rot_ok and sides >= 3 and h > 0.0 and b > 0.0 and (t > 0.0 or cone) and maxf(r0.x, r0.y) <= 1.5 * b \
				and (cone or (maxf(r1.x, r1.y) <= 1.5 * t and (r0.x - r0.y) * (r1.x - r1.y) >= 0.0)) \
				and chord * b * h >= SAFE_CROSS and (cone or chord * t * h >= SAFE_CROSS) \
				and (not bottom or chord * b * b * inner >= SAFE_CROSS) and (not lid or chord * t * t * inner >= SAFE_CROSS):
			_cyl_fast(sides, dir, rb, rt, pbase, ptop, n_down, n_up, r0, slope, hh, bottom, lid, cone, col)
			return
		var tp := PackedVector3Array()
		var tn := PackedVector3Array()
		for n in sides:
			var b0 := rb[n]
			var b1 := rb[n + 1]
			var t0 := rt[n]
			var t1 := rt[n + 1]
			var mid := (dir[n] + dir[n + 1]).normalized()
			var nm := (xf.basis * (Vector3(mid.x * r0.y, 0.0, mid.z * r0.x).normalized() * hh + slope).normalized()).normalized()
			tp.append(b0)
			tp.append(b1)
			tp.append(t1)
			tp.append(b0)
			tp.append(t1)
			tp.append(t0)
			tn.append(nm)
			tn.append(nm)
			if bottom:
				tp.append(pbase)
				tp.append(b1)
				tp.append(b0)
				tn.append(n_down)
			if lid:
				tp.append(ptop)
				tp.append(t0)
				tp.append(t1)
				tn.append(n_up)
		_emit(tp, tn, col)

	func _cyl_fast(sides: int, dir: PackedVector3Array, rb: PackedVector3Array, rt: PackedVector3Array, pbase: Vector3, ptop: Vector3, n_down: Vector3, n_up: Vector3, r0: Vector2, slope: Vector3, hh: float, bottom: bool, lid: bool, cone: bool, col: Color) -> void:
		var per := 1 if cone else 2  # side triangles per segment
		if bottom:
			per += 1
		if lid:
			per += 1
		var pos := PackedVector3Array()
		var nrm := PackedVector3Array()
		pos.resize(sides * per * 3)
		nrm.resize(sides * per * 3)
		var flip_a := false  # which way each kind of triangle is wound: decided on the first segment exactly as the general path decides it
		var flip_b := false
		var flip_d := false
		var flip_u := false
		var i := 0
		for n in sides:
			var b0 := rb[n]
			var b1 := rb[n + 1]
			var t1 := rt[n + 1]
			var mid := (dir[n] + dir[n + 1]).normalized()
			var nm := (xf.basis * (Vector3(mid.x * r0.y, 0.0, mid.z * r0.x).normalized() * hh + slope).normalized()).normalized()
			if n == 0:
				flip_a = (b1 - b0).cross(t1 - b0).dot(nm) > 0.0
				flip_b = (t1 - b0).cross(rt[0] - b0).dot(nm) > 0.0
				flip_d = (b1 - pbase).cross(b0 - pbase).dot(n_down) > 0.0
				flip_u = (rt[0] - ptop).cross(t1 - ptop).dot(n_up) > 0.0
			pos[i] = b0
			pos[i + 1] = t1 if flip_a else b1
			pos[i + 2] = b1 if flip_a else t1
			nrm[i] = nm
			nrm[i + 1] = nm
			nrm[i + 2] = nm
			i += 3
			if not cone:
				var t0 := rt[n]
				pos[i] = b0
				pos[i + 1] = t0 if flip_b else t1
				pos[i + 2] = t1 if flip_b else t0
				nrm[i] = nm
				nrm[i + 1] = nm
				nrm[i + 2] = nm
				i += 3
			if bottom:
				pos[i] = pbase
				pos[i + 1] = b0 if flip_d else b1
				pos[i + 2] = b1 if flip_d else b0
				nrm[i] = n_down
				nrm[i + 1] = n_down
				nrm[i + 2] = n_down
				i += 3
			if lid:
				var t0 := rt[n]
				pos[i] = ptop
				pos[i + 1] = t1 if flip_u else t0
				pos[i + 2] = t0 if flip_u else t1
				nrm[i] = n_up
				nrm[i + 1] = n_up
				nrm[i + 2] = n_up
				i += 3
		_pos.append_array(pos)
		_nrm.append_array(nrm)
		_fill(i, col)
		_tris += i / 3

	static func _ring(sides: int) -> Array:
		if sides >= _rings.size():
			_rings.resize(sides + 1)
		if _rings[sides] == null:
			var ring := PackedVector3Array()
			for n in sides + 1:
				var a := TAU * n / sides
				ring.append(Vector3(cos(a), 0.0, sin(a)))
			_rings[sides] = [ring, 2.0 * sin(PI / sides), cos(PI / sides)]
		return _rings[sides]

	## Ellipsoid, smooth normals.
	func ball(centre: Vector3, radii: Vector3, seg: int, rings: int, col: Color) -> void:
		var raw: Array[Vector3] = []  # the unit sphere's normals, before `radii` and `xf`: they pick each triangle's winding
		var pts: Array[Vector3] = []
		var nrm: Array[Vector3] = []
		for r in rings + 1:
			var phi := PI * r / rings
			for s in seg:
				var th := TAU * s / seg
				var v := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
				raw.append((v / radii).normalized())
				pts.append(xf * (centre + v * radii))
				nrm.append((xf.basis * raw[-1]).normalized())
		var pos := PackedVector3Array()
		var nrm_out := PackedVector3Array()
		for r in rings:
			for s in seg:
				var s2 := (s + 1) % seg
				var i0 := r * seg + s
				var i1 := r * seg + s2
				var i2 := (r + 1) * seg + s2
				var i3 := (r + 1) * seg + s
				if r > 0:
					_smooth_tri(pos, nrm_out, pts[i0], pts[i1], pts[i2], nrm[i0], nrm[i1], nrm[i2], raw[i0] + raw[i1] + raw[i2])
				if r < rings - 1:
					_smooth_tri(pos, nrm_out, pts[i0], pts[i2], pts[i3], nrm[i0], nrm[i2], nrm[i3], raw[i0] + raw[i2] + raw[i3])
		_pos.append_array(pos)
		_nrm.append_array(nrm_out)
		_fill(pos.size(), col)
		_tris += pos.size() / 3

	## The merged mesh (null material = the shared vertex-colour one).
	func mesh(material: Material = null) -> ArrayMesh:
		var m := ArrayMesh.new()
		if _n == 0:
			return m
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = _pos
		arrays[Mesh.ARRAY_NORMAL] = _nrm
		arrays[Mesh.ARRAY_COLOR] = _col
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		m.surface_set_material(0, material if material != null else CutsceneKit.vertex_material())
		return m

	# `n` more vertices were appended to _pos and _nrm: give them `col`.
	func _fill(n: int, col: Color) -> void:
		var run := PackedColorArray()
		run.resize(n)
		run.fill(col)
		_col.append_array(run)
		_n += n

	# Triangle j is points 3j..3j+2 of `tp` (already in the soup's space) with unit normal `tn[j]`: each is wound so `tn[j]` is its front
	# and a sliver is dropped; the rest go into the arrays in order.
	func _emit(tp: PackedVector3Array, tn: PackedVector3Array, col: Color) -> void:
		var count := tn.size()
		var pos := PackedVector3Array()
		var nrm := PackedVector3Array()
		pos.resize(3 * count)
		nrm.resize(3 * count)
		var i := 0
		var q := 0
		for j in count:
			var pa := tp[q]
			var pb := tp[q + 1]
			var pc := tp[q + 2]
			q += 3
			var cross := (pb - pa).cross(pc - pa)
			if cross.length_squared() < SLIVER_SQ:
				continue
			var nn := tn[j]
			pos[i] = pa
			if cross.dot(nn) > 0.0:
				pos[i + 1] = pc
				pos[i + 2] = pb
			else:
				pos[i + 1] = pb
				pos[i + 2] = pc
			nrm[i] = nn
			nrm[i + 1] = nn
			nrm[i + 2] = nn
			i += 3
		if i == 0:
			return
		if i < pos.size():
			pos.resize(i)
			nrm.resize(i)
		_pos.append_array(pos)
		_nrm.append_array(nrm)
		_fill(i, col)
		_tris += i / 3

	# One smooth-shaded triangle into `pos` / `nrm`; `sum` (the three grid normals added, before `xf`) says which way is out.
	func _smooth_tri(pos: PackedVector3Array, nrm: PackedVector3Array, pa: Vector3, pb: Vector3, pc: Vector3, na: Vector3, nb: Vector3, nc: Vector3, sum: Vector3) -> void:
		var cross := (pb - pa).cross(pc - pa)
		if cross.length_squared() < SLIVER_SQ:
			return
		pos.append(pa)
		nrm.append(na)
		if cross.dot(xf.basis * sum) > 0.0:
			pos.append(pc)
			pos.append(pb)
			nrm.append(nc)
			nrm.append(nb)
		else:
			pos.append(pb)
			pos.append(pc)
			nrm.append(nb)
			nrm.append(nc)


# --- materials ------------------------------------------------------------------------------------------------------------------

## sRGB vertex colours, rough, lit: the material of every Soup that has no texture.
static func vertex_material() -> StandardMaterial3D:
	if _vertex_material == null:
		_vertex_material = StandardMaterial3D.new()
		_vertex_material.vertex_color_use_as_albedo = true
		_vertex_material.vertex_color_is_srgb = true
		_vertex_material.roughness = 0.9
	return _vertex_material


## A CC0 detail map (`assets/textures/<set_name>/albedo.webp`) mapped by world-sized tiles (no UVs needed, triplanar in the object's
## space), multiplied by the Soup's vertex colours and `tint`. `tile_m` = the metres one texture repeat covers.
static func textured(set_name: String, tint: Color, tile_m: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(TEXTURE_DIR % set_name) as Texture2D
	m.albedo_color = tint
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.uv1_triplanar = true
	m.uv1_scale = Vector3.ONE / tile_m
	m.roughness = 0.85
	return m


## A flat self-lit colour (lamps, windows, the moon); `energy` > 1 blooms nothing here (no glow) but reads bright against the night.
static func glow(col: Color, energy := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(col.r * energy, col.g * energy, col.b * energy, col.a)
	m.disable_fog = true
	return m


# --- nodes ----------------------------------------------------------------------------------------------------------------------

static func add_mesh(parent: Node3D, mesh: Mesh, pos := Vector3.ZERO, material: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if material != null:
		mi.material_override = material
	parent.add_child(mi)
	return mi


static func omni(parent: Node3D, pos: Vector3, col: Color, energy: float, range_m: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = col
	l.light_energy = energy
	l.omni_range = range_m
	l.shadow_enabled = false
	parent.add_child(l)
	return l


## A spot at `pos` shining at `target` (both in `parent`'s space).
static func spot(parent: Node3D, pos: Vector3, target: Vector3, col: Color, energy: float, range_m: float, angle_deg: float) -> SpotLight3D:
	var l := SpotLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.spot_range = range_m
	l.spot_angle = angle_deg
	l.shadow_enabled = false
	l.transform = look_from(pos, target)
	parent.add_child(l)
	return l


## A transform at `pos` whose -Z points at `target` (cameras, spots).
static func look_from(pos: Vector3, target: Vector3) -> Transform3D:
	var dir := target - pos
	if dir.length_squared() < 0.000001:
		return Transform3D(Basis.IDENTITY, pos)
	var up := Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.99 else Vector3.BACK
	return Transform3D(Basis.looking_at(dir.normalized(), up), pos)


## A dark scene: flat background colour, flat ambient, optional exponential depth fog (no volumetric fog on the Mobile renderer).
static func night_env(bg: Color, ambient: Color, ambient_energy: float, fog: Color, fog_density: float) -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = bg
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = ambient
	e.ambient_light_energy = ambient_energy
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.fog_enabled = fog_density > 0.0
	e.fog_light_color = fog
	e.fog_density = fog_density
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	return e


## A sky-gradient scene (dawn): ProceduralSkyMaterial, ambient and reflections from flat colour. No DirectionalLight anywhere in a
## cutscene: it would light the whole level, so there is no sun disc either (scenes draw their own).
static func sky_env(top: Color, horizon: Color, ground: Color, ambient: Color, ambient_energy: float, fog_density: float) -> Environment:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_horizon_color = horizon.lerp(ground, 0.5)
	sky_mat.ground_bottom_color = ground
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = ambient
	e.ambient_light_energy = ambient_energy
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.fog_enabled = fog_density > 0.0
	e.fog_light_color = horizon
	e.fog_density = fog_density
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	return e


## A road bump: a damped wobble that starts at `at` seconds.
static func bump(time: float, at: float, amp: float, hz: float, decay: float) -> float:
	var d := time - at
	if d < 0.0:
		return 0.0
	return amp * exp(-d * decay) * sin(d * TAU * hz)
