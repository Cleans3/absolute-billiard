extends SceneTree

## One-shot: regenerates src/gameplay/bar_room/{meshes,materials}/* and BarRoom.tscn (04 §2.2, 07 §2).
## Static room merged by material (8 MeshInstance3D), UV2 unwrapped for LightmapGI, layer-4 collision, BarRoom script on the root.
## Every textured surface is box-mapped in world metres (UV = position / tile, per face axis) so no texture stretches, on
## ORMMaterial3D sets from assets/textures (Poly Haven CC0, src/tools/make_textures.py).
## `Decor` is DecorPlan's CC0 Kenney props routed per triangle into the room's own surfaces (wood / seat / prop) or, for flat
## colours + the posters, into one atlas surface (adhoc-1010a C10/C18); the source .glb are read from assets/third_party/ and never shipped.
##   godot --path . --headless -s src/tools/build_bar_room.gd
## Then bake with src/tools/bake_lightmaps.sh (needs a GPU window).

const DIR := "res://src/gameplay/bar_room/"
const TEX := "res://assets/textures/%s/%s"
const HALF := 7.0       # interior half-extent in x and z (matches the old CSG walls)
const CEIL := 3.6
const TEXEL := 0.15     # xatlas texel size in metres
# Bar counter, contract §6: off the east wall so a bartender fits behind it. The aisle floor is x 5.5-6.6.
const COUNTER_BODY_X := 5.15   # body x 4.85-5.45
const COUNTER_TOP_X := 5.1     # top x 4.7-5.5 (also the collision box)
const BACKBAR_X := 6.8         # shelves + cabinet x 6.6-7.0, flush to the east wall
const STOOL_X := 4.3
const TABLES: Array[Vector3] = [Vector3(-5.2, 0.0, 2.6), Vector3(-5.2, 0.0, 4.4), Vector3(-2.8, 0.0, 5.6)]
## World metres one texture repeat covers (Poly Haven's real-world size where it fits the prop).
const TILE := {floor = 2.0, wall = 1.0, wainscot = 2.1, ceiling = 2.0, wood = 1.2, seat = 0.5, metal = 1.0}
const DARK := Color(0.16, 0.16, 0.18)   # paint of the greybox metal parts (the prop material itself is white)
const BRASS := Color(0.62, 0.42, 0.16)

var _tiles := {}   # SurfaceTool -> tile metres (0 = keep the primitive's own UV)


func _init() -> void:
	call_deferred("_run")


## Emissive / flat material (neon, screens).
func _mat(id: String, albedo: Color, rough := 0.85, metal := 0.0, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	_save_mat(id, m)
	return m


## PBR material: `set` = assets/textures/<set>/{albedo.webp, orm.webp, normal.png}. `color` multiplies the albedo detail map
## (a BarSkin colour is set on it verbatim, BarRoom.apply_skin), the vertex colour multiplies again (white = untouched).
func _pbr(id: String, color: Color, set: String, normal := true, metal := 0.0) -> ORMMaterial3D:
	var m := ORMMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = load(TEX % [set, "albedo.webp"])
	m.orm_texture = load(TEX % [set, "orm.webp"])
	m.ao_enabled = true
	m.metallic = metal
	m.roughness = 1.0
	if normal:
		m.normal_enabled = true
		m.normal_texture = load(TEX % [set, "normal.png"])
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	_save_mat(id, m)
	return m


func _save_mat(id: String, m: BaseMaterial3D) -> void:
	m.resource_name = id
	ResourceSaver.save(m, DIR + "materials/%s.tres" % id)
	m.take_over_path(DIR + "materials/%s.tres" % id)


## A surface tool for `mat`; `tile` > 0 world-box-maps everything added through `_box` / `_cyl` / `_lathe` / `_place`.
func _st(mat: BaseMaterial3D, tile := 0.0) -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	_tiles[st] = tile
	return st


## Planar UV on the face's dominant axis, in tiles. v runs down the wall so grain / bricks stand upright.
func _uv(p: Vector3, n: Vector3, tile: float) -> Vector2:
	var a := n.abs()
	if a.y >= a.x and a.y >= a.z:
		return Vector2(p.x, p.z) / tile
	if a.x >= a.z:
		return Vector2(p.z, -p.y) / tile
	return Vector2(p.x, -p.y) / tile


## A primitive into `st` through `xf`. Box-mapped when the tool has a tile; a cylinder's side wraps around by `wrap_r`.
func _append(st: SurfaceTool, m: PrimitiveMesh, xf: Transform3D, color := Color.WHITE, wrap_r := 0.0) -> void:
	var tile: float = _tiles.get(st, 0.0)
	var a := m.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	for i in a[Mesh.ARRAY_INDEX]:
		var p := xf * v[i]
		var n := (xf.basis * nrm[i]).normalized()
		st.set_color(color)
		st.set_normal(n)
		if tile <= 0.0:
			st.set_uv(uv[i])
		elif wrap_r > 0.0 and absf(n.y) < 0.7:
			st.set_uv(Vector2(uv[i].x * TAU * wrap_r, -p.y) / tile)
		else:
			st.set_uv(_uv(p, n, tile))
		st.add_vertex(p)


func _box(st: SurfaceTool, center: Vector3, size: Vector3, yaw_deg := 0.0, color := Color.WHITE) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	_append(st, bm, Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), center), color)


func _cyl(st: SurfaceTool, center: Vector3, radius: float, height: float, seg := 14, color := Color.WHITE) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = seg
	cm.rings = 1
	_append(st, cm, Transform3D(Basis.IDENTITY, center), color, radius)


## A round bar of `radius` from `a` to `b` (neon tubes, rails).
func _tube(st: SurfaceTool, a: Vector3, b: Vector3, radius: float, seg := 8, color := Color.WHITE) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = a.distance_to(b)
	cm.radial_segments = seg
	cm.rings = 1
	var dir := (b - a).normalized()
	var basis := Basis() if dir.is_equal_approx(Vector3.UP) else Basis(Quaternion(Vector3.UP, dir))
	_append(st, cm, Transform3D(basis, (a + b) * 0.5), color, radius)


