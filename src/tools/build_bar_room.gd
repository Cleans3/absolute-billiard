extends SceneTree

## One-shot: regenerates src/gameplay/bar_room/{meshes,materials}/* and BarRoom.tscn (04 §2.2, 07 §2).
## Static greybox merged by material (8 MeshInstance3D), UV2 unwrapped for LightmapGI, layer-4 collision, BarRoom script on the root.
## Plus `Decor`: every prop and poster of DecorPlan merged into ONE static mesh with ONE material (the poster atlas, vertex colour
## for untextured props), CC0 glb read from assets/third_party/ and never shipped.
##   godot --path . --headless -s src/tools/build_bar_room.gd
## Then bake with src/tools/bake_lightmaps.gd (needs a GPU window).

const DIR := "res://src/gameplay/bar_room/"
const HALF := 7.0       # interior half-extent in x and z (matches the old CSG walls)
const CEIL := 3.6
const TEXEL := 0.15     # xatlas texel size in metres
# Bar counter, contract §6: off the east wall so a bartender fits behind it. The aisle floor is x 5.5-6.6.
const COUNTER_BODY_X := 5.15   # body x 4.85-5.45
const COUNTER_TOP_X := 5.1     # top x 4.7-5.5 (also the collision box)
const BACKBAR_X := 6.8         # shelves + cabinet x 6.6-7.0, flush to the east wall
const STOOL_X := 4.3

var _mats := {}


func _init() -> void:
	call_deferred("_run")


func _mat(id: String, albedo: Color, rough := 0.85, metal := 0.0, emit := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	m.resource_name = id
	ResourceSaver.save(m, DIR + "materials/%s.tres" % id)
	m.take_over_path(DIR + "materials/%s.tres" % id)
	_mats[id] = m
	return m


func _st(mat: StandardMaterial3D) -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	return st


func _box(st: SurfaceTool, center: Vector3, size: Vector3, yaw_deg := 0.0) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	st.append_from(bm, 0, Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), center))


