class_name Mirror
extends Node3D
## The big wall mirror (C14, 06 P26, adhoc-1012a). Two layers, so nothing re-renders the room per frame:
## the room (shell + table, ROOM_LAYER) is captured once into a 6-face cube from CAPTURE_AT and box-projected per pixel from the
## live eye in the glass shader (re-captured on a table rebuild or a bar skin change); the avatars (LAYER + the local head) are a
## per-frame window pass: a frustum camera mirrored through the glass whose near plane IS the glass, transparent background.
## The window pass runs every frame from the *interpolated* eye (a throttled or tick-time eye is what made the old mirror swim).
## Orientation: local +Z is the mirror's normal, facing the room; local Y is up.

const LAYER := Humanoid.MIRROR_LAYER      ## avatars (Humanoid puts every body on it)
const ROOM_LAYER := 1 << 10               ## render layer 11: what the cube capture draws (room shell, table)
const SIZE := Vector2(3.6, 2.4)
const VIEW_PX := Vector2i(576, 384)       ## same 3:2 as the glass
const FACE_PX := 512                      ## cube face size; halved from SLOW_TIER
const CAPTURE_AT := Vector3(0.0, 0.2, 2.5) ## local: in front of the glass at about eye height
const RANGE_M := 8.0
const SLOW_TIER := 2                      ## QualityManager tier from which the window pass and the faces halve
const FAR_M := 40.0
const NEAR_MIN_M := 0.05
const FRAME_M := 0.14                     ## width of the wood frame
const FRAME_BACK := -0.07                 ## the frame reaches back to the wall, 7 cm behind the glass
const FRAME_FRONT := 0.03
const WOOD := Color(0.24, 0.11, 0.05)
const BRASS := Color(0.80, 0.60, 0.22)
## Cube faces as [forward, up], world axes; mirror.gdshader's F/U arrays must match.
const FACES: Array[Array] = [
	[Vector3.RIGHT, Vector3.UP], [Vector3.LEFT, Vector3.UP], [Vector3.UP, Vector3.BACK],
	[Vector3.DOWN, Vector3.FORWARD], [Vector3.BACK, Vector3.UP], [Vector3.FORWARD, Vector3.UP],
]

@export var shell: Node3D                 ## the BarRoom: its meshes join the room capture
@export var table: Node3D                 ## the Table: its own meshes do (not the balls)
@export var skins: Node                   ## BarSkinDirector: a new bar skin re-captures the room

var renders := 0                          ## window-pass frames so far (probes, perf notes)
var captures := 0                         ## room captures so far

var _mat: ShaderMaterial
var _capturing := false
var _recapture := false

@onready var _view: SubViewport = $View
@onready var _cam: Camera3D = $View/Cam
@onready var _glass: MeshInstance3D = $Glass
@onready var _frame: MeshInstance3D = $Frame
@onready var _notifier: VisibleOnScreenNotifier3D = $Notifier


func _ready() -> void:
	_view.size = VIEW_PX
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_view.transparent_bg = true
	_view.use_hdr_2d = false              # 8-bit sRGB like the faces: the shader reads both as source_color
	_view.msaa_3d = Viewport.MSAA_DISABLED
	_view.positional_shadow_atlas_size = 0  # the glass shows lit avatars, not their shadows: no atlas to fill
	_view.gui_disable_input = true
	_cam.projection = Camera3D.PROJECTION_FRUSTUM
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT  # a frustum camera's `size` is then the window's height at the near plane
	_cam.cull_mask = LAYER | Humanoid.HEAD_LAYER
	_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # placed per frame from the interpolated eye
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://src/shaders/mirror.gdshader")
	_mat.set_shader_parameter(&"avatars", _view.get_texture())
	_mat.set_shader_parameter(&"box_min", Vector3(-DecorPlan.HALF, 0.0, -DecorPlan.HALF))
	_mat.set_shader_parameter(&"box_max", Vector3(DecorPlan.HALF, DecorPlan.CEIL, DecorPlan.HALF))
	_glass.material_override = _mat
	_glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_build_frame()
	tag(shell)
	tag(table)
	if table != null and table.has_signal(&"rebuilt"):
		table.connect(&"rebuilt", func() -> void:
			tag(table)
			capture())
	if skins != null and skins.has_signal(&"skin_applied"):
		skins.connect(&"skin_applied", func(_s: Variant, _o: int) -> void: capture())
	capture.call_deferred()


## Puts every mesh under `root` (but a ball's, or one in group `no_mirror`) on ROOM_LAYER as well as layer 1; lights, the
## lightmap and probes go on both mirror layers (a camera whose mask misses them draws unlit: room capture and avatars alike).
func tag(root: Node) -> void:
	if root == null:
		return
	for vi: VisualInstance3D in root.find_children("*", "VisualInstance3D", true, false):
		if vi.get_parent() is RigidBody3D or vi.is_in_group(&"no_mirror"):
			continue
		vi.layers |= ROOM_LAYER if vi is GeometryInstance3D else ROOM_LAYER | LAYER


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	tick(cam.get_global_transform_interpolated().origin if cam != null and _notifier.is_on_screen() else Vector3.INF)


## One frame for a viewer at `eye` (Vector3.INF = glass off screen): the window pass draws this frame only while the
## viewer is in front of the glass and in range. Returns whether it drew.
func tick(eye: Vector3) -> bool:
	if not eye.is_finite() or not in_range(eye):
		_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return false
	var px := VIEW_PX / 2 if QualityManager.current_tier >= SLOW_TIER else VIEW_PX
	if _view.size != px:
		_view.size = px
	render_for(eye)
	return true


## In front of the glass and within RANGE_M of it on the floor plan.
func in_range(eye: Vector3) -> bool:
	return (eye - global_position).dot(global_basis.z) >= NEAR_MIN_M and Vector2(eye.x - global_position.x, eye.z - global_position.z).length() <= RANGE_M


## Aim the window camera for a viewer at `eye` and draw this frame.
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
	renders += 1


## Renders the room's six cube faces from CAPTURE_AT into the glass's texture array. Needs a renderer (headless: no-op).
## A request while one runs is queued, not dropped (a skin can land mid-capture).
func capture() -> void:
	if _capturing:
		_recapture = true
		return
	if DisplayServer.get_name() == "headless":
		return
	_capturing = true
	var px := FACE_PX / 2 if QualityManager.current_tier >= SLOW_TIER else FACE_PX
	var vp := SubViewport.new()
	vp.size = Vector2i(px, px)
	vp.use_hdr_2d = false
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.positional_shadow_atlas_size = 0
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var cam := Camera3D.new()
	cam.fov = 90.0
	cam.near = 0.05
	cam.far = FAR_M
	cam.cull_mask = ROOM_LAYER
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	vp.add_child(cam)
	add_child(vp)
	var at := to_global(CAPTURE_AT)
	var images: Array[Image] = []
	for face: Array in FACES:
		var f: Vector3 = face[0]
		var u: Vector3 = face[1]
		cam.global_transform = Transform3D(Basis(u.cross(-f), u, -f), at)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		images.append(img)
	vp.queue_free()
	var faces := Texture2DArray.new()
	faces.create_from_images(images)
	_mat.set_shader_parameter(&"room", faces)
	_mat.set_shader_parameter(&"cap_pos", at)
	_mat.set_shader_parameter(&"has_room", true)
	captures += 1
	_capturing = false
	if _recapture:
		_recapture = false
		capture()


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