## Surface of revolution about the vertical axis through `centre`; `profile` = (radius, y) points bottom to top along the outside
## (so the outward normal is to the right of travel). Flat bands, smooth round; caps planar-mapped, sides wrapped.
func _lathe(st: SurfaceTool, centre: Vector3, profile: Array, seg := 16, color := Color.WHITE) -> void:
	var tile: float = _tiles.get(st, 0.0)
	for k in profile.size() - 1:
		var pa: Vector2 = profile[k]
		var pb: Vector2 = profile[k + 1]
		var n2 := Vector2(pb.y - pa.y, pa.x - pb.x).normalized()
		var rmid := (pa.x + pb.x) * 0.5
		for j in seg:
			var t0 := TAU * j / seg
			var t1 := TAU * (j + 1) / seg
			var corners := [[pa, t0], [pb, t0], [pb, t1], [pa, t1]]
			var pts: Array[Vector3] = []
			var nrm: Array[Vector3] = []
			var uvs: Array[Vector2] = []
			for c: Array in corners:
				var pr: Vector2 = c[0]
				var th: float = c[1]
				var p := centre + Vector3(cos(th) * pr.x, pr.y, sin(th) * pr.x)
				var n := Vector3(cos(th) * n2.x, n2.y, sin(th) * n2.x)
				pts.append(p)
				nrm.append(n)
				if tile <= 0.0:
					uvs.append(Vector2.ZERO)
				elif absf(n2.y) > 0.7:
					uvs.append(_uv(p, Vector3.UP, tile))
				else:
					uvs.append(Vector2(th * rmid, -p.y) / tile)
			for tri: Array in [[0, 1, 2], [0, 2, 3]]:
				var cr: Vector3 = (pts[tri[1]] - pts[tri[0]]).cross(pts[tri[2]] - pts[tri[0]])
				if cr.length_squared() < 1e-12:
					continue
				var order: Array = tri if cr.dot(nrm[tri[0]]) <= 0.0 else [tri[0], tri[2], tri[1]]
				for i: int in order:
					st.set_color(color)
					st.set_normal(nrm[i])
					st.set_uv(uvs[i])
					st.add_vertex(pts[i])


## Commits every surface tool into one ArrayMesh (one surface each), unwraps UV2, saves and returns it.
func _bake_mesh(id: String, sts: Array[SurfaceTool]) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for st in sts:
		st.index()
		st.commit(mesh)
	var err := mesh.lightmap_unwrap(Transform3D.IDENTITY, TEXEL)
	assert(err == OK, "lightmap_unwrap failed for %s" % id)
	var path := DIR + "meshes/%s.res" % id
	ResourceSaver.save(mesh, path)
	mesh.take_over_path(path)
	return mesh


