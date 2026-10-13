class_name WinRoom
extends RoomCutscene
## Campaign win, part 1, IN the bar (docs/plan/09 §3.8.3, 06 P39 U17: "the light turn green, the bartender start celebrating, then the vent open
## up and spray out a green gas of somesort, making the player vision blurry then black"). From the local player's own eye: the AlertLight in the
## middle of the ceiling comes on GREEN and turns slowly, a green wash over the screen, Gus cheers (arms up, hopping, `Bartender.celebrate`), the
## Vent opens (`Vent.open`) and sprays a bounded green plume (one CPUParticles3D, GAS_PARTICLES quads), the view turns up to it, then swims, blurs
## (the screen's mip chain, CutScreen) and goes black. The next part, TruckOutro, fades up from that black. The crew is not moved.
## Cost (07 §2): the beacon's one realtime spot, one CPUParticles3D of GAS_PARTICLES soft quads (alpha, no depth write, ~3 s of overdraw), one screen pass.

const LENGTH_SEC := 6.5
const T_CHEER := 0.8
const T_LOOK_FROM := 1.2
const T_LOOK_TO := 2.8
const T_VENT := 2.4
const T_GAS := 2.8
const T_BLUR_FROM := 3.2
const T_BLUR_TO := 5.8
const T_DARK_FROM := 5.2
const T_DARK_TO := 6.4
const SPIN_HZ := 0.45
const GREEN := Color(0.15, 1.0, 0.3)
const GAS_PARTICLES := 60
const CHEER_LINE := "Paid in full! Drinks are on Moe!"

var _alert: AlertLight
var _cut: CutScreen
var _vent: Vent
var _gus: Bartender
var _gas: CPUParticles3D
var _hiss: AudioStreamPlayer
var _eye0 := Transform3D.IDENTITY
var _fov0 := 70.0


func id() -> StringName:
	return &"win_room"


func length_sec() -> float:
	return LENGTH_SEC


func configure(opts: Dictionary) -> void:
	super(opts)
	fade_out = 0.4


func _build() -> void:
	_collect_crew()  # it only watches: nobody is moved
	_eye0 = local_eye()
	_fov0 = local_fov()
	_cut = _node(^"UILayer/CutScreen") as CutScreen
	_vent = _node(^"Vent") as Vent
	_gus = _node(^"Bar/Bartender") as Bartender
	_alert = AlertLight.new()
	_alert.position = AlertLight.MOUNT
	add_child(_alert)
	_build_gas()


## A bounded plume out of the vent's mouth: GAS_PARTICLES billboard quads with a soft radial sprite, tinted by a colour ramp that fades them in and out.
func _build_gas() -> void:
	_gas = CPUParticles3D.new()
	_gas.name = "Gas"
	_gas.amount = GAS_PARTICLES
	_gas.lifetime = 3.2
	_gas.emitting = false
	_gas.local_coords = false
	_gas.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_gas.emission_box_extents = Vector3(0.8, 0.8, 0.05)  # the vent mouth's plane (x east-west, y north-south)
	_gas.direction = Vector3(0.0, 0.0, -1.0)  # out of the mouth = down
	_gas.spread = 32.0
	_gas.initial_velocity_min = 1.0
	_gas.initial_velocity_max = 2.4
	_gas.gravity = Vector3(0.0, -0.45, 0.0)
	_gas.damping_min = 0.3
	_gas.damping_max = 0.8
	_gas.scale_amount_min = 1.0
	_gas.scale_amount_max = 1.7
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.35))
	grow.add_point(Vector2(1.0, 1.0))
	_gas.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	ramp.colors = PackedColorArray([Color(0.3, 1.0, 0.4, 0.0), Color(0.35, 1.0, 0.45, 0.55), Color(0.3, 0.9, 0.4, 0.0)])
	_gas.color_ramp = ramp
	var puff := QuadMesh.new()
	puff.size = Vector2(1.0, 1.0)
	_gas.mesh = puff
	var soft := Gradient.new()
	soft.offsets = PackedFloat32Array([0.0, 1.0])
	soft.colors = PackedColorArray([Color(1.0, 1.0, 1.0, 1.0), Color(1.0, 1.0, 1.0, 0.0)])
	var sprite := GradientTexture2D.new()
	sprite.gradient = soft
	sprite.fill = GradientTexture2D.FILL_RADIAL
	sprite.fill_from = Vector2(0.5, 0.5)
	sprite.fill_to = Vector2(0.5, 0.0)
	sprite.width = 64
	sprite.height = 64
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = sprite
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_gas.material_override = mat
	_gas.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_gas)
	_gas.global_transform = _vent.mouth_transform() if _vent != null else Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(2.5, 3.1, -3.5))


func _update(time: float, _dt: float) -> void:
	var power := smoothstep(0.0, 0.6, time)
	_alert.pose(time, GREEN, power, SPIN_HZ)
	if time >= T_CHEER and _once(&"cheer") and _gus != null:
		_gus.celebrate(true, CHEER_LINE)
	if time >= T_VENT and _once(&"vent") and _vent != null:
		_vent.open()
	if time >= T_GAS and _once(&"gas"):
		_gas.emitting = true
		_hiss = CutsceneSfx.play(self, CutsceneSfx.Kind.HISS, -10.0)
	var blur := smoothstep(T_BLUR_FROM, T_BLUR_TO, time)
	if _cut != null:
		var pulse := 0.5 + 0.5 * sin(TAU * 0.9 * time)
		var amount := power * (0.1 + 0.12 * pulse) + 0.45 * smoothstep(T_VENT, 5.0, time)
		_cut.set_wash(GREEN, amount, blur, smoothstep(T_DARK_FROM, T_DARK_TO, time), blur)
	_camera(time)


## The player's eye, turning up to the vent as it opens, then swaying drunkenly as the gas reaches it.
func _camera(time: float) -> void:
	var dir0 := -_eye0.basis.z
	var dir := dir0
	if _vent != null:
		var to_vent := (_vent.mouth_transform().origin - _eye0.origin).normalized()
		dir = dir0.slerp(to_vent, smoothstep(T_LOOK_FROM, T_LOOK_TO, time))
	var dizzy := smoothstep(T_LOOK_TO, 5.0, time)
	var look := Basis.looking_at(dir, Vector3.UP)
	look = Basis(dir, 0.12 * dizzy * sin(time * 1.7)) * look
	var eye := _eye0.origin + Vector3(0.04 * sin(time * 1.3), 0.03 * sin(time * 2.1), 0.0) * dizzy
	camera.global_transform = Transform3D(look, eye)
	camera.fov = _fov0


func _on_end(_skipped: bool) -> void:
	if _gus != null:
		_gus.celebrate(false)
	if _hiss != null:
		_hiss.stop()
	if _cut != null:
		_cut.clear()
