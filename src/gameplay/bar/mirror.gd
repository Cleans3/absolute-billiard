class_name Mirror
extends Node3D
## The big wall mirror (C14, 06 P26, adhoc-1012a). Two layers, so nothing re-renders the room per frame:
## the room shell (ROOM_LAYER) is captured once into a 6-face cube from CAPTURE_AT and box-projected per pixel from the live eye
## in the glass shader (re-captured on a bar skin change); the table and the avatars (LAYER + the local head) are a per-frame
## window pass (the table is too near the capture point for a box projection): a frustum camera mirrored through the glass whose near plane IS the glass, transparent background.
## The window pass runs every frame from the *interpolated* eye (a throttled or tick-time eye is what made the old mirror swim), at any
## distance in front of the glass (a range cut-off froze the avatars and the table over the live room, 06 P33 U2); what it costs is
## scaled instead: the pass is sized to the glass's size on the viewer's screen, and not drawn at all off screen or behind the glass.
## Tier 2 (the lowest, 07 §2) draws no window pass at all: the glass is the static room cube (the avatars and the table are not in it);
## tier 1 caps the pass at 512 px. Orientation: local +Z is the mirror's normal, facing the room; local Y is up.
## The room capture is six GPU readbacks, a hitch each: it runs at level load behind the LoadingScreen (which waits for `is_captured`) and never
## while a cutscene has the screen (`QualityManager.cutscene_holds`, adhoc-1014b S5): a request then waits for the hold to end, unless the
## LoadingScreen still covers it (the intro's cue fires under that overlay, and the overlay is waiting for this capture: no cycle).

const LAYER := Humanoid.MIRROR_LAYER      ## the window pass: avatars (Humanoid puts every body on it) and the table
const ROOM_LAYER := 1 << 10               ## render layer 11: what the cube capture draws (the room shell)
const SIZE := Vector2(3.6, 2.4)
const ASPECT := SIZE.x / SIZE.y           ## the window pass keeps the glass's 3:2
const VIEW_MAX_H: Array[int] = [1024, 512, 0]    ## tallest window pass per QualityManager tier (px), reached only when the glass fills the screen; 0 = no pass (static)
const VIEW_MIN_H := 128
const VIEW_STEP := 64                     ## the pass is resized in steps of this height, and shrinks only 2 steps late (no thrash at a boundary)
const FACE_PX: Array[int] = [1024, 512, 384]  ## cube face size per tier; mipmapped (the room is minified from a distance)
const CAPTURE_AT := Vector3(0.0, 0.2, 2.5) ## local: in front of the glass at about eye height
const FAR_M := 40.0
const CALM_FRAMES := 3                    ## frames without a hold before a held capture starts (a cut between two parts is off then on)
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
@export var table: Node3D                 ## the Table: its own meshes join the window pass (not the balls)
@export var skins: Node                   ## BarSkinDirector: a new bar skin re-captures the room

var renders := 0                          ## window-pass frames so far (probes, perf notes)
var captures := 0                         ## room captures so far
var faces_drawn := 0                      ## cube faces drawn and read back so far (src/tools/mirror_capture_timing.gd: none while a cutscene holds)
var blood := 0.0                          ## `set_blood`: 0 clean glass .. 1 smeared and dripping
var is_captured := false                  ## the room cube has been captured once (headless has none to capture: true at once)

signal captured                           ## a room capture finished

var _mat: ShaderMaterial
var _capturing := false
var _recapture := false
var _avatars_on := true                   ## the glass shows the window pass (false: tier 2, the static cube alone)
var _calm := 0                            ## frames a pending capture has seen without a cutscene hold
var _warm := 0                            ## frames `_process` leaves the window pass alone after `warm()` (the pass it asked for is drawn at the end of the first)

@onready var _view: SubViewport = $View
@onready var _cam: Camera3D = $View/Cam
@onready var _glass: MeshInstance3D = $Glass
@onready var _frame: MeshInstance3D = $Frame
@onready var _notifier: VisibleOnScreenNotifier3D = $Notifier


func _ready() -> void:
	add_to_group(&"mirror")
	add_to_group(Cutscene.WARM_GROUP)
	_view.size = view_size(VIEW_MIN_H)
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
	tag(shell, ROOM_LAYER)
	tag(table, LAYER)
	if table != null and table.has_signal(&"rebuilt"):
		table.connect(&"rebuilt", tag.bind(table, LAYER))
	if skins != null and skins.has_signal(&"skin_applied"):
		skins.connect(&"skin_applied", func(_s: Variant, _o: int) -> void: capture())
	capture.call_deferred()


## Puts every mesh under `root` (but a ball's, or one in group `no_mirror`) on `layer` as well as layer 1; lights, the lightmap
## and probes go on both mirror layers (a camera whose mask misses them draws unlit: room capture and window pass alike).
func tag(root: Node, layer: int) -> void:
	if root == null:
		return
	for vi: VisualInstance3D in root.find_children("*", "VisualInstance3D", true, false):
		if vi.get_parent() is RigidBody3D or vi.is_in_group(&"no_mirror"):
			continue
		vi.layers |= layer if vi is GeometryInstance3D else ROOM_LAYER | LAYER