func _run() -> void:
	var floor_m := _pbr("floor", Color(0.20, 0.12, 0.075), "floor")
	var wall_m := _pbr("wall", Color(0.30, 0.17, 0.15), "wall")
	var ceil_m := _pbr("ceiling", Color(0.11, 0.085, 0.075), "ceiling", false)
	var wood_m := _pbr("wood", Color(0.24, 0.13, 0.06), "wood")
	var wainscot_m := _pbr("wainscot", Color(0.24, 0.13, 0.06), "wainscot")  # own material so a BarSkin can tint it apart from the wood
	var seat_m := _pbr("seat", Color(0.42, 0.09, 0.08), "seat")
	var prop_m := _pbr("prop", Color.WHITE, "metal", true, 0.6)  # white: every metal part carries its own paint in its vertex colour
	var pink_m := _mat("neon_pink", Color.BLACK, 0.5, 0.0, Color(1.0, 0.15, 0.55), 3.0)
	var cyan_m := _mat("neon_cyan", Color.BLACK, 0.5, 0.0, Color(0.1, 0.85, 1.0), 3.0)
	var tv_m := _mat("tv_screen", Color.BLACK, 0.3, 0.0, Color.WHITE, 1.7)
	tv_m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	tv_m.emission_texture = load("res://assets/decor/tv_screen.png")
	_save_mat("tv_screen", tv_m)
	var juke_m := _mat("jukebox_glass", Color.BLACK, 0.3, 0.0, Color(1.0, 0.6, 0.15), 2.5)

	var s_floor := _st(floor_m, TILE.floor)
	var s_walls := _st(wall_m, TILE.wall)
	var s_ceil := _st(ceil_m, TILE.ceiling)
	var s_wood := _st(wood_m, TILE.wood)
	var s_wain := _st(wainscot_m, TILE.wainscot)
	var s_seat := _st(seat_m, TILE.seat)
	var s_prop := _st(prop_m, TILE.metal)
	var s_pink := _st(pink_m)
	var s_cyan := _st(cyan_m)
	var s_tv := _st(tv_m)
	var s_juke := _st(juke_m)

	# --- floor ---
	_box(s_floor, Vector3(0, -0.05, 0), Vector3(2 * HALF, 0.1, 2 * HALF))

	# --- walls (north wall has the door opening) ---
	var t := 0.2
	_box(s_walls, Vector3(0, CEIL * 0.5, HALF + t * 0.5), Vector3(2 * HALF + 2 * t, CEIL, t))
	_box(s_walls, Vector3(-HALF - t * 0.5, CEIL * 0.5, 0), Vector3(t, CEIL, 2 * HALF))
	_box(s_walls, Vector3(HALF + t * 0.5, CEIL * 0.5, 0), Vector3(t, CEIL, 2 * HALF))
	var dw := 0.95  # half door width
	var seg_w := HALF - dw
	_box(s_walls, Vector3(-(dw + seg_w * 0.5), CEIL * 0.5, -HALF - t * 0.5), Vector3(seg_w + t, CEIL, t))
	_box(s_walls, Vector3(dw + seg_w * 0.5, CEIL * 0.5, -HALF - t * 0.5), Vector3(seg_w + t, CEIL, t))
	_box(s_walls, Vector3(0, (2.3 + CEIL) * 0.5, -HALF - t * 0.5), Vector3(2 * dw, CEIL - 2.3, t))

	# --- ceiling + beams (the beams are wood) ---
	_box(s_ceil, Vector3(0, CEIL + 0.05, 0), Vector3(2 * HALF + 0.4, 0.1, 2 * HALF + 0.4))
	for bx in [-4.5, 0.0, 4.5]:
		_box(s_wood, Vector3(bx, CEIL - 0.15, 0), Vector3(0.25, 0.3, 2 * HALF))

	# --- wood: counter top, shelves, table tops, door frame, trim; panelling: wainscot, counter front, back bar, door ---
	var counter_z0 := 0.5
	var counter_len := 4.0
	var cz := counter_z0 + counter_len * 0.5
	_box(s_wain, Vector3(COUNTER_BODY_X, 0.5, cz), Vector3(0.6, 1.0, counter_len))                     # body, panelled front
	_box(s_wood, Vector3(COUNTER_TOP_X, 1.04, cz), Vector3(0.8, 0.08, counter_len + 0.2))              # top
	_tube(s_prop, Vector3(4.77, 0.2, counter_z0), Vector3(4.77, 0.2, counter_z0 + counter_len), 0.03, 10, BRASS)   # foot rail
	for fz in [counter_z0 + 0.1, cz, counter_z0 + counter_len - 0.1]:
		_box(s_prop, Vector3(4.82, 0.2, fz), Vector3(0.1, 0.05, 0.05), 0.0, BRASS)                       # rail brackets
	_box(s_wain, Vector3(BACKBAR_X, 0.5, cz), Vector3(0.4, 1.0, counter_len))                          # back-bar cabinet
	_box(s_wood, Vector3(BACKBAR_X, 1.55, cz), Vector3(0.4, 0.06, counter_len))                        # shelf low
	_box(s_wood, Vector3(BACKBAR_X, 2.05, cz), Vector3(0.4, 0.06, counter_len))                        # shelf high
	_box(s_wain, Vector3(6.9, 1.6, cz), Vector3(0.2, 3.2, counter_len))                                # back-bar panel
	for wz in [-HALF + 0.03, HALF - 0.03]:
		_box(s_wain, Vector3(0, 0.55, wz), Vector3(2 * HALF, 1.1, 0.06))                               # wainscot N/S
	_box(s_wain, Vector3(-HALF + 0.03, 0.55, 0), Vector3(0.06, 1.1, 2 * HALF))
	_trim(s_wood, dw)
	for tp in TABLES:
		_round_table(s_wood, s_prop, tp)
	_box(s_wain, Vector3(0, 1.15, -HALF + 0.05), Vector3(2 * dw - 0.1, 2.3, 0.08))                      # door slab (closed), panelled
	_box(s_wood, Vector3(0, 2.36, -HALF + 0.06), Vector3(2 * dw + 0.3, 0.12, 0.1))                      # door frame head
	for sx in [-1.0, 1.0]:
		_box(s_wood, Vector3(sx * (dw + 0.05), 1.18, -HALF + 0.06), Vector3(0.1, 2.36, 0.1))            # door frame posts
	_cyl(s_prop, Vector3(0.65, 1.1, -HALF + 0.12), 0.025, 0.12, 8, BRASS)                              # door handle

	# --- props: jukebox body, TV frame, fuse box, lamp, back-bar mounts (metal, painted by vertex colour) ---
	var stools: Array[Vector3] = [Vector3(0, 0, 0)]
	for z in [1.0, 2.0, 3.0, 4.0]:
		stools.append(Vector3(STOOL_X, 0, z))
	for tp in TABLES:
		stools.append(tp + Vector3(0.75, 0, 0))
		stools.append(tp + Vector3(-0.75, 0, 0))
	_jukebox(s_wood, s_wain, s_prop)
	_taps(s_prop)
	_box(s_prop, Vector3(0, 2.1, HALF - 0.06), Vector3(2.5, 1.5, 0.12), 0.0, DARK)                      # TV frame (south wall)
	_box(s_prop, Vector3(-HALF + 0.08, 1.4, 5.8), Vector3(0.16, 0.5, 0.35), 0.0, DARK)                  # fuse box (flick_lights)
	_lamp(s_prop)
	_neon(s_pink, s_cyan, s_prop)

	# --- screens (two surfaces): TV and jukebox glass ---
	var tf := _wall_frame(&"S", 0.0, 2.1, 0.16)   # the TV picture: one quad, the whole broadcast still on it
	var tc: Vector3 = tf.c
	var tw: Vector3 = (tf.r as Vector3) * 1.15
	var th := Vector3.UP * 0.65
	_quad(s_tv, [tc - tw + th, tc + tw + th, tc + tw - th, tc - tw - th], [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], tf.n)
	_box(s_juke, Vector3(6.16, 1.14, 5.8), Vector3(0.05, 0.56, 0.8))

	# --- decor: CC0 props into the room's own surfaces + one atlas surface for flat colours and posters ---
	var decor := _build_decor({&"wood": s_wood, &"seat": s_seat, &"prop": s_prop}, stools)

	var floor_mesh := _bake_mesh("floor", [s_floor])
	var walls_mesh := _bake_mesh("walls", [s_walls])
	var ceil_mesh := _bake_mesh("ceiling", [s_ceil])
	var wood_mesh := _bake_mesh("wood", [s_wood, s_wain])
	var seat_mesh := _bake_mesh("seats", [s_seat])
	var prop_mesh := _bake_mesh("props", [s_prop])
	var neon_mesh := _bake_mesh("neon", [s_pink, s_cyan])
	var screen_mesh := _bake_mesh("screens", [s_tv, s_juke])
	var decor_st: SurfaceTool = decor.st
	decor.mesh = _bake_mesh("decor", [decor_st])

	# --- scene ---
	var root_n := Node3D.new()
	root_n.name = "BarRoom"
	root_n.set_script(load("res://src/gameplay/bar_room/bar_room.gd"))  # apply_skin lives there; emitted here so a regen keeps it
	var geo := _add(root_n, Node3D.new(), "Geometry")
	for e in [["Floor", floor_mesh], ["Walls", walls_mesh], ["Ceiling", ceil_mesh], ["Wood", wood_mesh],
			["Seats", seat_mesh], ["Props", prop_mesh], ["Neon", neon_mesh], ["Screens", screen_mesh]]:
		var mi := MeshInstance3D.new()
		mi.mesh = e[1]
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # 07 §2: props never cast into the one shadow map
		_add(geo, mi, e[0])

	_add_decor(root_n, decor)
	_build_collision(root_n, counter_z0, counter_len, stools, decor.boxes)
	_build_lights(root_n)
	_build_env(root_n)

	var lm := LightmapGI.new()
	lm.quality = LightmapGI.BAKE_QUALITY_HIGH
	lm.bounces = 2
	lm.interior = true
	lm.texel_scale = 1.0
	lm.max_texture_size = 1024
	lm.use_denoiser = true
	_add(root_n, lm, "Lightmap")

	var ps := PackedScene.new()
	assert(ps.pack(root_n) == OK)
	assert(ResourceSaver.save(ps, DIR + "BarRoom.tscn") == OK)
	print("bar room built: ", DIR + "BarRoom.tscn")
	quit()


