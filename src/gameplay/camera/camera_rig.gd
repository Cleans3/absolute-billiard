class_name CameraRig
extends Node3D
## A grabbable tripod camera (docs/plan/02 §2). A prop: the view is scored by math, never rendered.
## Looks along -Z rotated by its yaw, tilted down PITCH; the friend who last placed it chose the angle.

const TIER_MULT: Array[float] = [1.0, 1.25, 1.5]  # tier 1 / 2 / 3 [tune]
const EYE_HEIGHT := 1.5
const PITCH := 0.35  # rad down
const FOOT_RADIUS := 0.55  # tripod splay on the floor
const HUB_Y := 1.1  # where the three legs meet
const HEAD_Y := 1.4  # top of the pan plate; the body sits on it
const LEG_RADIUS := 0.016
const UV_GLASS := Vector2(0.25, 0.5)  # the optic material is a 2x1 palette: [glass | tally light]
const UV_TALLY := Vector2(0.75, 0.5)

static var _mesh: ArrayMesh  # one model for every rig

@export var camera_id: StringName
@export var tier := 1

var held_by := 0  # peer id carrying it; 0 = standing on its tripod


func _ready() -> void:
	var model := MeshInstance3D.new()
	model.name = "Model"
	model.mesh = _model()
	model.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC  # no UV2 for the lightmap: lit by the bake's probes instead
	model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # 07: props never enter the one shadow map
	add_child(model)


func tier_mult() -> float:
	return TIER_MULT[clampi(tier, 1, TIER_MULT.size()) - 1]


func eye() -> Vector3:
	return global_position + Vector3.UP * EYE_HEIGHT


func forward() -> Vector3:
	var yaw := rotation.y
	return Vector3(-sin(yaw) * cos(PITCH), -sin(PITCH), -cos(yaw) * cos(PITCH))


func aim_at(point: Vector3) -> void:
	var d := point - global_position
	rotation.y = atan2(-d.x, -d.z)


## One ArrayMesh, three surfaces (= 3 draw calls per rig): dark metal tripod + lens barrel, matte body,
## and the optic palette (glass front + red tally). Head parts are pre-pitched to match `forward()`.
static func _model() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	# Dark painted aluminium, not bare metal: at metallic 0.85 / rough 0.4 a 3 cm strut is all grazing Fresnel, so the room probe's
	# bright pixels outline it in white while its body stays black (adhoc-1013c U4).
	var metal := _surface(_material(Color(0.2, 0.21, 0.24), 0.65, 0.15))
	var matte := _surface(_material(Color(0.06, 0.06, 0.07), 0.92, 0.0))
	var optic := _surface(_optic_material())
	var hub := Vector3(0, HUB_Y, 0)
	for i in 3:
		var dir := Vector3.BACK.rotated(Vector3.UP, TAU * i / 3.0)
		_strut(metal, hub + dir * 0.04, dir * FOOT_RADIUS + Vector3(0, 0.01, 0), LEG_RADIUS)
	_cyl(metal, Vector3(0, HUB_Y, 0), 0.05, 0.08, Basis.IDENTITY)  # leg collar
	_cyl(metal, Vector3(0, (HUB_Y + HEAD_Y) * 0.5, 0), 0.022, HEAD_Y - HUB_Y, Basis.IDENTITY)  # centre column
	_cyl(metal, Vector3(0, HEAD_Y, 0), 0.07, 0.04, Basis.IDENTITY)  # pan plate
	var head := Transform3D(Basis(Vector3.RIGHT, -PITCH), Vector3(0, EYE_HEIGHT, 0))
	var along_z := Basis(Vector3.RIGHT, PI * 0.5)
	_box(matte, Vector3(0.22, 0.2, 0.34), head)  # body
	_box(matte, Vector3(0.14, 0.14, 0.1), head * Transform3D(Basis.IDENTITY, Vector3(0, 0.02, 0.22)))  # battery / viewfinder
	_cyl_xf(metal, 0.065, 0.16, head * Transform3D(along_z, Vector3(0, 0, -0.25)))  # lens barrel
	_cyl_xf(metal, 0.076, 0.04, head * Transform3D(along_z, Vector3(0, 0, -0.22)))  # focus ring
	_cyl_xf(optic, 0.058, 0.012, head * Transform3D(along_z, Vector3(0, 0, -0.336)), UV_GLASS)  # front glass
	_box(optic, Vector3(0.03, 0.03, 0.03), head * Transform3D(Basis.IDENTITY, Vector3(0, 0.115, -0.12)), UV_TALLY)
	_mesh = ArrayMesh.new()
	for st in [metal, matte, optic]:
		(st as SurfaceTool).commit(_mesh)
	return _mesh


static func _surface(mat: Material) -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	return st


static func _material(albedo: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	m.metallic = metal
	return m


## Glass and tally share one material so the rig stays at 3 draw calls: a 2x1 palette feeds albedo and emission.
static func _optic_material() -> StandardMaterial3D:
	var albedo := Image.create(2, 1, false, Image.FORMAT_RGB8)
	albedo.set_pixel(0, 0, Color(0.03, 0.05, 0.12))
	albedo.set_pixel(1, 0, Color(0.9, 0.04, 0.03))
	var glow := Image.create(2, 1, false, Image.FORMAT_RGB8)
	glow.set_pixel(1, 0, Color(1.0, 0.08, 0.05))
	var m := _material(Color.WHITE, 0.06, 0.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.albedo_texture = ImageTexture.create_from_image(albedo)
	m.emission_enabled = true
	m.emission_texture = ImageTexture.create_from_image(glow)
	m.emission_energy_multiplier = 4.0
	return m


## Appends a primitive; `uv` >= 0 pins every vertex to that palette cell.
static func _part(st: SurfaceTool, prim: PrimitiveMesh, xf: Transform3D, uv := Vector2(-1, -1)) -> void:
	if uv.x < 0.0:
		st.append_from(prim, 0, xf)
		return
	var arrays := prim.get_mesh_arrays()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	uvs.fill(uv)
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var tmp := ArrayMesh.new()
	tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	st.append_from(tmp, 0, xf)


static func _box(st: SurfaceTool, size: Vector3, xf: Transform3D, uv := Vector2(-1, -1)) -> void:
	var b := BoxMesh.new()
	b.size = size
	_part(st, b, xf, uv)


static func _cyl_xf(st: SurfaceTool, radius: float, height: float, xf: Transform3D, uv := Vector2(-1, -1)) -> void:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = 12
	c.rings = 1
	_part(st, c, xf, uv)


static func _cyl(st: SurfaceTool, center: Vector3, radius: float, height: float, basis: Basis) -> void:
	_cyl_xf(st, radius, height, Transform3D(basis, center))


## A thin cylinder from `a` to `b`.
static func _strut(st: SurfaceTool, a: Vector3, b: Vector3, radius: float) -> void:
	var d := b - a
	_cyl_xf(st, radius, d.length(), Transform3D(Basis(Quaternion(Vector3.UP, d.normalized())), (a + b) * 0.5))
