class_name Ufo
extends Node3D
## The set-up saucer (06 P33 U16): procedural, a handful of meshes, NO collision object anywhere in it or its beam, no light (emissive only).
## Saucer + dome + rim lights + underside glow + a tractor-beam cone and a landing pad on the cloth. `RoundStaging` places it; the beam is
## world-space (top_level) so it can point at any ball. `set_solid` materialises / dematerialises the craft (Materialise, instance transparency).

const RADIUS := 0.55
const THICKNESS := 0.26
const EMITTER_Y := -0.12     ## local y of the beam's mouth
const PAD_DROP := 0.06       ## a ball's centre above the cloth (about one radius): where the pad lies below the beam target

var beam_on := false
var _target := Vector3.ZERO
var _saucer: MeshInstance3D
var _dome: MeshInstance3D
var _rim: MeshInstance3D
var _glow: MeshInstance3D
var _beam: MeshInstance3D
var _pad: MeshInstance3D
var _beam_mat: ShaderMaterial
var _pad_mat: StandardMaterial3D


func _ready() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.5, 0.54, 0.62)
	metal.metallic = 0.85
	metal.roughness = 0.3
	var saucer_mesh := SphereMesh.new()
	saucer_mesh.radius = 0.5
	saucer_mesh.height = 1.0
	saucer_mesh.radial_segments = 32
	saucer_mesh.rings = 14
	_saucer = _part("Saucer", saucer_mesh, metal)
	_saucer.scale = Vector3(RADIUS * 2.0, THICKNESS, RADIUS * 2.0)

	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.45, 0.9, 1.0, 0.45)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.emission_enabled = true
	glass.emission = Color(0.2, 0.7, 0.9)
	glass.emission_energy_multiplier = 0.6
	glass.roughness = 0.1
	var dome_mesh := SphereMesh.new()
	dome_mesh.radius = 0.5
	dome_mesh.height = 0.5
	dome_mesh.is_hemisphere = true
	dome_mesh.radial_segments = 24
	dome_mesh.rings = 8
	_dome = _part("Dome", dome_mesh, glass)
	_dome.scale = Vector3(RADIUS * 0.9, RADIUS * 0.9, RADIUS * 0.9)
	_dome.position = Vector3(0.0, THICKNESS * 0.3, 0.0)

	var rim_mat := ShaderMaterial.new()
	rim_mat.shader = preload("res://src/shaders/ufo_rim.gdshader")
	var rim_mesh := TorusMesh.new()
	rim_mesh.inner_radius = RADIUS * 0.88
	rim_mesh.outer_radius = RADIUS * 1.04
	rim_mesh.rings = 32
	rim_mesh.ring_segments = 8
	_rim = _part("Rim", rim_mesh, rim_mat)

	var glow_mat := StandardMaterial3D.new()
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.albedo_color = Color(0.7, 1.0, 1.0)
	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 0.16
	glow_mesh.bottom_radius = 0.16
	glow_mesh.height = 0.03
	glow_mesh.radial_segments = 16
	glow_mesh.rings = 1
	_glow = _part("Glow", glow_mesh, glow_mat)
	_glow.position = Vector3(0.0, EMITTER_Y + 0.01, 0.0)

	_beam_mat = ShaderMaterial.new()
	_beam_mat.shader = preload("res://src/shaders/ufo_beam.gdshader")
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.2     # +Y end: at the ball
	beam_mesh.bottom_radius = 0.07  # -Y end: at the saucer
	beam_mesh.height = 1.0
	beam_mesh.radial_segments = 16
	beam_mesh.rings = 1
	beam_mesh.cap_top = false
	beam_mesh.cap_bottom = false
	_beam = _part("Beam", beam_mesh, _beam_mat)
	_beam.top_level = true
	_beam.visible = false

	_pad_mat = StandardMaterial3D.new()
	_pad_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pad_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pad_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_pad_mat.albedo_color = Color(0.4, 0.95, 1.0, 0.45)
	_pad_mat.no_depth_test = false
	var pad_mesh := CylinderMesh.new()
	pad_mesh.top_radius = 0.2
	pad_mesh.bottom_radius = 0.2
	pad_mesh.height = 0.004
	pad_mesh.radial_segments = 20
	pad_mesh.rings = 1
	_pad = _part("Pad", pad_mesh, _pad_mat)
	_pad.top_level = true
	_pad.visible = false
	set_solid(1.0)


## `p` 0 = gone .. 1 = solid. The craft's meshes fade (and glow while they do); the beam and the pad are not part of it.
func set_solid(p: float) -> void:
	for mi: MeshInstance3D in [_saucer, _dome, _rim, _glow]:
		Materialise.set_progress(mi, p)


## Aims the tractor beam from the saucer's underside at world `target` (a ball's centre), at `strength` 0..1; 0 switches it off.
func set_beam(target: Vector3, strength: float) -> void:
	beam_on = strength > 0.01
	_beam.visible = beam_on
	_pad.visible = beam_on
	if not beam_on:
		return
	_target = target
	var from := to_global(Vector3(0.0, EMITTER_Y, 0.0))
	var up := target - from
	var length := maxf(up.length(), 0.01)
	var y := up / length
	var x := y.cross(Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD).normalized()
	var z := x.cross(y)
	_beam.global_transform = Transform3D(Basis(x, y * length, z), (from + target) * 0.5)
	_beam_mat.set_shader_parameter(&"strength", strength)
	_pad.global_position = Vector3(target.x, target.y - PAD_DROP, target.z)
	_pad_mat.albedo_color.a = 0.45 * strength


## Where the beam last landed (world), for probes and the screenshot tool.
func beam_target() -> Vector3:
	return _target


func _part(part_name: String, mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # props never enter the one shadow map (07 §2)
	mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	add_child(mi)
	return mi