# ---------------------------------------------------------------------------------------------------------------------
# Shell details
# ---------------------------------------------------------------------------------------------------------------------

## Baseboard on the three panelled walls and a chair rail on top of the wainscot, both broken at the door; the chair rail also
## stops short of the mirror's stretch of the west wall (z -5.9..-1.7) and the blackboard's wall has no panelling.
func _trim(s_wood: SurfaceTool, dw: float) -> void:
	var door_gap := dw + 0.2
	for z in [-HALF + 0.07, HALF - 0.07]:
		var xs: Array = [[-HALF, HALF]] if z > 0.0 else [[-HALF, -door_gap], [door_gap, HALF]]
		for r: Array in xs:
			var len: float = r[1] - r[0]
			var cx: float = (r[0] + r[1]) * 0.5
			_box(s_wood, Vector3(cx, 0.07, z), Vector3(len, 0.14, 0.04))                  # baseboard
			_box(s_wood, Vector3(cx, 1.12, z + signf(-z) * 0.02), Vector3(len, 0.05, 0.1))  # chair rail
	_box(s_wood, Vector3(-HALF + 0.07, 0.07, 0), Vector3(0.04, 0.14, 2 * HALF))             # west baseboard
	_box(s_wood, Vector3(-HALF + 0.09, 1.12, (-1.7 + HALF) * 0.5), Vector3(0.1, 0.05, HALF + 1.7 - 0.0))  # west chair rail, z -1.7..7


## A bar-height round table: a rounded wood top at y 0.95-1.01 (DecorPlan.TABLE_TOP_Y) on a metal pedestal.
func _round_table(s_wood: SurfaceTool, s_prop: SurfaceTool, c: Vector3) -> void:
	_lathe(s_wood, c, [Vector2(0.0, 0.95), Vector2(0.44, 0.95), Vector2(0.5, 0.97), Vector2(0.5, 0.995), Vector2(0.47, 1.01), Vector2(0.0, 1.01)], 24)
	_lathe(s_prop, c, [Vector2(0.34, 0.0), Vector2(0.34, 0.03), Vector2(0.12, 0.09), Vector2(0.06, 0.16), Vector2(0.06, 0.95)], 14, DARK)
	_cyl(s_prop, c + Vector3(0, 0.955, 0), 0.14, 0.03, 12, BRASS)                              # collar under the top


## The jukebox against the east wall inside its 0.75 x 1.9 x 1.1 collision box (x 6.175-6.925, front faces -x): plinth, panelled
## cabinet with a grille, the glowing window in a brass bezel, brass pillars, an arched wood crown.
func _jukebox(s_wood: SurfaceTool, s_wain: SurfaceTool, s_prop: SurfaceTool) -> void:
	var cx := 6.55
	var cz := 5.8
	_box(s_wood, Vector3(cx, 0.08, cz), Vector3(0.75, 0.16, 1.1))                                     # plinth
	_box(s_wain, Vector3(cx, 0.47, cz), Vector3(0.73, 0.62, 1.06))                                    # lower cabinet
	_box(s_prop, Vector3(cx - 0.375, 0.47, cz), Vector3(0.03, 0.4, 0.7), 0.0, Color(0.03, 0.03, 0.035))  # speaker grille
	for dz in [-0.37, 0.37]:
		_box(s_prop, Vector3(cx - 0.385, 0.47, cz + dz), Vector3(0.02, 0.44, 0.04), 0.0, BRASS)
	for dy in [0.25, 0.69]:
		_box(s_prop, Vector3(cx - 0.385, dy, cz), Vector3(0.02, 0.04, 0.78), 0.0, BRASS)
	_box(s_wain, Vector3(cx, 1.14, cz), Vector3(0.75, 0.72, 1.1))                                     # window body
	for dy in [0.84, 1.44]:
		_box(s_prop, Vector3(cx - 0.4, dy, cz), Vector3(0.04, 0.04, 0.9), 0.0, BRASS)                 # bezel top / bottom
	for dz in [-0.45, 0.45]:
		_box(s_prop, Vector3(cx - 0.4, 1.14, cz + dz), Vector3(0.04, 0.64, 0.04), 0.0, BRASS)         # bezel sides
	_tube(s_wood, Vector3(cx, 1.5, cz - 0.55), Vector3(cx, 1.5, cz + 0.55), 0.37, 18)                  # arched crown (lower half sits in the body)
	for dz in [-0.52, 0.52]:
		_tube(s_prop, Vector3(cx - 0.36, 0.16, cz + dz), Vector3(cx - 0.36, 1.5, cz + dz), 0.03, 10, BRASS)  # pillars


