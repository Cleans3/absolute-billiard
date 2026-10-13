class_name StreamTv
extends Node3D
## MainLevel/Tv: the wall TV on the south wall (docs/plan/02 §3.2, 07 §2, 06 P33 U5, adhoc-1013c W4). Dynamic, not baked. The glass is
## split in two, each half 3:2 (no crop): the left shows the first tripod rig live (it follows the rig if a player carries it), the
## right the ceiling camera's top-down picture. Two SubViewports render the main world through two cameras; nothing else is drawn
## for them: no shadow atlas (the lamp's shadows are not in the feeds), no MSAA, FXAA instead.
## Cost control (07 §2 "TV feeds"): the feeds draw alternately, one pass per period, only while the TV is on the viewer's screen
## (VisibleOnScreenNotifier3D) and `feeds_on`; sizes and rate by QualityManager tier:
##   tier 0  two 640x427 feeds, 15 Hz each (a pass every 1/30 s)     tier 1  two 400x267, 8 Hz each (every 1/16 s)
##   tier 2  one wide 512x171 feed, the ceiling camera's, across the whole glass, 5 Hz (the lowest tier: one slow feed)
## A feed shows only after it has drawn once (shader `lit`), so the TV is black whenever it is off, resized or new. No noise.
## Render layers: the frame is on layer 1 + the mirror's ROOM_LAYER (the room cube keeps a TV on the wall); the glass and the LIVE bugs are on
## SCREEN_LAYER (+ ROOM_LAYER for the glass) which no feed camera draws, so a tripod turned at the TV does not film itself. Feeds draw layer 1,
## the mirror layer and HEAD_LAYER (the shooter's body is on it in CUE and shows on the TV); never ShotGuide's layer 12; the ceiling feed
## also leaves out CeilingCam.LAMP_LAYER (the lamp). Local space: +Z faces the room, origin on the wall plane at the TV's centre.

const SCREEN := Vector2(3.72, 1.24)       ## the glass, metres
const FRAME := Vector2(4.0, 1.48)         ## outer size: the south wall's TV zone is x -2.05..2.05 (DecorPlan.wall_keep_clear)
const DEPTH := 0.2                        ## rim depth: from the wall plane into the room
const SCREEN_Z := DEPTH - 0.03            ## the glass sits recessed in the rim
const LABEL_LIFT := 0.025                 ## the LIVE bugs stand this far in front of the glass: a few mm z-fights on a coarse depth buffer (07 §7.7)
const DIVIDER := 0.04                     ## the bar between the two pictures (it hides the seam)
const SCREEN_LAYER := 1 << 13             ## render layer 14: the glass and its labels; no feed camera draws it
const FEED_MASK := 1 | Humanoid.MIRROR_LAYER | Humanoid.HEAD_LAYER
const HALF_ASPECT := SCREEN.x * 0.5 / SCREEN.y  ## each half's picture: 3:2 with these numbers
const WIDE_ASPECT := SCREEN.x / SCREEN.y
const HALF_W: Array[int] = [640, 400]     ## picture width (px) of one half on tiers 0 / 1
const WIDE_W := 512                       ## tier 2: width of the single wide feed
const PERIOD: Array[float] = [1.0 / 30.0, 1.0 / 16.0, 1.0 / 5.0]  ## seconds between two feed passes, per tier
const NEAR_M := 0.05
const FAR_M := 40.0
const FRAME_COLOR := Color(0.07, 0.07, 0.08)
const LIVE_COLOR := Color(1.0, 0.25, 0.2)
const FONT := preload("res://assets/fonts/BarlowCondensed-SemiBold.ttf")

@export var cameras: CameraRigs

var feeds_on := true                      ## `set_feeds_on`: false = a black glass, nothing rendered
var renders: Array[int] = [0, 0]          ## feed passes so far: [tripod, ceiling] (probes, perf notes)

var _vp: Array[SubViewport] = []
var _cam: Array[Camera3D] = []
var _labels: Array[Label3D] = []
var _mat: ShaderMaterial
var _notifier: VisibleOnScreenNotifier3D
var _tier := -1
var _lit := Vector2.ZERO                  ## 1 per feed once it has drawn since the last resize / switch-on
var _pending: Array[bool] = [false, false]  ## a pass was requested last frame: the picture exists next frame
var _accum := 0.0
var _next := 0                            ## the feed that draws next (tier 0 / 1 alternate)


