class_name Mirror
extends Node3D
## The big wall mirror (C14, 06 P26). A planar reflection on a phone budget: a SubViewport camera sits where the viewer's
## eye would be behind the glass and looks through the glass rectangle (a frustum camera whose near plane IS the glass, so
## nothing behind the wall plane is drawn and no oblique-clip maths is needed). It draws only render layer 10 (room shell,
## table, avatars; balls and props are left out) plus the local head's layer, at 576x384, at most 20 Hz (10 on quality
## tier 2), and only while the glass is on screen and the viewer is within RANGE_M of it.
## Orientation: local +Z is the mirror's normal, facing the room; local Y is up.

const LAYER := Humanoid.MIRROR_LAYER
const SIZE := Vector2(3.6, 2.4)
const VIEW_PX := Vector2i(576, 384)       ## same 3:2 as the glass
const RANGE_M := 8.0
const RATE_HZ := 20.0
const SLOW_TIER := 2                      ## QualityManager tier from which the rate halves
const FAR_M := 40.0
const NEAR_MIN_M := 0.05
const FRAME_M := 0.14                     ## width of the wood frame
const FRAME_BACK := -0.07                 ## the frame reaches back to the wall, 7 cm behind the glass
const FRAME_FRONT := 0.03
const WOOD := Color(0.24, 0.11, 0.05)
const BRASS := Color(0.80, 0.60, 0.22)

@export var shell: Node3D                 ## the BarRoom: its meshes join the mirror layer
@export var table: Node3D                 ## the Table: its own meshes do (not the balls)

var renders := 0                          ## render requests so far (probes, perf notes)

var _acc := 0.0
var _fresh := false                       ## the viewport holds an image of the current view

@onready var _view: SubViewport = $View
@onready var _cam: Camera3D = $View/Cam
@onready var _glass: MeshInstance3D = $Glass
@onready var _frame: MeshInstance3D = $Frame
@onready var _notifier: VisibleOnScreenNotifier3D = $Notifier


func _ready() -> void:
	_view.size = VIEW_PX
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_view.msaa_3d = Viewport.MSAA_DISABLED
	_view.positional_shadow_atlas_size = 0  # the glass shows lit avatars, not their shadows: no atlas to fill
	_view.gui_disable_input = true
	_cam.projection = Camera3D.PROJECTION_FRUSTUM
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT  # a frustum camera's `size` is then the window's height at the near plane
	_cam.cull_mask = LAYER | Humanoid.HEAD_LAYER
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://src/shaders/mirror.gdshader")
	mat.set_shader_parameter(&"view", _view.get_texture())
	_glass.material_override = mat
	_glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_build_frame()
	tag(shell)
	tag(table)
	if table != null and table.has_signal(&"rebuilt"):
		table.connect(&"rebuilt", tag.bind(table))


## Puts every visual under `root` (but a ball's, or one in group `no_mirror`) on the mirror layer as well as layer 1. Lights,
## the lightmap and the reflection probes count: a camera whose mask misses their layer draws the room unlit.
func tag(root: Node) -> void:
	if root == null:
		return
	for vi: VisualInstance3D in root.find_children("*", "VisualInstance3D", true, false):
		if not vi.get_parent() is RigidBody3D and not vi.is_in_group(&"no_mirror"):
			vi.layers |= LAYER