## Three beer taps on the counter's far (bartender) edge, clear of the serve spot at z 2.5.
func _taps(s_prop: SurfaceTool) -> void:
	_box(s_prop, Vector3(5.3, 1.09, 3.6), Vector3(0.22, 0.02, 0.7), 0.0, DARK)                         # drip tray
	for z in [3.35, 3.6, 3.85]:
		_cyl(s_prop, Vector3(5.3, 1.12, z), 0.03, 0.04, 10, BRASS)                                       # base
		_tube(s_prop, Vector3(5.3, 1.14, z), Vector3(5.3, 1.34, z), 0.014, 8, Color(0.8, 0.8, 0.82))     # chrome stem
		_box(s_prop, Vector3(5.26, 1.3, z), Vector3(0.1, 0.02, 0.02), 0.0, Color(0.8, 0.8, 0.82))        # spout
		_box(s_prop, Vector3(5.3, 1.4, z), Vector3(0.025, 0.1, 0.03), 0.0, DARK)                         # handle


## The pool-hall lamp over the table: green cone shade with a cream lining, rod to the ceiling. The light itself is a node.
func _lamp(s_prop: SurfaceTool) -> void:
	var c := Vector3(0, 0, -3.5)
	_lathe(s_prop, c, [Vector2(0.55, 2.95), Vector2(0.14, 3.22)], 20, Color(0.05, 0.22, 0.13))
	_lathe(s_prop, c, [Vector2(0.14, 3.22), Vector2(0.13, 3.19), Vector2(0.545, 2.93), Vector2(0.55, 2.95)], 20, Color(0.75, 0.62, 0.42))
	_box(s_prop, Vector3(0, 3.41, -3.5), Vector3(0.04, 0.38, 0.04), 0.0, DARK)                  # rod
	_cyl(s_prop, Vector3(0, 3.22, -3.5), 0.07, 0.06, 10, BRASS)                                  # cap


## Neon as real tubes on dark backing plates, sized to DecorPlan.wall_keep_clear's sign rects.
func _neon(sp: SurfaceTool, sc: SurfaceTool, s_prop: SurfaceTool) -> void:
	var plate := Color(0.03, 0.03, 0.035)
	var wx := -HALF + 0.08
	_box(s_prop, Vector3(-HALF + 0.04, 2.15, 1.5), Vector3(0.04, 0.78, 2.5), 0.0, plate)
	for bar: Array in [[2.4, 2.2], [2.15, 1.6], [1.9, 2.2]]:                                      # west wall: three bars
		_tube(sp, Vector3(wx, bar[0], 1.5 - bar[1] * 0.5), Vector3(wx, bar[0], 1.5 + bar[1] * 0.5), 0.032)
	var nz := -HALF + 0.08
	_box(s_prop, Vector3(-3.0, 2.85, -HALF + 0.04), Vector3(2.55, 0.48, 0.04), 0.0, plate)
	_box(s_prop, Vector3(3.0, 2.85, -HALF + 0.04), Vector3(1.75, 0.68, 0.04), 0.0, plate)
	for y in [3.0, 2.7]:                                                                         # north wall: cyan pair over the door side
		_tube(sc, Vector3(-4.2, y, nz), Vector3(-1.8, y, nz), 0.032)
	_tube(sc, Vector3(3.0, 2.55, nz), Vector3(3.0, 3.15, nz), 0.032)
	_tube(sp, Vector3(2.2, 2.85, nz), Vector3(3.8, 2.85, nz), 0.032)


func _add(parent: Node, n: Node, nm: String) -> Node:
	n.name = nm
	parent.add_child(n)
	n.owner = parent if parent.owner == null and parent.get_parent() == null else parent.owner
	return n