func _cyl(st: SurfaceTool, center: Vector3, radius: float, height: float, seg := 14) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = seg
	cm.rings = 1
	st.append_from(cm, 0, Transform3D(Basis.IDENTITY, center))


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
	var floor_m := _mat("floor", Color(0.20, 0.12, 0.075), 0.55)
	var wall_m := _mat("wall", Color(0.30, 0.17, 0.15), 0.92)
	var ceil_m := _mat("ceiling", Color(0.11, 0.085, 0.075), 0.95)
	var wood_m := _mat("wood", Color(0.24, 0.13, 0.06), 0.6)
	var wainscot_m := _mat("wainscot", Color(0.24, 0.13, 0.06), 0.6)  # own material so a BarSkin can tint it apart from the wood
	var seat_m := _mat("seat", Color(0.42, 0.09, 0.08), 0.5)
	var prop_m := _mat("prop", Color(0.16, 0.16, 0.18), 0.4, 0.5)
	var pink_m := _mat("neon_pink", Color.BLACK, 0.5, 0.0, Color(1.0, 0.15, 0.55), 3.0)
	var cyan_m := _mat("neon_cyan", Color.BLACK, 0.5, 0.0, Color(0.1, 0.85, 1.0), 3.0)
	var tv_m := _mat("tv_screen", Color.BLACK, 0.3, 0.0, Color(0.45, 0.6, 1.0), 2.2)
	var juke_m := _mat("jukebox_glass", Color.BLACK, 0.3, 0.0, Color(1.0, 0.6, 0.15), 2.5)

	# --- floor ---
	var s := _st(floor_m)
	_box(s, Vector3(0, -0.05, 0), Vector3(2 * HALF, 0.1, 2 * HALF))
	var floor_mesh := _bake_mesh("floor", [s])

	# --- walls (north wall has the door opening) ---
	s = _st(wall_m)
	var t := 0.2
	_box(s, Vector3(0, CEIL * 0.5, HALF + t * 0.5), Vector3(2 * HALF + 2 * t, CEIL, t))
	_box(s, Vector3(-HALF - t * 0.5, CEIL * 0.5, 0), Vector3(t, CEIL, 2 * HALF))
	_box(s, Vector3(HALF + t * 0.5, CEIL * 0.5, 0), Vector3(t, CEIL, 2 * HALF))
	var dw := 0.95  # half door width
	var seg_w := HALF - dw
	_box(s, Vector3(-(dw + seg_w * 0.5), CEIL * 0.5, -HALF - t * 0.5), Vector3(seg_w + t, CEIL, t))
	_box(s, Vector3(dw + seg_w * 0.5, CEIL * 0.5, -HALF - t * 0.5), Vector3(seg_w + t, CEIL, t))
	_box(s, Vector3(0, (2.3 + CEIL) * 0.5, -HALF - t * 0.5), Vector3(2 * dw, CEIL - 2.3, t))
	var walls_mesh := _bake_mesh("walls", [s])

	# --- ceiling + beams ---
	s = _st(ceil_m)
	_box(s, Vector3(0, CEIL + 0.05, 0), Vector3(2 * HALF + 0.4, 0.1, 2 * HALF + 0.4))
	for bx in [-4.5, 0.0, 4.5]:
		_box(s, Vector3(bx, CEIL - 0.15, 0), Vector3(0.25, 0.3, 2 * HALF))
	var ceil_mesh := _bake_mesh("ceiling", [s])

	# --- wood: bar counter + back shelf + wainscot + tables + door + door frame ---
	s = _st(wood_m)
	var sw := _st(wainscot_m)
	var counter_z0 := 0.5
	var counter_len := 4.0
	var cz := counter_z0 + counter_len * 0.5
	_box(s, Vector3(COUNTER_BODY_X, 0.5, cz), Vector3(0.6, 1.0, counter_len))  # body
	_box(s, Vector3(COUNTER_TOP_X, 1.04, cz), Vector3(0.8, 0.08, counter_len + 0.2))  # top
	_box(s, Vector3(BACKBAR_X, 0.5, cz), Vector3(0.4, 1.0, counter_len))       # back-bar cabinet
	_box(s, Vector3(BACKBAR_X, 1.55, cz), Vector3(0.4, 0.06, counter_len))     # shelf low
	_box(s, Vector3(BACKBAR_X, 2.05, cz), Vector3(0.4, 0.06, counter_len))     # shelf high
	_box(s, Vector3(6.9, 1.6, cz), Vector3(0.2, 3.2, counter_len))             # back-bar panel
	for wz in [-HALF + 0.03, HALF - 0.03]:
		_box(sw, Vector3(0, 0.55, wz), Vector3(2 * HALF, 1.1, 0.06))           # wainscot N/S
	_box(sw, Vector3(-HALF + 0.03, 0.55, 0), Vector3(0.06, 1.1, 2 * HALF))
	for tp in [Vector3(-5.2, 0.0, 2.6), Vector3(-5.2, 0.0, 4.4), Vector3(-2.8, 0.0, 5.6)]:
		_cyl(s, tp + Vector3(0, 0.98, 0), 0.5, 0.06, 18)                       # round table top
	_box(s, Vector3(0, 1.15, -HALF + 0.05), Vector3(2 * dw - 0.1, 2.3, 0.08))  # door slab (closed)
	_box(s, Vector3(0, 2.36, -HALF + 0.06), Vector3(2 * dw + 0.3, 0.12, 0.1))  # door frame head
	var wood_mesh := _bake_mesh("wood", [s, sw])

	# --- seats: bar stools at the counter, one at the origin (kick_stool), round-table stools ---
	s = _st(seat_m)
	var stools: Array[Vector3] = [Vector3(0, 0, 0)]
	for z in [1.0, 2.0, 3.0, 4.0]:
		stools.append(Vector3(STOOL_X, 0, z))
	for tp in [Vector3(-5.2, 0, 2.6), Vector3(-5.2, 0, 4.4), Vector3(-2.8, 0, 5.6)]:
		stools.append(tp + Vector3(0.75, 0, 0))
		stools.append(tp + Vector3(-0.75, 0, 0))
	for p in stools:
		_cyl(s, p + Vector3(0, 0.75, 0), 0.22, 0.09, 14)
	var seat_mesh := _bake_mesh("seats", [s])

	# --- props: stool posts, table posts, jukebox body, TV frame, fuse box, lamp shade, bottles ---
	s = _st(prop_m)
	for p in stools:
		_cyl(s, p + Vector3(0, 0.375, 0), 0.05, 0.75, 8)
		_cyl(s, p + Vector3(0, 0.02, 0), 0.24, 0.04, 12)
	for tp in [Vector3(-5.2, 0.0, 2.6), Vector3(-5.2, 0.0, 4.4), Vector3(-2.8, 0.0, 5.6)]:
		_cyl(s, tp + Vector3(0, 0.48, 0), 0.06, 0.96, 8)
		_cyl(s, tp + Vector3(0, 0.02, 0), 0.32, 0.04, 12)
	_box(s, Vector3(6.55, 0.95, 5.8), Vector3(0.75, 1.9, 1.1))                 # jukebox body
	_box(s, Vector3(0, 2.1, HALF - 0.06), Vector3(2.5, 1.5, 0.12))             # TV frame (south wall)
	_box(s, Vector3(-HALF + 0.08, 1.4, 5.8), Vector3(0.16, 0.5, 0.35))        # fuse box (flick_lights)
	_cyl(s, Vector3(0, 3.05, -3.5), 0.55, 0.22, 18)                            # lamp shade over the table
	_box(s, Vector3(0, 3.3, -3.5), Vector3(0.04, 0.6, 0.04))                   # lamp rod
	for i in 14:
		_box(s, Vector3(6.75, 1.55 + 0.06 + 0.14, counter_z0 + 0.3 + i * 0.27), Vector3(0.09, 0.28, 0.09))
		if i % 2 == 0:
			_box(s, Vector3(6.75, 2.05 + 0.06 + 0.12, counter_z0 + 0.3 + i * 0.27), Vector3(0.08, 0.24, 0.08))
	var prop_mesh := _bake_mesh("props", [s])

	# --- neon (two surfaces) ---
	var sp := _st(pink_m)
	var sc := _st(cyan_m)
	_box(sp, Vector3(-HALF + 0.08, 2.4, 1.5), Vector3(0.05, 0.07, 2.2))       # west wall sign, bars
	_box(sp, Vector3(-HALF + 0.08, 2.15, 1.5), Vector3(0.05, 0.07, 1.6))
	_box(sp, Vector3(-HALF + 0.08, 1.9, 1.5), Vector3(0.05, 0.07, 2.2))
	_box(sc, Vector3(-3.0, 3.0, -HALF + 0.08), Vector3(2.4, 0.07, 0.05))      # north wall sign over the door side
	_box(sc, Vector3(-3.0, 2.7, -HALF + 0.08), Vector3(2.4, 0.07, 0.05))
	_box(sc, Vector3(3.0, 2.85, -HALF + 0.08), Vector3(0.07, 0.6, 0.05))
	_box(sp, Vector3(3.0, 2.85, -HALF + 0.08), Vector3(1.6, 0.07, 0.05))
	var neon_mesh := _bake_mesh("neon", [sp, sc])

	# --- screens (two surfaces): TV and jukebox glass ---
	var stv := _st(tv_m)
	var sj := _st(juke_m)
	_box(stv, Vector3(0, 2.1, HALF - 0.14), Vector3(2.3, 1.3, 0.04))
	_box(sj, Vector3(6.17, 1.35, 5.8), Vector3(0.05, 0.9, 0.8))
	var screen_mesh := _bake_mesh("screens", [stv, sj])

	# --- decor: props + posters, one mesh, one material (adhoc-1010a C10/C18) ---
	var decor := _build_decor()

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
	for tp in [Vector3(-5.2, 0.0, 2.6), Vector3(-5.2, 0.0, 4.4), Vector3(-2.8, 0.0, 5.6)]:
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
	spot.shadow_bias = 0.04
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
# Decor (DecorPlan): props from CC0 glb + posters, merged into one static mesh with the poster atlas as its only material.
# ---------------------------------------------------------------------------------------------------------------------