func _process(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and _notifier.is_on_screen():
		tick(delta, cam.global_position)


## One frame of the schedule for a viewer at `eye`: draws when the viewer is in range of the glass and the last image is
## older than the period (20 Hz, 10 Hz on quality tier 2). Returns whether it drew.
func tick(delta: float, eye: Vector3) -> bool:
	if not in_range(eye):
		return false
	_acc += delta
	var period := 1.0 / (RATE_HZ * (0.5 if QualityManager.current_tier >= SLOW_TIER else 1.0))
	if _fresh and _acc < period:
		return false
	_acc = 0.0
	render_for(eye)
	return true


## In front of the glass and within RANGE_M of it on the floor plan.
func in_range(eye: Vector3) -> bool:
	return (eye - global_position).dot(global_basis.z) >= NEAR_MIN_M and Vector2(eye.x - global_position.x, eye.z - global_position.z).length() <= RANGE_M


## Aim the camera for a viewer at `eye` and draw once.
func render_for(eye: Vector3) -> void:
	var n := global_basis.z.normalized()
	var up := global_basis.y.normalized()
	var right := n.cross(up)                          # the camera behind the glass looks along +n: its right is n x up
	var d := (eye - global_position).dot(n)
	_cam.global_transform = Transform3D(Basis(right, up, -n), eye - 2.0 * d * n)
	var rel := global_position - eye
	_cam.frustum_offset = Vector2(rel.dot(right), rel.dot(up))  # the glass rectangle's centre in that camera's view plane
	_cam.size = SIZE.y
	_cam.near = d
	_cam.far = d + FAR_M
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	_fresh = true
	renders += 1


# --- frame ---------------------------------------------------------------------------------------------

## Wood frame plus a brass lip around the glass: one mesh, one vertex-coloured material (1 draw call).
func _build_frame() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := SIZE.x * 0.5
	var h := SIZE.y * 0.5
	var f := FRAME_M
	var z0 := FRAME_BACK
	var z1 := FRAME_FRONT
	_box(st, Vector3(0.0, h + f * 0.5, (z0 + z1) * 0.5), Vector3(SIZE.x + 2.0 * f, f, z1 - z0), WOOD)
	_box(st, Vector3(0.0, -h - f * 0.5, (z0 + z1) * 0.5), Vector3(SIZE.x + 2.0 * f, f, z1 - z0), WOOD)
	_box(st, Vector3(-w - f * 0.5, 0.0, (z0 + z1) * 0.5), Vector3(f, SIZE.y, z1 - z0), WOOD)
	_box(st, Vector3(w + f * 0.5, 0.0, (z0 + z1) * 0.5), Vector3(f, SIZE.y, z1 - z0), WOOD)
	var lip := 0.025
	_box(st, Vector3(0.0, h - lip * 0.5, z1 * 0.5), Vector3(SIZE.x, lip, z1 + 0.012), BRASS)
	_box(st, Vector3(0.0, -h + lip * 0.5, z1 * 0.5), Vector3(SIZE.x, lip, z1 + 0.012), BRASS)
	_box(st, Vector3(-w + lip * 0.5, 0.0, z1 * 0.5), Vector3(lip, SIZE.y - 2.0 * lip, z1 + 0.012), BRASS)
	_box(st, Vector3(w - lip * 0.5, 0.0, z1 * 0.5), Vector3(lip, SIZE.y - 2.0 * lip, z1 + 0.012), BRASS)
	_frame.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.55
	m.metallic_specular = 0.4
	m.emission_enabled = true  # a dynamic prop in a baked room: keep it from going black away from the lamps
	m.emission = Color(0.30, 0.17, 0.08)
	m.emission_energy_multiplier = 0.6
	_frame.material_override = m
	_frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _box(st: SurfaceTool, centre: Vector3, size: Vector3, col: Color) -> void:
	var hs := size * 0.5
	for axis in 3:
		for sgn in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = 1.0
			var v := n.cross(u)
			var c := centre + n * hs[axis]
			var a := c - u * hs[(axis + 1) % 3] - v * hs[(axis + 2) % 3]
			var b := c + u * hs[(axis + 1) % 3] - v * hs[(axis + 2) % 3]
			var d := c + u * hs[(axis + 1) % 3] + v * hs[(axis + 2) % 3]
			var e := c - u * hs[(axis + 1) % 3] + v * hs[(axis + 2) % 3]
			for tri in [[a, b, d], [a, d, e]]:
				var cross: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
				var order := [0, 1, 2] if cross.dot(n) < 0.0 else [0, 2, 1]  # Godot's front face is clockwise seen from outside
				for k: int in order:
					st.set_color(col)
					st.set_normal(n)
					st.add_vertex(tri[k])
