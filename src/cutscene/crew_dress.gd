class_name CrewDress
extends RefCounted
## What the Rope puts on the crew, and how the cutscenes seat them (docs/plan/09 §3.8, §4.4). Each seat gets a gag, a blindfold or a
## hood, a pure function of the campaign seed and the seat so every peer dresses the same crew the same way (A9). The pieces are small
## meshes on a BoneAttachment3D under the Humanoid's head bone: humanoid.gd is not touched, the Humanoid does not know it is dressed.
## Seated crew are Humanoids with their physics process off (a moving parent must not read as walking) and the hands tied behind.

enum Kind { GAG, BLINDFOLD, HOOD }

const HEAD_BONE := "head"
const DRESS_NAME := "Dress"
## Head frame = the head bone's origin (the neck joint). The skull is an ellipsoid at (0, 0.12, 0), radii (0.10, 0.12, 0.11); the face looks -Z.
const CLOTH := Color("c9bfa0")
const RAG := Color("e6dfcc")
const BLIND := Color("141217")
const BURLAP := Color("8c6d45")
const ROPE := Color("3a2a1a")
const HAT_EXTRA := {&"cap": 0.03, &"beanie": 0.07, &"crown": 0.07, &"tophat": 0.11}  ## how much taller a hood must be to cover the hat

static var _material: ShaderMaterial


## Seat -> Kind. The bag always holds one of each plus a seeded extra, shuffled by the seed, so a full crew shows all three.
static func kind_for(seed_value: int, seat: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var bag: Array[int] = [Kind.GAG, Kind.BLINDFOLD, Kind.HOOD, rng.randi() % 3]
	for i in range(bag.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var keep := bag[i]
		bag[i] = bag[j]
		bag[j] = keep
	return bag[posmod(seat, bag.size())]


static func kind_name(kind: int) -> String:
	return ["gag", "blindfold", "hood"][clampi(kind, 0, 2)]


## `count` Humanoids (1-4) under `parent`, which must be in the tree. Skin per seat, else the seat's colour.
static func spawn(parent: Node3D, count: int, skins: Array[CharacterSkin]) -> Array[Humanoid]:
	var out: Array[Humanoid] = []
	for i in clampi(count, 1, 4):
		out.append(spawn_one(parent, i, skins[i] if i < skins.size() else null))
	return out


## One body for `seat`: its skin, else the seat's colour; physics process off (a moving parent must not read as walking).
static func spawn_one(parent: Node3D, seat: int, skin: CharacterSkin) -> Humanoid:
	var h := Humanoid.new()
	h.name = "Crew%d" % seat
	h.apply_skin(skin if skin != null else SkinCatalog.default_character(seat))
	parent.add_child(h)
	h.set_physics_process(false)  # after add_child: READY re-enables the process a script overrides
	return h


## Hands tied behind the back (the arm IK reaches a point behind the pelvis). Node space of the Humanoid.
static func tie_hands(h: Humanoid) -> void:
	h.set_hand(0, Vector3(0.07, 0.99, 0.17))
	h.set_hand(1, Vector3(-0.07, 0.99, 0.17))


## Puts `kind` on `h`'s head. Returns the attachment (free it to undress), or null if the body has no skeleton yet (not in the tree).
static func dress(h: Humanoid, kind: int) -> BoneAttachment3D:
	var skel := h.get_node_or_null(^"Skeleton") as Skeleton3D
	if skel == null:
		return null
	var old := skel.get_node_or_null(DRESS_NAME)
	if old != null:
		old.free()
	var hat: StringName = h.skin().hat if h.skin() != null else &"none"
	var soup := CutsceneKit.Soup.new()
	match kind:
		Kind.GAG:
			_gag(soup)
		Kind.BLINDFOLD:
			_blindfold(soup)
		_:
			_hood(soup, float(HAT_EXTRA.get(hat, 0.0)))
	var att := BoneAttachment3D.new()
	att.name = DRESS_NAME
	att.bone_name = HEAD_BONE
	skel.add_child(att)
	var mi := MeshInstance3D.new()
	mi.mesh = soup.mesh(dress_material())
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	att.add_child(mi)
	return att


## Same fabric as the bodies (humanoid.gdshader: sRGB vertex colours + a fill glow), so the pieces read in the cutscenes' dark.
static func dress_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load("res://src/shaders/humanoid.gdshader") as Shader
	return _material


static func _gag(s: CutsceneKit.Soup) -> void:
	s.cyl(Vector3(0.0, 0.045, 0.0), 0.045, Vector2(0.088, 0.096), Vector2(0.108, 0.118), 12, CLOTH, 0)
	s.box(Vector3(0.0, 0.075, -0.116), Vector3(0.036, 0.018, 0.014), RAG)  # the rag in the mouth
	_knot(s, 0.07, CLOTH)


static func _blindfold(s: CutsceneKit.Soup) -> void:
	s.cyl(Vector3(0.0, 0.113, 0.0), 0.05, Vector2(0.108, 0.118), Vector2(0.104, 0.114), 12, BLIND, 0)
	_knot(s, 0.138, BLIND)


## The knot and two tails at the back of the head (+Z), centred at height `y`.
static func _knot(s: CutsceneKit.Soup, y: float, col: Color) -> void:
	s.box(Vector3(0.0, y, 0.112), Vector3(0.026, 0.02, 0.016), col)
	s.box(Vector3(0.02, y - 0.04, 0.118), Vector3(0.01, 0.034, 0.006), col)
	s.box(Vector3(-0.022, y - 0.036, 0.118), Vector3(0.01, 0.03, 0.006), col)


## A sack over the head, resting on the shoulders, tied at the neck; `extra` lifts the top to cover a hat.
static func _hood(s: CutsceneKit.Soup, extra: float) -> void:
	s.ball(Vector3(0.0, 0.135 + extra * 0.8, 0.0), Vector3(0.13, 0.15 + extra, 0.14), 10, 7, BURLAP)
	s.cyl(Vector3(0.0, -0.01, 0.0), 0.14, Vector2(0.13, 0.125), Vector2(0.118, 0.125), 10, BURLAP, 0)
	s.cyl(Vector3(0.0, 0.035, 0.0), 0.02, Vector2(0.121, 0.126), Vector2(0.121, 0.126), 10, ROPE, 0)