## -> {mesh: ArrayMesh, items: Array[Dictionary], boxes: Array[AABB], tris: int}. Aborts the run on a keep-clear violation.
func _build_decor() -> Dictionary:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "decor"
	mat.albedo_texture = load(DecorPlan.ATLAS_PATH)
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.9
	mat.metallic_specular = 0.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	ResourceSaver.save(mat, DIR + "materials/decor.tres")
	mat.take_over_path(DIR + "materials/decor.tres")
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	var items: Array[Dictionary] = []
	var boxes: Array[AABB] = []
	var tris := 0
	var models := {}
	for it: Array in DecorPlan.ITEMS:
		var key: String = "%s/%s" % [it[1], it[2]]
		if not models.has(key):
			models[key] = _load_model(it[1], it[2])
		var info := _place(st, models[key], it)
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
	return {mesh = _bake_mesh("decor", [st]), items = items, boxes = boxes, tris = tris}


func _add_decor(root_n: Node3D, decor: Dictionary) -> void:
	var holder := _add(root_n, Node3D.new(), "Decor")
	var mi := MeshInstance3D.new()
	mi.mesh = decor.mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(holder, mi, "Mesh")
	holder.set_meta("items", decor.items)  # data only (id, model, kind, footprint / wall rect, tris): what tests/world/bar_room_probe.gd reads
	print("decor: %d items, %d tris, %d colliders" % [decor.items.size(), decor.tris, decor.boxes.size()])


## One glb -> {surfaces: [{verts, normals, indices, colors}], min: Vector3, max: Vector3} in model space.
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
				colors.append(c * DecorPlan.PROP_TINT)
				out.min = out.min.min(v)
				out.max = out.max.max(v)
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(src_v.size()))
			out.surfaces.append({verts = verts, normals = normals, indices = idx, colors = colors})
	scene.free()
	return out


## Adds one DecorPlan item to `st`; returns {id, model, kind, rect (xz footprint), height, tris}.
func _place(st: SurfaceTool, model: Dictionary, it: Array) -> Dictionary:
	var scale: float = DecorPlan.PACKS[it[1]].scale * (it[6] if it.size() > 6 else 1.0)
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
		for i in sf.indices:
			var p := pos + rot * ((v[i] - centre) * scale)
			st.set_color(sf.colors[i])
			st.set_uv(DecorPlan.WHITE_UV)
			st.set_normal(rot * sf.normals[i])
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
