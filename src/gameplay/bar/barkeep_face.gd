class_name BarkeepFace
extends RefCounted
## The Bartender's real face (06 P48): a CC0 low-poly head with brows, eyes, a nose and a grey handlebar mustache, on a BoneAttachment3D under
## the Humanoid's head bone, like CrewDress's pieces. Source and licence: assets/CREDITS.md; rebuilt by src/tools/build_barkeep_face.gd.
## One mesh (~1.3k triangles), one StandardMaterial3D that mirrors humanoid.gdshader's look so the face matches the neck and hands.
## `Humanoid.set_face` stops painting the modelled head and puts this mesh on the head surface's render layers (local camera / mirror).

const HEAD_BONE := "head"
const FACE_NAME := "BarkeepFace"
const MESH := "res://assets/models/barkeep_face/barkeep_face.res"
const ATLAS := "res://assets/models/barkeep_face/barkeep_face.png"
## The atlas' skin colour (sRGB): the Bartender's `skin_color` is set to it so the neck and hands match the face.
const SKIN := Color("ffdc9f")

static var _material: StandardMaterial3D


## Puts the face on `h`'s head bone. Returns the attachment (free it to take the face off; `h.set_face(null)` brings the modelled one back),
## or null if the body has no skeleton yet (not in the tree).
static func attach(h: Humanoid) -> BoneAttachment3D:
	var skel := h.get_node_or_null(^"Skeleton") as Skeleton3D
	if skel == null:
		return null
	var old := skel.get_node_or_null(FACE_NAME)
	if old != null:
		old.free()
	var att := BoneAttachment3D.new()
	att.name = FACE_NAME
	att.bone_name = HEAD_BONE
	skel.add_child(att)
	var mi := MeshInstance3D.new()
	mi.mesh = load(MESH) as Mesh
	mi.material_override = material()
	att.add_child(mi)
	h.set_face(mi)
	return att


## humanoid.gdshader in StandardMaterial terms: the atlas x 0.5 sRGB (0.214 linear) as albedo, and the same colour as a 0.9 fill emission, so the
## side of the face the lamps miss reads as dim colour, not black (06 P26).
static func material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		var atlas := load(ATLAS) as Texture2D
		_material.albedo_texture = atlas
		_material.albedo_color = Color(0.5, 0.5, 0.5)
		_material.emission_enabled = true
		_material.emission_texture = atlas
		_material.emission_energy_multiplier = 0.214 * 0.9
		_material.roughness = 0.85
		_material.metallic_specular = 0.2
	return _material
