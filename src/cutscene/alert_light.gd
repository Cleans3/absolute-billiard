class_name AlertLight
extends Node3D
## The beacon in the middle of the ceiling (docs/plan/09 §3.8, adhoc-1013c A10): a lamp whose head turns, with ONE realtime SpotLight3D
## sweeping the room, and an emissive dome. The failure runs it red and fast, the win runs it green and slow. Local presentation, built by
## the in-room cutscene and freed with it. Cost (07 §2): the room has two realtime lights (the table lamp's spot, one bar fill), this is the
## third; no shadow; 4 small meshes (base, stem, dome, hood), 2 materials. `pose(time, ...)` is a pure function of `time`.
## Origin = the point on the ceiling beam's underside (CEIL - 0.3) it hangs from, +Y up.

const MOUNT := Vector3(0.0, 3.3, 0.0)  ## world: the middle of the room, under the x = 0 ceiling beam
const HEAD_DROP := 0.28
const SPOT_RANGE := 14.0
const SPOT_ANGLE_DEG := 38.0
const SPOT_PITCH_DEG := -16.0  ## the beam leaves a little below the horizontal, so it sweeps the walls and the floor
const SPOT_ENERGY := 7.0
const METAL := Color(0.1, 0.1, 0.11)

var power := 0.0  ## 0 off .. 1 full, as last posed
var spin := 0.0   ## radians the head has turned

var _head: Node3D
var _spot: SpotLight3D
var _dome: MeshInstance3D
var _dome_mat: StandardMaterial3D


func _ready() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = METAL
	metal.metallic = 0.5
	metal.roughness = 0.5
	_part(_cyl(0.16, 0.06), Vector3(0.0, -0.03, 0.0), metal)  # base plate on the beam
	_part(_cyl(0.05, 0.12), Vector3(0.0, -0.12, 0.0), metal)  # stem
	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0.0, -HEAD_DROP, 0.0)
	add_child(_head)
	var ball := SphereMesh.new()
	ball.radius = 0.14
	ball.height = 0.28
	ball.radial_segments = 12
	ball.rings = 6
	_dome_mat = StandardMaterial3D.new()
	_dome_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dome = _part(ball, Vector3.ZERO, _dome_mat, _head)
	var hood := BoxMesh.new()
	hood.size = Vector3(0.3, 0.2, 0.04)
	_part(hood, Vector3(0.0, 0.0, 0.17), metal, _head)  # rides behind the bulb: it is what shows the head turning
	_spot = SpotLight3D.new()
	_spot.name = "Sweep"
	_spot.rotation_degrees = Vector3(SPOT_PITCH_DEG, 0.0, 0.0)
	_spot.spot_range = SPOT_RANGE
	_spot.spot_angle = SPOT_ANGLE_DEG
	_spot.spot_attenuation = 0.8
	_spot.shadow_enabled = false
	_spot.layers = 1 | Mirror.ROOM_LAYER | Mirror.LAYER  # the mirror's cameras use it too (Mirror.tag does this for the room's own lights)
	_head.add_child(_spot)
	pose(0.0, Color.RED, 0.0)


## Sets everything for `time`: the head's turn, the spot's colour and energy (a heartbeat flicker), the dome's glow. `p_power` 0 = dark.
func pose(time: float, color: Color, p_power: float, spin_hz := 1.1) -> void:
	power = clampf(p_power, 0.0, 1.0)
	spin = TAU * spin_hz * time
	_head.rotation.y = spin
	var pulse := 0.5 + 0.5 * sin(TAU * spin_hz * 2.0 * time)  # twice a turn, as the beam crosses the walls
	_spot.light_color = color
	_spot.light_energy = SPOT_ENERGY * power * (0.65 + 0.35 * pulse)
	_spot.visible = power > 0.001
	_dome_mat.albedo_color = Color(color.r, color.g, color.b) * (0.15 + 1.1 * power * (0.6 + 0.4 * pulse))


func _part(mesh: Mesh, at: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	mi.layers = 1 | Mirror.ROOM_LAYER
	(parent if parent != null else self).add_child(mi)
	return mi


static func _cyl(radius: float, height: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = height
	c.radial_segments = 12
	c.rings = 1
	return c
