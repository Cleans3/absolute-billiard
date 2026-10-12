extends SceneTree
## Bar room polish (06 P13/P14/P17/P18): no fog planes, the counter stands off the wall with a >= 1 m aisle and a
## free bartender spot, BarSkin recolours the shared materials, Table felt, and the camera rig is a real 3-surface model.
## adhoc-1010a C10/C18: the Decor mesh (one draw call, one material), >= 12 distinct props + >= 6 posters, keep-clear zones, licences.
## adhoc-1012a art: PBR texture sets (VRAM-compressed, mipmapped, licensed, world-mapped UVs) and the 07 §2 material budget.
##   godot --path . --headless -s tests/world/bar_room_probe.gd

const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const SKINS_DIR := "res://src/resources/skins/bars/"
const WORLD_MASK := 8  # 07 §1 layer 4

var _fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	var room: BarRoom = ROOM.instantiate()
	root.add_child(room)
	for i in 3:
		await physics_frame
	_fog(room)
	_aisle(room)
	_decor(room)
	_skins(room)
	await _felt()
	await _rig()
	if _fails > 0:
		printerr("BAR ROOM PROBE FAILED: %d" % _fails)
		quit(1)
		return
	print("BAR ROOM OK")
	quit()


## P13: nothing in the room is a fog plane (a node named Fog*, or a ShaderMaterial on any room mesh).
func _fog(room: Node) -> void:
	var found: Array[String] = []
	for n in room.find_children("*", "", true, false):
		if String(n.name).containsn("fog") and not n is WorldEnvironment:
			found.append(String(n.name))
		var mi := n as MeshInstance3D
		if mi != null and (mi.material_override is ShaderMaterial or mi.get_surface_override_material_count() > 0 and mi.get_surface_override_material(0) is ShaderMaterial):
			found.append(String(n.name) + " (shader)")
	_check(found.is_empty(), "no fog planes in the room: %s" % [found])
	_check(not ResourceLoader.exists("res://src/shaders/fog_plane.gdshader"), "fog_plane shader is gone")
	var env := (room.get_node("WorldEnvironment") as WorldEnvironment).environment
	_check(env.fog_enabled, "the Environment's depth fog stays")


## 06 contract §6: counter x 4.7-5.5, aisle 5.5-6.6 behind it (>= 1.0 m), a player capsule (r 0.3) fits and stands at (6.0, 0, 2.5).
func _aisle(room: Node) -> void:
	var space := (room as Node3D).get_world_3d().direct_space_state
	for z in [0.7, 1.5, 2.5, 3.5, 4.3]:
		var west := _ray(space, Vector3(6.0, 0.9, z), Vector3(3.0, 0.9, z))
		var east := _ray(space, Vector3(6.0, 0.9, z), Vector3(7.5, 0.9, z))
		var head := _ray(space, Vector3(6.0, 1.7, z), Vector3(7.5, 1.7, z))  # the shelves are collision-bounded too
		_check(not west.is_empty() and not east.is_empty() and not head.is_empty(), "aisle rays hit the counter and the back bar at z=%.1f" % z)
		if west.is_empty() or east.is_empty() or head.is_empty():
			continue
		var x_counter: float = west.position.x
		_check(x_counter <= 5.5 + 0.001, "counter collision stays out of the aisle (east face %.3f)" % x_counter)
		_check(x_counter >= 5.4, "counter east face is where the contract puts it, not further in (%.3f)" % x_counter)
		_check(east.position.x - x_counter >= 1.0, "aisle >= 1.0 m wide at z=%.1f: %.3f" % [z, east.position.x - x_counter])
		_check(head.position.x >= 6.6 - 0.001, "back bar stays on the wall at head height (%.3f)" % head.position.x)
	# control: the capsule query does see the counter
	_check(not _capsule_free(space, Vector3(5.15, 0.0, 2.5)), "a capsule inside the counter collides (query control)")
	_check(_capsule_free(space, Vector3(6.0, 0.0, 2.5)), "a player capsule stands at the bartender point (6.0, 0, 2.5)")
	for z in [0.9, 1.7, 2.5, 3.3, 4.1]:
		_check(_capsule_free(space, Vector3(6.05, 0.0, z)), "a capsule fits the aisle at z=%.1f" % z)
	for p: Array in Bar.PROPS:
		if p[0] in [&"bar_buy", &"bar_serve", &"throw_drink"]:
			_check((p[1] as Vector3).is_equal_approx(Vector3(4.2, 0.0, 2.5)), "%s sits on the customer side at (4.2, 0, 2.5)" % p[0])


