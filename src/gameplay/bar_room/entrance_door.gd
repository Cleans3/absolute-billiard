class_name EntranceDoor
extends Node3D
## MainLevel/EntranceDoor (docs/plan/09 §3.8.1, adhoc-1013c F3b): the bar's door, made to move. The room's baked door slab (north wall, x -0.9..0.9)
## cannot, so this node hangs a dynamic leaf 6 cm proud of it in the same panelling (the room's wainscot material, world-metre UVs), and when
## the leaf swings open a black doorway quad hides the baked slab behind it. The leaf is always there, shut and BOLTED: the intro throws the crew
## in, slams it and shoots the bolt, and it stays that way for the whole session (Resume included). Local presentation, no collider, no light;
## 4 small meshes + the leaf + the doorway quad, 3 materials.
## API (the intro codes against it): `set_openness(0..1)` (0 shut, 1 flung back against the west wall), `set_bolt(0..1)` (0 drawn, 1 shot).

const HALF_W := 0.93                    ## the leaf's half width: it fills the frame's opening
const HEIGHT := 2.3
const THICK := 0.03
const QUAD_Z := -DecorPlan.HALF + 0.15  ## the doorway quad: just in front of the baked slab's handle (a brass stub that sticks out 4.5 cm)
const HINGE := Vector3(-HALF_W, 0.0, QUAD_Z + THICK * 0.5)  ## the west jamb; the leaf swings INTO the room (+Z)
const OPEN_DEG := 125.0
const BOLT_Y := 1.35
const BOLT_DRAWN := 1.48                ## hinge-local x of the bar's centre, drawn / shot (it is 0.4 long: shot, its end sits in the keeper)
const BOLT_SHOT := 1.78
const TILE := 2.1                       ## the wainscot's metres per repeat (build_bar_room.gd TILE.wainscot)
const WAINSCOT := "res://src/gameplay/bar_room/materials/wainscot.tres"
const BRASS := Color(0.80, 0.60, 0.22)

var openness := 0.0
var bolt := 1.0

var _hinge: Node3D
var _bar: MeshInstance3D
var _void: MeshInstance3D


func _ready() -> void:
	_hinge = Node3D.new()
	_hinge.name = "Hinge"
	_hinge.position = HINGE
	add_child(_hinge)
	var leaf := MeshInstance3D.new()
	leaf.name = "Leaf"
	leaf.mesh = _box_mesh(HINGE + Vector3(HALF_W, HEIGHT * 0.5, 0.0), Vector3(HALF_W * 2.0, HEIGHT, THICK))
	leaf.material_override = load(WAINSCOT) as Material
	leaf.position = Vector3(HALF_W, HEIGHT * 0.5, 0.0)
	_dynamic(leaf, Mirror.ROOM_LAYER)  # the mirror's room cube keeps a shut door in the wall
	_hinge.add_child(leaf)
	var brass := StandardMaterial3D.new()
	brass.albedo_color = BRASS
	brass.metallic = 0.8
	brass.roughness = 0.35
	brass.emission_enabled = true
	brass.emission = BRASS
	brass.emission_energy_multiplier = 0.12  # reads in the room's dark
	var plate := BoxMesh.new()
	plate.size = Vector3(0.3, 0.1, 0.02)
	_part(plate, Vector3(1.55, BOLT_Y, THICK * 0.5 + 0.01), brass, _hinge)
	var bar := BoxMesh.new()
	bar.size = Vector3(0.4, 0.04, 0.04)
	_bar = _part(bar, Vector3(BOLT_SHOT, BOLT_Y, THICK * 0.5 + 0.04), brass, _hinge)
	var keeper := BoxMesh.new()
	keeper.size = Vector3(0.14, 0.12, 0.12)
	_part(keeper, Vector3(HALF_W + 0.07, BOLT_Y, QUAD_Z + 0.03), brass)  # the iron staple on the east jamb the bar slides into
	var quad := QuadMesh.new()
	quad.size = Vector2(HALF_W * 2.0, HEIGHT)
	var dark := StandardMaterial3D.new()
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dark.albedo_color = Color(0.012, 0.016, 0.03)  # the night outside
	_void = _part(quad, Vector3(0.0, HEIGHT * 0.5, QUAD_Z), dark)
	_apply()


## 0 = shut, 1 = flung open against the west wall; the black doorway shows while it is not shut.
func set_openness(o: float) -> void:
	openness = clampf(o, 0.0, 1.0)
	_apply()


## 0 = drawn back, 1 = shot into the keeper.
func set_bolt(b: float) -> void:
	bolt = clampf(b, 0.0, 1.0)
	_apply()


func is_locked() -> bool:
	return openness <= 0.0 and bolt >= 1.0


func _apply() -> void:
	if _hinge == null:
		return
	_hinge.rotation.y = -deg_to_rad(OPEN_DEG) * openness  # a negative turn about Y swings the free edge toward +Z, into the room
	_bar.position.x = lerpf(BOLT_DRAWN, BOLT_SHOT, bolt)
	_void.visible = openness > 0.005


func _part(mesh: Mesh, at: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	_dynamic(mi, 0)
	(parent if parent != null else self).add_child(mi)
	return mi


static func _dynamic(mi: MeshInstance3D, extra_layers: int) -> void:
	mi.layers = 1 | extra_layers
	mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC  # no UV2: lit by the bake's probes, like the Trapdoor's panels
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A box with the room's world-metre UVs (position / TILE on the dominant axis) so the leaf continues the panelling around it.
## `world_centre` is where the box stands when shut.
static func _box_mesh(world_centre: Vector3, size: Vector3) -> ArrayMesh:
	var bm := BoxMesh.new()
	bm.size = size
	var a := bm.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in a[Mesh.ARRAY_INDEX]:
		var p := v[i] + world_centre
		var an := n[i].abs()
		var uv: Vector2
		if an.y >= an.x and an.y >= an.z:
			uv = Vector2(p.x, p.z) / TILE
		elif an.x >= an.z:
			uv = Vector2(p.z, -p.y) / TILE
		else:
			uv = Vector2(p.x, -p.y) / TILE
		st.set_color(Color.WHITE)
		st.set_normal(n[i])
		st.set_uv(uv)
		st.add_vertex(v[i])
	st.generate_tangents()
	return st.commit()