func _shape(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	cs.position = center
	body.add_child(cs)
	cs.owner = body.owner


func _build_collision(root_n: Node3D, cz0: float, clen: float, stools: Array[Vector3], decor_boxes: Array) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 8  # 07 §1 layer 4 "world"; balls (mask 1|2|3) never test it
	body.collision_mask = 0
	_add(root_n, body, "Collision")
	_shape(body, Vector3(0, -0.5, 0), Vector3(2 * HALF + 4, 1.0, 2 * HALF + 4))
	_shape(body, Vector3(0, CEIL + 0.5, 0), Vector3(2 * HALF + 4, 1.0, 2 * HALF + 4))
	_shape(body, Vector3(0, CEIL * 0.5, HALF + 0.5), Vector3(2 * HALF + 2, CEIL, 1.0))
	_shape(body, Vector3(0, CEIL * 0.5, -HALF - 0.5), Vector3(2 * HALF + 2, CEIL, 1.0))
	_shape(body, Vector3(-HALF - 0.5, CEIL * 0.5, 0), Vector3(1.0, CEIL, 2 * HALF))
	_shape(body, Vector3(HALF + 0.5, CEIL * 0.5, 0), Vector3(1.0, CEIL, 2 * HALF))
	_shape(body, Vector3(COUNTER_TOP_X, 0.55, cz0 + clen * 0.5), Vector3(0.8, 1.1, clen + 0.2))  # counter
	_shape(body, Vector3(BACKBAR_X, 1.6, cz0 + clen * 0.5), Vector3(0.4, 3.2, clen))   # back bar: bounds the aisle (x 5.5-6.6)
	_shape(body, Vector3(6.55, 0.95, 5.8), Vector3(0.75, 1.9, 1.1))                    # jukebox
	for p in stools:
		_shape(body, p + Vector3(0, 0.4, 0), Vector3(0.44, 0.8, 0.44))
	for tp in TABLES:
		_shape(body, tp + Vector3(0, 0.5, 0), Vector3(1.0, 1.0, 1.0))
	for b: AABB in decor_boxes:
		_shape(body, b.get_center(), b.size)


func _light(root_n: Node3D, nm: String, pos: Vector3, color: Color, energy: float, range_m: float, bake: int) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = range_m
	l.light_bake_mode = bake
	l.shadow_enabled = false
	_add(root_n, l, nm)
	return l


func _build_lights(root_n: Node3D) -> void:
	# 3 realtime lights max, 1 shadowed (07 §2): the table lamp spot + one bar fill. Neon/TV/jukebox are baked.
	var spot := SpotLight3D.new()
	spot.position = Vector3(0, 2.95, -3.5)
	spot.rotation_degrees = Vector3(-90, 0, 0)
	spot.light_color = Color(1.0, 0.86, 0.62)
	spot.light_energy = 14.0
	spot.spot_range = 6.0
	spot.spot_angle = 58.0
	spot.spot_angle_attenuation = 1.4
	spot.shadow_enabled = true
	spot.shadow_bias = 0.01  # was 0.04: that much peter-panning detaches the rail/cushion shadows from their bases (06 P32); 0.005-0.04 shows no acne on the cloth
	spot.light_bake_mode = Light3D.BAKE_DYNAMIC
	_add(root_n, spot, "TableLamp")
	_light(root_n, "BarFill", Vector3(3.5, 2.6, 2.5), Color(1.0, 0.7, 0.4), 3.0, 6.0, Light3D.BAKE_DYNAMIC)
	_light(root_n, "BakedNeonPink", Vector3(-6.0, 2.2, 1.5), Color(1.0, 0.15, 0.55), 24.0, 7.0, Light3D.BAKE_STATIC)
	_light(root_n, "BakedNeonCyan", Vector3(0.0, 2.6, -6.2), Color(0.1, 0.85, 1.0), 24.0, 8.0, Light3D.BAKE_STATIC)
	_light(root_n, "BakedJukebox", Vector3(5.6, 1.4, 5.8), Color(1.0, 0.6, 0.15), 12.0, 4.0, Light3D.BAKE_STATIC)
	_light(root_n, "BakedTV", Vector3(0.0, 2.1, 6.0), Color(0.45, 0.6, 1.0), 24.0, 6.0, Light3D.BAKE_STATIC)
	_light(root_n, "BakedRoomWarm", Vector3(0.0, 3.2, 1.5), Color(1.0, 0.75, 0.5), 28.0, 12.0, Light3D.BAKE_STATIC)
	var probes := [["ReflectTable", Vector3(0, 1.8, -3.5), Vector3(9.0, 3.5, 7.0)], ["ReflectBar", Vector3(4.0, 1.8, 3.5), Vector3(6.0, 3.5, 7.0)]]
	for p in probes:
		var rp := ReflectionProbe.new()
		rp.position = p[1]
		rp.size = p[2]
		rp.interior = true
		rp.box_projection = true
		rp.update_mode = ReflectionProbe.UPDATE_ONCE  # Godot 4 has no baked-probe asset: captured once at load
		rp.intensity = 0.6
		rp.cull_mask = 1
		_add(root_n, rp, p[0])


func _build_env(root_n: Node3D) -> void:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.015, 0.02)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.09, 0.07, 0.08)
	e.ambient_light_energy = 0.5
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_light_color = Color(0.13, 0.09, 0.08)
	e.fog_density = 0.018
	e.glow_enabled = true
	e.glow_intensity = 0.5
	e.glow_strength = 0.8
	e.glow_hdr_threshold = 1.2
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	var we := WorldEnvironment.new()
	we.environment = e
	_add(root_n, we, "WorldEnvironment")


# ---------------------------------------------------------------------------------------------------------------------
# Decor (DecorPlan): CC0 props routed per triangle into the room's surfaces, flat colours + posters in one atlas surface.
# ---------------------------------------------------------------------------------------------------------------------

## -> {st: SurfaceTool (the atlas surface, baked by the caller), items, boxes: Array[AABB], tris}. `tools` = class -> surface
## tool of the room's own wood / seat / prop surface. Aborts the run on a keep-clear violation.
func _build_decor(tools: Dictionary, stools: Array[Vector3]) -> Dictionary:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(DecorPlan.ATLAS_PATH)
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.75
	mat.metallic_specular = 0.2
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_save_mat("decor", mat)
	var st := _st(mat)
	tools[&"decor"] = st
	var items: Array[Dictionary] = []
	var boxes: Array[AABB] = []
	var tris := 0
	var models := {}
	var list: Array = DecorPlan.ITEMS.duplicate()
	list.append_array(DecorPlan.bar_items())
	for i in stools.size():  # bar stools: Kenney stoolBar, red cushion -> seat, frame -> metal; scale to the old 0.8 m seat height
		list.append([StringName("stool_%d" % i), &"furniture", "stoolBar", stools[i], float(i * 47 % 360), &"top", 0.91])
	for it: Array in list:
		var key: String = "%s/%s" % [it[1], it[2]]
		if not models.has(key):
			models[key] = _load_model(it[1], it[2])
		var info := _place(tools, models[key], it)
		tris += info.tris
		items.append(info)
		if it[5] == &"floor":
			boxes.append(AABB(Vector3(info.rect.position.x, it[3].y, info.rect.position.y), Vector3(info.rect.size.x, info.height, info.rect.size.y)))
	for p: Array in DecorPlan.POSTERS:
		items.append(_poster(st, p))
		tris += 12 + 2
	items.append(_dartboard(st))
	tris += 32
	var bad := _keep_clear_violations(items)
	if not bad.is_empty():
		printerr("DECOR KEEP-CLEAR VIOLATIONS:\n  ", "\n  ".join(bad))
		quit(1)
	return {st = st, mesh = null, items = items, boxes = boxes, tris = tris}