## adhoc-1010a C10/C18 (docs/plan/07 §2 decor row): what the generator baked, checked against what must stay clear.
func _decor(room: BarRoom) -> void:
	var decor := room.get_node_or_null("Decor")
	_check(decor != null, "Decor node exists next to Geometry (not inside it: BarSkin walks Geometry's surfaces)")
	if decor == null:
		return
	var mi := decor.get_node("Mesh") as MeshInstance3D
	_check(mi.mesh.get_surface_count() == 1, "decor is ONE surface (one draw call): %d" % mi.mesh.get_surface_count())
	var mat := mi.mesh.surface_get_material(0) as StandardMaterial3D
	_check(mat != null and mat.resource_name == "decor" and mat.albedo_texture != null and mat.vertex_color_use_as_albedo, "decor material: atlas texture + vertex colour")
	_check(mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC and mi.mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_TEX_UV2 != 0, "decor is static with UV2 (lives in the lightmap bake)")
	var tris: int = mi.mesh.surface_get_array_index_len(0) / 3
	_check(tris <= 8000, "decor stays under 8k triangles (07 budget slice): %d" % tris)
	var props := {}
	var posters := {}
	var walls := {}
	var floor_rects := DecorPlan.floor_keep_clear()
	var wall_rects := DecorPlan.wall_keep_clear()
	for it: Dictionary in decor.get_meta("items"):
		if it.kind == &"poster":
			posters[it.id] = true
			walls[it.wall] = true
			for r: Rect2 in wall_rects.get(it.wall, []):
				_check(not (it.wall_rect as Rect2).intersects(r), "poster %s clear of wall rect %s on %s" % [it.id, r, it.wall])
			continue
		props[it.model] = true
		if it.kind == &"floor":
			for r in floor_rects:
				_check(not (it.rect as Rect2).intersects(r), "%s %s clear of floor zone %s" % [it.id, it.rect, r])
		elif it.kind == &"flat":
			for r in [floor_rects[0], floor_rects[1]]:
				_check(not (it.rect as Rect2).intersects(r), "rug %s clear of the table band / door" % it.id)
	_check(props.size() >= 12, ">= 12 distinct prop models (C18): %d" % props.size())
	_check(posters.size() >= 6, ">= 6 distinct posters (C10): %d" % posters.size())
	_check(walls.size() == 4, "posters on all four walls: %s" % [walls.keys()])
	for pk: StringName in DecorPlan.PACKS:
		var dir: String = ProjectSettings.globalize_path("res://assets/third_party/%s/" % DecorPlan.PACKS[pk].dir)
		var has_license := false
		for f in DirAccess.get_files_at(dir):
			has_license = has_license or f.begins_with("LICENSE")
		_check(has_license, "%s ships its LICENSE beside the models" % pk)
	# floor props collide (layer 8): a ray from above lands on the sofa, not on the floor
	var hit := _ray(room.get_world_3d().direct_space_state, Vector3(5.6, 2.0, -6.55), Vector3(5.6, -0.2, -6.55))
	_check(not hit.is_empty() and hit.position.y > 0.3, "the NE sofa has a collider (hit y %.2f)" % (hit.position.y if not hit.is_empty() else -1.0))