func _ready() -> void:
	_build_frame()
	_build_screen()
	_build_feeds()
	_build_labels()
	_notifier = VisibleOnScreenNotifier3D.new()
	_notifier.aabb = AABB(Vector3(-FRAME.x * 0.5, -FRAME.y * 0.5, 0.0), Vector3(FRAME.x, FRAME.y, DEPTH + 0.1))
	add_child(_notifier)
	apply_tier(QualityManager.current_tier)


func _process(delta: float) -> void:
	tick(delta, _notifier.is_on_screen())


## The Seam F3b codes against: false = a black glass and no pass drawn; true = live again (the first picture lands within a period or two).
func set_feeds_on(on: bool) -> void:
	feeds_on = on
	if not is_node_ready():
		return  # asked before the TV was built: `_ready` reads `feeds_on`
	if not on:
		_lit = Vector2.ZERO
		_pending.fill(false)
		_idle()
		_push_lit()
	_sync_labels()


## One frame. `on_screen`: the TV is in the viewer's view. Returns the feed drawn (0 tripod, 1 ceiling), -1 for none.
## Draws nothing while off, off screen, or between two periods.
func tick(delta: float, on_screen: bool) -> int:
	_settle()
	if not feeds_on or not on_screen or cameras == null:
		_idle()
		return -1
	var tier := clampi(QualityManager.current_tier, 0, PERIOD.size() - 1)
	if tier != _tier:
		apply_tier(tier)
	_accum += delta
	if _accum < PERIOD[tier]:
		return -1
	_accum = minf(_accum - PERIOD[tier], PERIOD[tier])  # a long frame is not paid back with a burst
	var i := 1 if tier >= 2 else _next
	_next = 1 - _next
	return i if _render(i) else -1


## Sizes, rate and layout for a quality tier. Resizing clears the pictures, so the glass goes black until each feed has drawn again.
func apply_tier(tier: int) -> void:
	_tier = clampi(tier, 0, PERIOD.size() - 1)
	var wide := _tier >= 2
	var size := feed_size(_tier)
	_vp[1].size = size
	_vp[0].size = Vector2i(2, 2) if wide else size  # tier 2 draws no tripod feed: keep it one texel
	_mat.set_shader_parameter(&"wide", wide)
	_labels[0].text = "LIVE  CEILING" if wide else "LIVE  CAM 1"
	_lit = Vector2.ZERO
	_pending.fill(false)
	_accum = 0.0
	_push_lit()
	_sync_labels()


## A feed's picture size (px) on `tier`: half of the glass (3:2) on 0 / 1, the whole glass (3:1) on 2.
static func feed_size(tier: int) -> Vector2i:
	if tier >= 2:
		return Vector2i(WIDE_W, roundi(WIDE_W / WIDE_ASPECT))
	var w := HALF_W[clampi(tier, 0, HALF_W.size() - 1)]
	return Vector2i(w, roundi(w / HALF_ASPECT))


## The render layers a feed camera draws: `i` 0 = the tripod (sees the lamp), 1 = the ceiling camera (does not).
static func feed_mask(i: int) -> int:
	return FEED_MASK | (CeilingCam.LAMP_LAYER if i == 0 else 0)


func _render(i: int) -> bool:
	if cameras == null:
		return false
	var cam := _cam[i]
	if i == 0:
		if cameras.rigs.is_empty():
			return false
		cam.global_transform = cameras.rigs[0].feed_transform()
		cam.fov = CameraRig.FEED_FOV
	else:
		var ceiling := cameras.ceiling
		if ceiling == null:
			return false
		cam.global_transform = Transform3D(ceiling.look_basis(), ceiling.eye())
		cam.fov = ceiling.fit_fov(float(_vp[1].size.x) / float(_vp[1].size.y))
	_vp[i].render_target_update_mode = SubViewport.UPDATE_ONCE
	renders[i] += 1
	_pending[i] = true
	return true


func _idle() -> void:
	for vp in _vp:
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_accum = 0.0


## A pass requested last frame has been drawn by now: that feed's picture is real.
func _settle() -> void:
	for i in 2:
		if _pending[i]:
			_pending[i] = false
			if feeds_on and _lit[i] == 0.0:
				_lit[i] = 1.0
				_push_lit()


