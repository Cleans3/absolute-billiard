class_name CutsceneKit
extends RefCounted
## Procedural-geometry helpers the cutscenes share (docs/plan/09 §4.4). A `Soup` merges many vertex-coloured boxes, cylinders and
## cones into ONE mesh = one draw call; the rest is plain materials, a night Environment and light makers. No scene state.

const TEXTURE_DIR := "res://assets/textures/%s/albedo.webp"  ## the CC0 detail maps (assets/textures/SOURCE.md)

static var _vertex_material: StandardMaterial3D


## Vertex-coloured solids merged into one mesh. `xf` (rotation + translation only) is applied to whatever is added next.
class Soup extends RefCounted:
	const CAP_BOTTOM := 1
	const CAP_TOP := 2
	const BOX_FACES := [[0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6], [0, 1, 3, 2], [4, 5, 7, 6]]
	const BOX_NORMALS: Array[Vector3] = [Vector3.LEFT, Vector3.RIGHT, Vector3.DOWN, Vector3.UP, Vector3.FORWARD, Vector3.BACK]

	var xf := Transform3D.IDENTITY
	var _st := SurfaceTool.new()
	var _tris := 0

	func _init() -> void:
		_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	func triangles() -> int:
		return _tris

	## One triangle with outward normal `n`, wound the way Godot front-faces it (clockwise seen from outside) whatever the order given.
	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
		var pa := xf * a
		var pb := xf * b
		var pc := xf * c
		var nn := (xf.basis * n).normalized()
		var cross := (pb - pa).cross(pc - pa)
		if cross.length_squared() < 0.0000001:
			return
		var v1 := pb
		var v2 := pc
		if cross.dot(nn) > 0.0:
			v1 = pc
			v2 = pb
		for p: Vector3 in [pa, v1, v2]:
			_st.set_color(col)
			_st.set_normal(nn)
			_st.add_vertex(p)
		_tris += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
		tri(a, b, c, n, col)
		tri(a, c, d, n, col)

	func box(centre: Vector3, half: Vector3, col: Color) -> void:
		var c: Array[Vector3] = []
		for n in 8:
			c.append(centre + Vector3(half.x if n & 1 else -half.x, half.y if n & 2 else -half.y, half.z if n & 4 else -half.z))
		for f in 6:
			var idx: Array = BOX_FACES[f]
			quad(c[idx[0]], c[idx[1]], c[idx[2]], c[idx[3]], BOX_NORMALS[f], col)

	## Vertical frustum from `base` up by `h`; elliptical radii (x, z) at the bottom and the top; r1 = 0 is a cone.
	func cyl(base: Vector3, h: float, r0: Vector2, r1: Vector2, sides: int, col: Color, caps := CAP_BOTTOM | CAP_TOP) -> void:
		var top := base + Vector3(0.0, h, 0.0)
		var slope := Vector3.UP * ((r0.x + r0.y - r1.x - r1.y) * 0.5)
		for n in sides:
			var a0 := TAU * n / sides
			var a1 := TAU * (n + 1) / sides
			var d0 := Vector3(cos(a0), 0.0, sin(a0))
			var d1 := Vector3(cos(a1), 0.0, sin(a1))
			var b0 := base + Vector3(d0.x * r0.x, 0.0, d0.z * r0.y)
			var b1 := base + Vector3(d1.x * r0.x, 0.0, d1.z * r0.y)
			var t0 := top + Vector3(d0.x * r1.x, 0.0, d0.z * r1.y)
			var t1 := top + Vector3(d1.x * r1.x, 0.0, d1.z * r1.y)
			var mid := (d0 + d1).normalized()
			var nm := (Vector3(mid.x * r0.y, 0.0, mid.z * r0.x).normalized() * maxf(h, 0.001) + slope).normalized()
			tri(b0, b1, t1, nm, col)
			tri(b0, t1, t0, nm, col)
			if caps & CAP_BOTTOM:
				tri(base, b1, b0, Vector3.DOWN, col)
			if caps & CAP_TOP and r1.x > 0.0:
				tri(top, t0, t1, Vector3.UP, col)

	## Ellipsoid, smooth normals.
	func ball(centre: Vector3, radii: Vector3, seg: int, rings: int, col: Color) -> void:
		var grid: Array = []
		for r in rings + 1:
			var row: Array[Vector3] = []
			var phi := PI * r / rings
			for s in seg:
				var th := TAU * s / seg
				row.append(Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th)))
			grid.append(row)
		for r in rings:
			for s in seg:
				var s2 := (s + 1) % seg
				var q: Array[Vector3] = [grid[r][s], grid[r][s2], grid[r + 1][s2], grid[r + 1][s]]
				var p: Array[Vector3] = []
				for v in q:
					p.append(centre + v * radii)
				var nrm: Array[Vector3] = []
				for v in q:
					nrm.append((v / radii).normalized())
				if r > 0:
					_smooth_tri(p[0], p[1], p[2], nrm[0], nrm[1], nrm[2], col)
				if r < rings - 1:
					_smooth_tri(p[0], p[2], p[3], nrm[0], nrm[2], nrm[3], col)

	func _smooth_tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, col: Color) -> void:
		var pa := xf * a
		var pb := xf * b
		var pc := xf * c
		var cross := (pb - pa).cross(pc - pa)
		if cross.length_squared() < 0.0000001:
			return
		var sum := xf.basis * (na + nb + nc)
		var order: Array[int] = [0, 1, 2]
		if cross.dot(sum) > 0.0:
			order = [0, 2, 1]
		var pts: Array[Vector3] = [pa, pb, pc]
		var nrm: Array[Vector3] = [(xf.basis * na).normalized(), (xf.basis * nb).normalized(), (xf.basis * nc).normalized()]
		for k in order:
			_st.set_color(col)
			_st.set_normal(nrm[k])
			_st.add_vertex(pts[k])
		_tris += 1

	## The merged mesh (null material = the shared vertex-colour one).
	func mesh(material: Material = null) -> ArrayMesh:
		var m := _st.commit()
		if m.get_surface_count() > 0:
			m.surface_set_material(0, material if material != null else CutsceneKit.vertex_material())
		return m


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