## adhoc-1012a: the room's surfaces are PBR (albedo + ORM [+ normal]) and stay within the 12 materials of 07 §2; every set is
## imported VRAM-compressed with mipmaps (07 §8), has its licence beside it, and the floor is mapped in world metres (no stretch).
func _pbr(room: BarRoom) -> void:
	var mats := {}
	for mi: MeshInstance3D in room.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			mats[m.resource_name] = m
	_check(mats.size() <= 12, "the room uses <= 12 materials (07 §2): %d %s" % [mats.size(), mats.keys()])
	for id in [&"floor", &"wall", &"wainscot", &"ceiling", &"wood", &"seat", &"prop"]:
		var m := mats.get(String(id)) as ORMMaterial3D
		_check(m != null and m.albedo_texture != null and m.orm_texture != null, "%s is a PBR material (albedo + ORM)" % id)
		if m != null and id != &"ceiling":
			_check(m.normal_enabled and m.normal_texture != null, "%s has a normal map" % id)
	var dir := "res://assets/textures/"
	_check(FileAccess.file_exists(dir + "LICENSE.txt") and FileAccess.file_exists(dir + "SOURCE.md"), "the texture sets ship their licence and sources")
	var sets := 0
	for set_dir in DirAccess.get_directories_at(dir):
		sets += 1
		for f in DirAccess.get_files_at(dir + set_dir):
			if not f.ends_with(".import"):
				continue
			var txt := FileAccess.get_file_as_string(dir + set_dir + "/" + f)
			_check(txt.contains("compress/mode=2") and txt.contains("mipmaps/generate=true"), "%s/%s imports VRAM-compressed with mipmaps" % [set_dir, f])
			_check(txt.contains("compress/normal_map=1") == f.begins_with("normal"), "%s/%s: normal-map flag only on normals" % [set_dir, f])
	_check(sets >= 7, "at least the 7 room texture sets: %d" % sets)
	var fl := room.get_node("Geometry/Floor") as MeshInstance3D
	var uv: PackedVector2Array = fl.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in uv:
		lo = lo.min(p)
		hi = hi.max(p)
	_check(absf((hi.x - lo.x) - 7.0) < 0.6, "floor planks are mapped in world metres (14 m / 2 m tile = 7 repeats): %s" % (hi - lo))


## adhoc-1012a seam: the slot machine's spot (-6.3, 0, 1.5) on the west wall, 1.2 m clear in front, holds no collider; the
## keep-clear reach square (x -7.5..-5.1, z 0.3..2.7) is on DecorPlan so the generator refuses decor there.
func _slot_zone(room: BarRoom) -> void:
	var space := (room as Node3D).get_world_3d().direct_space_state
	for p in [Vector3(-6.3, 0.0, 1.5), Vector3(-5.6, 0.0, 1.5), Vector3(-5.2, 0.0, 1.1), Vector3(-6.3, 0.0, 2.0)]:
		_check(_capsule_free(space, p), "slot machine zone is free at %s" % p)
	_check(DecorPlan.floor_keep_clear().any(func(r: Rect2) -> bool: return r.encloses(Rect2(-7.5, 0.3, 2.4, 2.4))), "DecorPlan keeps the slot machine's reach square (x -7.5..-5.1, z 0.3..2.7) clear")


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, WORLD_MASK)
	return space.intersect_ray(q)


func _capsule_free(space: PhysicsDirectSpaceState3D, floor_pos: Vector3) -> bool:
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.75
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.collision_mask = WORLD_MASK
	q.transform = Transform3D(Basis.IDENTITY, floor_pos + Vector3(0, 0.875 + 0.06, 0))  # 6 cm up: not touching the floor box
	return space.intersect_shape(q, 1).is_empty()