func _add_decor(root_n: Node3D, decor: Dictionary) -> void:
	var holder := _add(root_n, Node3D.new(), "Decor")
	var mi := MeshInstance3D.new()
	mi.mesh = decor.mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(holder, mi, "Mesh")
	holder.set_meta("items", decor.items)  # data only (id, model, kind, footprint / wall rect, tris): what tests/world/bar_room_probe.gd reads
	print("decor: %d items, %d tris, %d colliders" % [decor.items.size(), decor.tris, decor.boxes.size()])


## One glb -> {surfaces: [{verts, normals, indices, colors}], min: Vector3, max: Vector3} in model space (colors = the model's own).
func _load_model(pack: StringName, model: String) -> Dictionary:
	var path := ProjectSettings.globalize_path("res://assets/third_party/%s/models/%s.glb" % [DecorPlan.PACKS[pack].dir, model])
	var doc := GLTFDocument.new()
	var gst := GLTFState.new()
	assert(doc.append_from_file(path, gst) == OK, "cannot read " + path)
	var scene := doc.generate_scene(gst)
	var out := {surfaces = [], min = Vector3(INF, INF, INF), max = Vector3(-INF, -INF, -INF)}
	for mi: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		var xf := Transform3D.IDENTITY
		var n: Node3D = mi
		while n != scene:
			xf = n.transform * xf
			n = n.get_parent()
		for i in mi.mesh.get_surface_count():
			var a := mi.mesh.surface_get_arrays(i)
			var m := mi.mesh.surface_get_material(i) as BaseMaterial3D
			var img: Image = null
			if m.albedo_texture != null:
				img = m.albedo_texture.get_image()
				if img.is_compressed():
					img.decompress()
			var src_v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var src_n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var src_uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			var verts := PackedVector3Array()
			var normals := PackedVector3Array()
			var colors := PackedColorArray()
			for k in src_v.size():
				var v := xf * src_v[k]
				verts.append(v)
				normals.append((xf.basis * src_n[k]).normalized())
				var c := m.albedo_color
				if img != null:
					var uv := src_uv[k]
					c = img.get_pixel(clampi(int(fposmod(uv.x, 1.0) * img.get_width()), 0, img.get_width() - 1), clampi(int(fposmod(uv.y, 1.0) * img.get_height()), 0, img.get_height() - 1)) * c
				colors.append(c)
				out.min = out.min.min(v)
				out.max = out.max.max(v)
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(src_v.size()))
			out.surfaces.append({verts = verts, normals = normals, indices = idx, colors = colors})
	scene.free()
	return out


## Adds one DecorPlan item, each triangle to the surface of its material class; returns {id, model, kind, rect (xz footprint), height, tris}.
func _place(tools: Dictionary, model: Dictionary, it: Array) -> Dictionary:
	var scale: float = DecorPlan.PACKS[it[1]].scale * (it[6] if it.size() > 6 else 1.0)
	var forced: StringName = it[7] if it.size() > 7 else &""
	var dim: float = it[8] if it.size() > 8 else 1.0
	var pos: Vector3 = it[3]
	var rot := Basis(Vector3.UP, deg_to_rad(it[4]))
	var lo: Vector3 = model.min
	var hi: Vector3 = model.max
	var centre := Vector3((lo.x + hi.x) * 0.5, lo.y if it[5] != &"hang" else hi.y, (lo.z + hi.z) * 0.5)
	var tris := 0
	var rmin := Vector2(INF, INF)
	var rmax := Vector2(-INF, -INF)
	for corner in [Vector3(lo.x, 0, lo.z), Vector3(hi.x, 0, lo.z), Vector3(lo.x, 0, hi.z), Vector3(hi.x, 0, hi.z)]:
		var w: Vector3 = pos + rot * ((corner - centre) * scale)
		rmin = rmin.min(Vector2(w.x, w.z))
		rmax = rmax.max(Vector2(w.x, w.z))
	for sf: Dictionary in model.surfaces:
		var v: PackedVector3Array = sf.verts
		var cols: PackedColorArray = sf.colors
		for t in range(0, sf.indices.size(), 3):
			var tri: Array = [sf.indices[t], sf.indices[t + 1], sf.indices[t + 2]]
			var avg: Color = (cols[tri[0]] + cols[tri[1]] + cols[tri[2]]) / 3.0
			var cls: StringName = forced if forced != &"" else DecorPlan.classify(avg)
			var st: SurfaceTool = tools[cls]
			var tile: float = _tiles.get(st, 0.0)
			var keep: float = DecorPlan.CLASS_KEEP[cls]
			for i: int in tri:
				var p := pos + rot * ((v[i] - centre) * scale)
				var n: Vector3 = rot * sf.normals[i]
				var c: Color = cols[i] * DecorPlan.PROP_TINT * dim if keep >= 1.0 else Color.WHITE.lerp(cols[i], keep)
				st.set_color(c)
				st.set_uv(DecorPlan.WHITE_UV if tile <= 0.0 else _uv(p, n, tile))
				st.set_normal(n)
				st.add_vertex(p)
		tris += sf.indices.size() / 3
	return {id = it[0], model = it[2], kind = it[5], rect = Rect2(rmin, rmax - rmin), height = (hi.y - lo.y) * scale, tris = tris}


## One framed poster flat on a wall. Wall letter -> inward normal and the viewer's right-hand axis.
func _wall_frame(wall: StringName, along: float, y: float, off: float) -> Dictionary:
	match wall:
		&"S": return {c = Vector3(along, y, HALF - off), n = Vector3(0, 0, -1), r = Vector3(-1, 0, 0)}
		&"N": return {c = Vector3(along, y, -HALF + off), n = Vector3(0, 0, 1), r = Vector3(1, 0, 0)}
		&"W": return {c = Vector3(-HALF + off, y, along), n = Vector3(1, 0, 0), r = Vector3(0, 0, -1)}
		_: return {c = Vector3(HALF - off, y, along), n = Vector3(-1, 0, 0), r = Vector3(0, 0, 1)}


