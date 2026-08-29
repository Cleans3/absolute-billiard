extends SceneTree

## One-shot generator for the Player skeleton. Run headless, then delete.

const SCENE := "res://src/gameplay/player/Player.tscn"

# bone name, parent bone, rest offset from parent (metres, -Z forward, +X right)
const BONES := [
	["Hips", "", Vector3(0, 0.95, 0)],
	["Spine", "Hips", Vector3(0, 0.2, 0)],
	["Chest", "Spine", Vector3(0, 0.2, 0)],
	["Neck", "Chest", Vector3(0, 0.17, 0)],
	["Head", "Neck", Vector3(0, 0.1, 0)],
	["UpperArm.L", "Chest", Vector3(-0.17, 0.1, 0)],
	["LowerArm.L", "UpperArm.L", Vector3(0, -0.28, 0)],
	["Hand.L", "LowerArm.L", Vector3(0, -0.25, 0)],
	["UpperArm.R", "Chest", Vector3(0.17, 0.1, 0)],
	["LowerArm.R", "UpperArm.R", Vector3(0, -0.28, 0)],
	["Hand.R", "LowerArm.R", Vector3(0, -0.25, 0)],
	["UpperLeg.L", "Hips", Vector3(-0.09, -0.05, 0)],
	["LowerLeg.L", "UpperLeg.L", Vector3(0, -0.42, 0)],
	["Foot.L", "LowerLeg.L", Vector3(0, -0.4, 0)],
	["UpperLeg.R", "Hips", Vector3(0.09, -0.05, 0)],
	["LowerLeg.R", "UpperLeg.R", Vector3(0, -0.42, 0)],
	["Foot.R", "LowerLeg.R", Vector3(0, -0.4, 0)],
]


func _initialize() -> void:
	var player: Node3D = load(SCENE).instantiate()

	for stale_path in ["Head/headMesh", "Skeleton3D"]:
		var stale := player.get_node_or_null(stale_path)
		if stale:
			stale.get_parent().remove_child(stale)
			stale.queue_free()

	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	player.add_child(skeleton)

	for bone: Array in BONES:
		skeleton.add_bone(bone[0])
	for bone: Array in BONES:
		var idx := skeleton.find_bone(bone[0])
		if not bone[1].is_empty():
			skeleton.set_bone_parent(idx, skeleton.find_bone(bone[1]))
		skeleton.set_bone_rest(idx, Transform3D(Basis(), bone[2]))
	skeleton.reset_bone_poses()

	for bone_name: String in _limbs():
		var mesh: Mesh = _limbs()[bone_name][0]
		var offset: Vector3 = _limbs()[bone_name][1]

		var attachment := BoneAttachment3D.new()
		attachment.name = "Attach_" + bone_name.replace(".", "_")
		attachment.bone_name = bone_name
		skeleton.add_child(attachment)

		var instance := MeshInstance3D.new()
		instance.name = bone_name.replace(".", "_")
		instance.mesh = mesh
		instance.position = offset
		# Own head would fill the first-person camera; keep it only for shadows.
		if bone_name == "Head":
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		attachment.add_child(instance)

	for node: Node in _descendants(skeleton):
		node.owner = player
	skeleton.owner = player

	var packed := PackedScene.new()
	packed.pack(player)
	var err := ResourceSaver.save(packed, SCENE)
	print("save: ", error_string(err), " bones: ", skeleton.get_bone_count())
	quit()


func _limbs() -> Dictionary:
	return {
		"Hips": [_box(Vector3(0.26, 0.2, 0.16)), Vector3(0, 0.1, 0)],
		"Spine": [_box(Vector3(0.28, 0.2, 0.16)), Vector3(0, 0.1, 0)],
		"Chest": [_box(Vector3(0.32, 0.17, 0.17)), Vector3(0, 0.085, 0)],
		"Neck": [_capsule(0.045, 0.1), Vector3(0, 0.05, 0)],
		"Head": [_sphere(0.095, 0.23), Vector3(0, 0.1, 0)],
		"UpperArm.L": [_capsule(0.045, 0.28), Vector3(0, -0.14, 0)],
		"LowerArm.L": [_capsule(0.04, 0.25), Vector3(0, -0.125, 0)],
		"Hand.L": [_box(Vector3(0.055, 0.14, 0.03)), Vector3(0, -0.07, 0)],
		"UpperArm.R": [_capsule(0.045, 0.28), Vector3(0, -0.14, 0)],
		"LowerArm.R": [_capsule(0.04, 0.25), Vector3(0, -0.125, 0)],
		"Hand.R": [_box(Vector3(0.055, 0.14, 0.03)), Vector3(0, -0.07, 0)],
		"UpperLeg.L": [_capsule(0.065, 0.42), Vector3(0, -0.21, 0)],
		"LowerLeg.L": [_capsule(0.055, 0.4), Vector3(0, -0.2, 0)],
		"Foot.L": [_box(Vector3(0.09, 0.06, 0.24)), Vector3(0, -0.03, -0.06)],
		"UpperLeg.R": [_capsule(0.065, 0.42), Vector3(0, -0.21, 0)],
		"LowerLeg.R": [_capsule(0.055, 0.4), Vector3(0, -0.2, 0)],
		"Foot.R": [_box(Vector3(0.09, 0.06, 0.24)), Vector3(0, -0.03, -0.06)],
	}


func _descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_descendants(child))
	return out


func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 8
	mesh.rings = 2
	return mesh


func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


func _sphere(radius: float, height: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.rings = 6
	return mesh