func _skins(room: BarRoom) -> void:
	var skins: Array[BarSkin] = []
	for f in DirAccess.get_files_at(SKINS_DIR):
		if f.ends_with(".tres"):
			skins.append(load(SKINS_DIR + f) as BarSkin)
	_check(skins.size() >= 5, "at least 5 bar skins: %d" % skins.size())
	var ids := skins.map(func(s: BarSkin) -> StringName: return s.id)
	_check(ids.has(&"classic"), "a classic skin exists")
	var classic: BarSkin = load(SKINS_DIR + "classic.tres")
	# classic = the palette baked into the room by build_bar_room.gd
	var before := _palette(room)
	_check(before[&"wall"].is_equal_approx(classic.wall_color) and before[&"floor"].is_equal_approx(classic.floor_color)
			and before[&"wood"].is_equal_approx(classic.wood_color) and before[&"wainscot"].is_equal_approx(classic.wainscot_color)
			and before[&"seat"].is_equal_approx(classic.seat_color) and before[&"neon_pink"].is_equal_approx(classic.neon_a)
			and before[&"neon_cyan"].is_equal_approx(classic.neon_b), "classic skin is today's palette")
	for skin in skins:
		if skin.id == &"classic":
			continue
		room.apply_skin(skin)
		var now := _palette(room)
		_check(now[&"wall"].is_equal_approx(skin.wall_color) and now[&"wall"] != before[&"wall"], "%s recolours the walls" % skin.id)
		_check(now[&"floor"].is_equal_approx(skin.floor_color) and now[&"wood"].is_equal_approx(skin.wood_color)
				and now[&"wainscot"].is_equal_approx(skin.wainscot_color) and now[&"seat"].is_equal_approx(skin.seat_color), "%s sets floor/wood/wainscot/seat" % skin.id)
		_check(now[&"neon_pink"].is_equal_approx(skin.neon_a) and now[&"neon_cyan"].is_equal_approx(skin.neon_b), "%s sets both neon emissions" % skin.id)
	room.apply_skin(classic)
	var back := _palette(room)
	for k in before:
		_check((back[k] as Color).is_equal_approx(before[k]), "classic restores %s" % k)


## material resource_name -> the colour a skin drives (albedo, or emission for the neons).
func _palette(room: Node) -> Dictionary:
	var out := {}
	for mi: MeshInstance3D in room.get_node("Geometry").get_children():
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i) as BaseMaterial3D
			var id := StringName(m.resource_name)
			out[id] = m.emission if id in [&"neon_pink", &"neon_cyan"] else m.albedo_color
	return out


func _felt() -> void:
	var table: Table = TABLE.instantiate()
	root.add_child(table)
	await physics_frame
	var c := Color(0.1, 0.2, 0.55)
	table.set_felt_color(c)
	var cloth := table.get_node("Cloth") as MeshInstance3D
	_check((cloth.material_override as StandardMaterial3D).albedo_color.is_equal_approx(c), "set_felt_color recolours the cloth")
	table.rebuild()
	await physics_frame
	cloth = table.get_node("Cloth") as MeshInstance3D
	_check((cloth.material_override as StandardMaterial3D).albedo_color.is_equal_approx(c), "the felt survives a table rebuild")
	# adhoc-1012a: the felt has nap (albedo + normal), the wood parts share one PBR material, the table is <= 4 materials / meshes
	var felt := cloth.material_override as StandardMaterial3D
	_check(felt.albedo_texture != null and felt.normal_enabled and felt.normal_texture != null, "the felt carries its albedo + nap normal")
	var table_mats := {}
	for mi: MeshInstance3D in table.find_children("*", "MeshInstance3D", true, false):
		if mi.material_override != null:
			table_mats[mi.material_override] = true
	_check(table_mats.size() <= 4, "the table is <= 4 materials (felt, wood, rubber, liners): %d" % table_mats.size())
	var wood := table.get_node_or_null("Visual_wood") as MeshInstance3D
	_check(wood != null and wood.material_override is ORMMaterial3D, "rails / apron / legs are one wood PBR mesh")
	table.queue_free()


## P14: authored materials, <= 3 draw calls, not the engine default, not STATIC (no UV2).
func _rig() -> void:
	var rig := CameraRig.new()
	root.add_child(rig)
	await process_frame
	var model := rig.get_node("Model") as MeshInstance3D
	_check(model != null and model.mesh.get_surface_count() <= 3, "rig is one mesh, <= 3 surfaces")
	_check(model.gi_mode != GeometryInstance3D.GI_MODE_STATIC, "rig gi_mode is not STATIC (no UV2)")
	var emissive := 0
	for i in model.mesh.get_surface_count():
		var m := model.mesh.surface_get_material(i) as StandardMaterial3D
		_check(m != null, "rig surface %d has an authored material" % i)
		if m != null and m.emission_enabled:
			emissive += 1
	_check(emissive == 1, "exactly one emissive surface (the tally light)")
	_check(model.mesh.get_aabb().size.y > 1.4 and model.mesh.get_aabb().size.x > 0.8, "tripod spans the camera eye height and splays")
	rig.queue_free()