func _process(_delta: float) -> void:
	if _recapture and not _capturing and not _held():
		_calm += 1
		if _calm >= CALM_FRAMES:
			_calm = 0
			_recapture = false
			capture()
	elif _held():
		_calm = 0
	if _warm > 0:
		_warm -= 1
		return
	var vp := get_viewport()
	var cam := vp.get_camera_3d()
	if cam == null or not _notifier.is_on_screen():
		tick(Vector3.INF)
		return
	tick(cam.get_global_transform_interpolated().origin, focal_px(cam, vp))


## Pixels one metre covers at one metre from the viewer's eye on the 3D render target (its height over twice the tangent of the
## vertical half angle, at the viewport's 3D scale): the glass `d` metres away is `SIZE.y * focal / d` pixels tall.
static func focal_px(cam: Camera3D, vp: Viewport) -> float:
	var half := deg_to_rad(cam.fov) * 0.5
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:  # `fov` is then horizontal
		half = atan(tan(half) / maxf(vp.get_visible_rect().size.aspect(), 0.1))
	return vp.get_visible_rect().size.y * vp.scaling_3d_scale / (2.0 * tan(half))


## One frame for a viewer at `eye` (Vector3.INF = glass off screen): the window pass draws this frame whenever the viewer is in front
## of the glass, however far, sized to the glass on their screen (`focal` from `focal_px`; 0 = the tier's tallest). Returns whether it drew.
func tick(eye: Vector3, focal := 0.0) -> bool:
	if not eye.is_finite() or not in_front(eye) or not has_window_pass():
		_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_show_avatars(has_window_pass())
		return false
	_show_avatars(true)
	var h := window_height(maxf((eye - global_position).dot(global_basis.z), NEAR_MIN_M), focal)
	var cur := _view.size.y
	if h > cur or h <= cur - 2 * VIEW_STEP:
		_view.size = view_size(h)
	render_for(eye)
	return true


## Draws the window pass once from where the room capture stands, whatever the viewer sees: the pass has its own framebuffer format, so its pipelines
## compile on its first draw, and the intro's black prepare (CutscenePlayer) makes that now, not in the first room beat that shows the glass.
## True when a pass was asked for (tier 2 draws none).
func warm() -> bool:
	if not has_window_pass():
		return false
	_show_avatars(true)
	render_for(to_global(CAPTURE_AT))
	_warm = 1
	return true


## Whether the current tier draws the avatars-and-table window pass (tier 2: no, the glass is the static room cube).
static func has_window_pass() -> bool:
	return VIEW_MAX_H[clampi(QualityManager.current_tier, 0, VIEW_MAX_H.size() - 1)] > 0


## The glass reads the window pass's texture only while it is being drawn: a tier that stops drawing it must not leave its last frame up.
func _show_avatars(on: bool) -> void:
	if on != _avatars_on and _mat != null:
		_avatars_on = on
		_mat.set_shader_parameter(&"avatars_on", on)


## In front of the glass plane (a viewer behind it, in the wall, sees no reflection).
func in_front(eye: Vector3) -> bool:
	return (eye - global_position).dot(global_basis.z) >= NEAR_MIN_M


## The window pass's height (px) for a viewer `dist` m from the glass plane: the glass's height on screen rounded up to VIEW_STEP,
## between VIEW_MIN_H and the tier's tallest. `focal` <= 0: the tallest.
func window_height(dist: float, focal: float) -> int:
	var tallest := maxi(VIEW_MAX_H[clampi(QualityManager.current_tier, 0, VIEW_MAX_H.size() - 1)], VIEW_MIN_H)
	if focal <= 0.0:
		return tallest
	return clampi(ceili(SIZE.y * focal / dist / VIEW_STEP) * VIEW_STEP, VIEW_MIN_H, tallest)


static func view_size(h: int) -> Vector2i:
	return Vector2i(roundi(h * ASPECT), h)


## 0 = clean glass, 1 = smeared and dripping (the failure cutscene animates it; local presentation, nothing on the wire).
func set_blood(amount: float) -> void:
	blood = clampf(amount, 0.0, 1.0)
	if _mat != null:
		_mat.set_shader_parameter(&"blood", blood)


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


## A cutscene has the screen and nothing hides it (the LoadingScreen, up from the session's start until the bar is playable, does).
func _held() -> bool:
	return QualityManager.cutscene_holds > 0 and not get_tree().root.has_node(^"LoadingScreen")


## Renders the room's six cube faces from CAPTURE_AT into the glass's texture array. Needs a renderer (headless: no-op).
## A request while one runs is queued, not dropped (a skin can land mid-capture).
func capture() -> void:
	if _capturing or _held():
		_recapture = true
		return
	if DisplayServer.get_name() == "headless":
		is_captured = true
		captured.emit()
		return
	_capturing = true
	var px := FACE_PX[clampi(QualityManager.current_tier, 0, FACE_PX.size() - 1)]
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
		while _held():  # a cutscene took the screen mid-capture: the rest of the faces wait for it to end
			await get_tree().process_frame
		var f: Vector3 = face[0]
		var u: Vector3 = face[1]
		cam.global_transform = Transform3D(Basis(u.cross(-f), u, -f), at)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		img.generate_mipmaps()
		images.append(img)
		faces_drawn += 1
	vp.queue_free()
	var faces := Texture2DArray.new()
	faces.create_from_images(images)
	_mat.set_shader_parameter(&"room", faces)
	_mat.set_shader_parameter(&"cap_pos", at)
	_mat.set_shader_parameter(&"has_room", true)
	captures += 1
	_capturing = false
	is_captured = true
	captured.emit()
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