func _push_lit() -> void:
	_mat.set_shader_parameter(&"lit", _lit)


func _sync_labels() -> void:
	_labels[0].visible = feeds_on
	_labels[1].visible = feeds_on and _tier < 2


# --- parts ----------------------------------------------------------------------------------------------------------

## Back plate, rim (top, bottom, left, right) and the divider: one mesh, one vertex-coloured material (1 draw call).
func _build_frame() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bx := (FRAME.x - SCREEN.x) * 0.5
	var by := (FRAME.y - SCREEN.y) * 0.5
	Mirror._box(st, Vector3(0.0, 0.0, 0.02), Vector3(FRAME.x, FRAME.y, 0.04), FRAME_COLOR)
	for s in [-1.0, 1.0]:
		Mirror._box(st, Vector3(0.0, s * (SCREEN.y + by) * 0.5, DEPTH * 0.5), Vector3(FRAME.x, by, DEPTH), FRAME_COLOR)
		Mirror._box(st, Vector3(s * (SCREEN.x + bx) * 0.5, 0.0, DEPTH * 0.5), Vector3(bx, SCREEN.y, DEPTH), FRAME_COLOR)
	Mirror._box(st, Vector3(0.0, 0.0, (0.04 + DEPTH - 0.02) * 0.5), Vector3(DIVIDER, SCREEN.y, DEPTH - 0.06), FRAME_COLOR)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.5
	m.metallic_specular = 0.4
	m.emission_enabled = true  # a dynamic prop in a baked room: keep it from going black away from the lamps
	m.emission = Color(0.10, 0.10, 0.11)
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	frame.mesh = st.commit()
	frame.material_override = m
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # 07: props never enter the one shadow map
	frame.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	frame.layers = 1 | Mirror.ROOM_LAYER
	add_child(frame)


func _build_screen() -> void:
	var quad := QuadMesh.new()
	quad.size = SCREEN
	var screen := MeshInstance3D.new()
	screen.name = "Screen"
	screen.mesh = quad
	screen.position = Vector3(0.0, 0.0, SCREEN_Z)
	screen.layers = SCREEN_LAYER | Mirror.ROOM_LAYER
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	screen.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://src/shaders/tv.gdshader")
	screen.material_override = _mat
	add_child(screen)


func _build_feeds() -> void:
	for i in 2:
		var vp := SubViewport.new()
		vp.name = "FeedA" if i == 0 else "FeedB"
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.use_hdr_2d = false                    # 8-bit sRGB like the mirror's pass: the shader reads it as source_color
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA  # a minified 640 px picture shimmers without it
		vp.positional_shadow_atlas_size = 0      # no shadow pass for a picture this small
		vp.gui_disable_input = true
		add_child(vp)
		var cam := Camera3D.new()
		cam.name = "Cam"
		cam.keep_aspect = Camera3D.KEEP_HEIGHT   # `fov` is the vertical angle
		cam.near = NEAR_M
		cam.far = FAR_M
		cam.cull_mask = feed_mask(i)
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # placed per pass from the rig's / pod's own transform
		vp.add_child(cam)
		_vp.append(vp)
		_cam.append(cam)
	_mat.set_shader_parameter(&"feed_a", _vp[0].get_texture())
	_mat.set_shader_parameter(&"feed_b", _vp[1].get_texture())


## A thin red "LIVE" bug over the top-left corner of each picture.
func _build_labels() -> void:
	for i in 2:
		var l := Label3D.new()
		l.name = "Live" + ("A" if i == 0 else "B")
		l.font = FONT
		l.font_size = 90
		l.pixel_size = 0.0008
		l.modulate = LIVE_COLOR
		l.outline_size = 10
		l.outline_modulate = Color(0.04, 0.02, 0.02, 0.9)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l.double_sided = false
		l.layers = SCREEN_LAYER
		l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var left := -SCREEN.x * 0.5 if i == 0 else DIVIDER * 0.5
		l.position = Vector3(left + 0.08, SCREEN.y * 0.5 - 0.09, SCREEN_Z + LABEL_LIFT)
		l.text = "LIVE  CAM 1" if i == 0 else "LIVE  CEILING"
		add_child(l)
		_labels.append(l)