func _poster(st: SurfaceTool, p: Array) -> Dictionary:
	var width: float = p[7]
	var height: float = width * DecorPlan.CELL.y / (DecorPlan.CELL.x * p[3])
	var f := _wall_frame(p[4], p[5], p[6], DecorPlan.POSTER_OFFSET + 0.002)
	var frame := _wall_frame(p[4], p[5], p[6], DecorPlan.POSTER_OFFSET * 0.5)
	# frame: a dark box a little larger than the print
	var bm := BoxMesh.new()
	bm.size = Vector3(width + 0.1, height + 0.1, DecorPlan.POSTER_OFFSET)
	var fb := Basis(f.r, Vector3.UP, f.n)  # local x = right, y = up, z = out of the wall
	_add_mesh(st, bm, Transform3D(fb, frame.c), Color(0.13, 0.07, 0.04))
	# print
	var u0: float = p[1] * DecorPlan.CELL.x / DecorPlan.ATLAS_SIZE.x
	var u1: float = (p[1] + p[3]) * DecorPlan.CELL.x / DecorPlan.ATLAS_SIZE.x
	var v0: float = p[2] * DecorPlan.CELL.y / DecorPlan.ATLAS_SIZE.y
	var v1: float = (p[2] + 1) * DecorPlan.CELL.y / DecorPlan.ATLAS_SIZE.y
	var hw: Vector3 = f.r * (width * 0.5)
	var hh: Vector3 = Vector3.UP * (height * 0.5)
	var tl: Vector3 = f.c - hw + hh
	var tr: Vector3 = f.c + hw + hh
	var br: Vector3 = f.c + hw - hh
	var bl: Vector3 = f.c - hw - hh
	_quad(st, [tl, tr, br, bl], [Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)], f.n)
	var along: float = p[5]
	var wall_rect := Rect2(along - width * 0.5, p[6] - height * 0.5, width, height)
	return {id = p[0], model = "poster", kind = &"poster", wall = p[4], wall_rect = wall_rect, tris = 14}


func _dartboard(st: SurfaceTool) -> Dictionary:
	var d := DecorPlan.DARTBOARD
	var f := _wall_frame(d.wall, d.along, d.y, DecorPlan.POSTER_OFFSET + 0.002)
	var r: float = d.diameter * 0.5
	var cell: Vector2 = d.cell
	var cu := (cell.x * DecorPlan.CELL.x + 128.0) / DecorPlan.ATLAS_SIZE.x
	var cv := (cell.y * DecorPlan.CELL.y + 128.0) / DecorPlan.ATLAS_SIZE.y
	var ru := 128.0 / DecorPlan.ATLAS_SIZE.x
	var rv := 128.0 / DecorPlan.ATLAS_SIZE.y
	var seg := 32
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var p0: Vector3 = f.c + f.r * (cos(a0) * r) + Vector3.UP * (sin(a0) * r)
		var p1: Vector3 = f.c + f.r * (cos(a1) * r) + Vector3.UP * (sin(a1) * r)
		_tri(st, [f.c, p1, p0], [Vector2(cu, cv), Vector2(cu + cos(a1) * ru, cv - sin(a1) * rv), Vector2(cu + cos(a0) * ru, cv - sin(a0) * rv)], f.n)
	var wall_rect := Rect2(d.along - r, d.y - r, d.diameter, d.diameter)
	return {id = &"dartboard", model = "dartboard", kind = &"poster", wall = d.wall, wall_rect = wall_rect, tris = seg}


func _tri(st: SurfaceTool, pts: Array, uvs: Array, normal: Vector3) -> void:
	for i in 3:
		st.set_color(Color.WHITE)
		st.set_uv(uvs[i])
		st.set_normal(normal)
		st.add_vertex(pts[i])


func _quad(st: SurfaceTool, pts: Array, uvs: Array, normal: Vector3) -> void:  # tl, tr, br, bl; clockwise from the front
	_tri(st, [pts[0], pts[1], pts[2]], [uvs[0], uvs[1], uvs[2]], normal)
	_tri(st, [pts[0], pts[2], pts[3]], [uvs[0], uvs[2], uvs[3]], normal)


## A primitive mesh as untextured decor (white atlas texel, `color` from the vertex colour).
func _add_mesh(st: SurfaceTool, m: PrimitiveMesh, xf: Transform3D, color: Color) -> void:
	var a := m.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	for i in a[Mesh.ARRAY_INDEX]:
		st.set_color(color)
		st.set_uv(DecorPlan.WHITE_UV)
		st.set_normal(xf.basis * nrm[i])
		st.add_vertex(xf * v[i])


## Floor items vs DecorPlan.floor_keep_clear (kind floor; flat only vs door + table band), posters vs wall_keep_clear.
func _keep_clear_violations(items: Array[Dictionary]) -> Array[String]:
	var bad: Array[String] = []
	var floor_rects := DecorPlan.floor_keep_clear()
	var walls := DecorPlan.wall_keep_clear()
	for info: Dictionary in items:
		match info.kind:
			&"floor":
				for r in floor_rects:
					if (info.rect as Rect2).intersects(r):
						bad.append("%s %s hits floor rect %s" % [info.id, info.rect, r])
			&"flat":
				for r in [floor_rects[0], floor_rects[1]]:
					if (info.rect as Rect2).intersects(r):
						bad.append("%s %s hits %s" % [info.id, info.rect, r])
			&"poster":
				for r: Rect2 in walls.get(info.wall, []):
					if (info.wall_rect as Rect2).intersects(r):
						bad.append("%s %s hits wall rect %s on %s" % [info.id, info.wall_rect, r, info.wall])
	return bad
