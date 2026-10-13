extends SceneTree
## The Bartender's real face (06 P48): a CC0 mesh on the head bone through a BoneAttachment3D, the modelled face not painted, one
## StandardMaterial3D (not the humanoid shader), within the 2k-triangle budget, and on the head surface's render layers: the local player's
## camera culls it in first person, the wall mirror's window pass draws it. Runs through the real MainLevel (solo).
##   godot --path . --headless -s tests/player/barkeep_face_probe.gd
## Prints BARKEEP FACE OK, or the failing checks and BARKEEP FACE FAIL (exit 1).

const MAX_TRIS := 2000
const FACE_LAYERS := 1 | Humanoid.MIRROR_LAYER

var fails := 0
var finished := false


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("BARKEEP FACE FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame  # the NetManager autoload joins the tree
	SaveManager.root = "user://test_barkeep_face"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	var bartender := level.get_node("Bar/Bartender") as Bartender
	var h := bartender._humanoid
	var skel := h.get_node("Skeleton") as Skeleton3D
	await _frames(5)

	# the face: a BoneAttachment3D on the head bone, one mesh, one StandardMaterial3D
	var att := skel.get_node_or_null(BarkeepFace.FACE_NAME) as BoneAttachment3D
	_check(att != null, "the Bartender wears a BarkeepFace attachment under the skeleton")
	if att == null:
		print("BARKEEP FACE FAIL (no face)")
		quit(1)
		return
	_check(att.bone_name == BarkeepFace.HEAD_BONE and skel.find_bone(att.bone_name) == Humanoid.B.HEAD, "it sits on the HEAD bone")
	var face := att.get_child(0) as MeshInstance3D
	_check(face != null and face.mesh != null and face.mesh.get_surface_count() == 1, "one mesh, one surface")
	var arrays := face.mesh.surface_get_arrays(0)
	var tris := (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	_check(tris > 500 and tris <= MAX_TRIS, "triangles within the budget (%d <= %d)" % [tris, MAX_TRIS])
	_check(face.material_override is StandardMaterial3D, "its own StandardMaterial3D, not the humanoid shader")
	var mat := face.material_override as StandardMaterial3D
	_check(mat != null and mat.albedo_texture != null and mat.albedo_texture.get_width() <= 512, "textured with a small atlas (%s)" % [mat.albedo_texture.get_size() if mat != null and mat.albedo_texture != null else "none"])
	_check(not (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).is_empty() and not (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).is_empty(), "UVs and normals present")

	# where: the head, facing -Z like the Humanoid, over the neck and under the hat
	var box := face.global_transform * face.mesh.get_aabb()
	var rel := box.position - h.global_position
	_check(rel.y > 1.42 and rel.y < 1.52 and rel.y + box.size.y > 1.70 and rel.y + box.size.y < 1.85, "it spans the head (y %.2f..%.2f above the feet)" % [rel.y, rel.y + box.size.y])
	_check(box.size.x < 0.5 and box.size.z < 0.5, "it is head-sized (%.2f x %.2f m)" % [box.size.x, box.size.z])
	var nose := Vector3.ZERO
	var nose_z := 1e9
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for v in verts:
		if v.z < nose_z:
			nose_z = v.z
			nose = v
	_check(nose_z < -0.17 and absf(nose.x) < 0.07, "the front-most point (nose/mustache) faces -Z, centred (z %.2f, x %.2f)" % [nose_z, nose.x])

	# the modelled face is not painted: the head surface is the hat, neck and nothing else
	var with_face := _verts(h._head_mi.mesh)
	h.set_face(null)
	var modelled := _verts(h._head_mi.mesh)
	h.set_face(face)
	_check(with_face < modelled * 0.5, "the head surface drops the modelled head, eyes, brows, nose and mustache (%d vs %d vertices)" % [with_face, modelled])
	_check(_verts(h._head_mi.mesh) == with_face, "set_face is repeatable")

	# the skin matches the face
	var skin := bartender.skin.skin_color
	_check(absf(skin.r - BarkeepFace.SKIN.r) < 0.01 and absf(skin.g - BarkeepFace.SKIN.g) < 0.01 and absf(skin.b - BarkeepFace.SKIN.b) < 0.01, "the Bartender's skin colour is the atlas' skin colour")

	# layers: the head surface's, both ways
	_check(face.layers == FACE_LAYERS and h._head_mi.layers == FACE_LAYERS, "third person: layer 1 + the mirror layer (%d)" % face.layers)
	h.set_first_person(true)
	_check(face.layers == Humanoid.HEAD_LAYER and face.layers == h._head_mi.layers, "first person: HEAD_LAYER like the head surface (%d)" % face.layers)
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	_check(player.cam.cull_mask & face.layers == 0, "the local player's camera culls HEAD_LAYER: a first-person face is not drawn")
	var mirror := level.get_node("Mirror") as Mirror
	_check(mirror._cam.cull_mask & face.layers != 0, "the mirror's window pass draws HEAD_LAYER")
	h.set_first_person(false)
	_check(face.layers == FACE_LAYERS and mirror._cam.cull_mask & face.layers != 0, "back in third person the mirror draws it (layers %d)" % face.layers)
	_check(player.cam.cull_mask & face.layers != 0, "and so does the player's camera")

	# it follows the head: a head turn moves it with the bone
	bartender.set_process(false)  # his own idle look would overwrite the turn
	var before := face.global_transform.basis * Vector3.FORWARD
	h.set_look(0.9, 0.0)
	await _frames(40)
	var after := face.global_transform.basis * Vector3.FORWARD
	_check(before.angle_to(after) > 0.4, "the face turns with the head (%.2f rad)" % before.angle_to(after))
	h.set_look(0.0, 0.0)
	bartender.set_process(true)

	# its source is on record
	var credits := FileAccess.get_file_as_string("res://assets/CREDITS.md")
	_check(credits.contains("poly.pizza/m/imEy3Tqg80") and credits.contains("CC0") and credits.contains("sha256"), "assets/CREDITS.md names the face's source, licence and sha256")

	finished = true
	print("BARKEEP FACE OK" if fails == 0 else "BARKEEP FACE FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _verts(m: Mesh) -> int:
	var n := 0
	for i in m.get_surface_count():
		n += (m.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return n
