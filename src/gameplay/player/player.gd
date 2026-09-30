class_name Player
extends CharacterBody3D
## First-person walker with three modes (08 §2.2): WALK, CUE (aim and strike), CARRY (holding a camera rig).
## Yaw rotates the body, pitch rotates Head only — keeping them split is what stops the capsule tipping over.
## Local player: bound to the level once (`bind`), reads keys and TouchControls. Puppet: a remote peer's avatar,
## fed by `apply_pose` and interpolated 100 ms behind (04 push_player_pose).

enum Mode { WALK, CUE, CARRY }

signal mode_changed(mode: Mode)

const POSE_BYTES := 16
const INTERP_DELAY_MSEC := 100
const PITCH_LIMIT := deg_to_rad(89.0)
const EYE_M := 1.6
const REACH_M := 2.0                 # same number WorldInteractions validates
const PLACE_AHEAD_M := 1.5
const BAR_KINDS: Array[StringName] = [&"bar_buy", &"bar_serve", &"throw_drink"]  # one counter, one menu
const SEAT_COLOURS: Array[Color] = [
	Color("e0534a"), Color("4a90e0"), Color("e0c14a"), Color("5ab86a"),
]

@export var speed := 3.5             # [tune]
@export var jump_velocity := 4.5
@export var mouse_sensitivity := 0.0025
@export var touch_look_deg_per_px := 0.20  # [tune]

var mode := Mode.WALK
var is_local := false
var prompt := ""

var _rd: Node                        # RoundDirector
var _sim: PhysicsSim
var _world: WorldInteractions
var _shop: ShopMenu
var _picker: DrinkPicker
var _cameras: CameraRigs
var _controls: TouchControls
var _target: Interactable
var _held_rig := 0                   # CameraRig number while CARRY (derived from the mirrored holders)
var _placing := false
var _clock_end_msec := 0             # local end of the host's shot clock; 0 = none
var _jump_queued := false
var _saved_pos := Vector3.ZERO
var _saved_yaw := 0.0
var _saved_pitch := 0.0
var _cue_pitch := 0.0
var _floor_y := 0.0
var _pose := PackedByteArray()
var _samples: Array[PackedFloat64Array] = []  # puppet: [msec, x, y, z, yaw, pitch, mode]
var _puppet_mode := Mode.WALK
var _avatar: Node3D
var _avatar_cue: MeshInstance3D
var _avatar_head: MeshInstance3D

@onready var head: Node3D = $Head
@onready var cam: Camera3D = $Head/headCam
@onready var cue: CueController = $Head/CueController
@onready var _probe: ShapeCast3D = $InteractProbe


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # camera is driven from _process
	_pose.resize(POSE_BYTES)
	set_physics_process(false)
	set_process(false)
	set_process_unhandled_input(false)


## One-time wiring of the local player to the level (contract §3 names). Never called on puppets.
func bind(level: Node) -> void:
	is_local = true
	var table: Table = level.get_node("Table")
	_rd = level.get_node("RoundDirector")
	_sim = table.sim
	_world = level.get_node_or_null("WorldInteractions")
	_shop = level.get_node_or_null("UILayer/ShopMenu")
	_picker = level.get_node_or_null("UILayer/DrinkPicker")
	_cameras = level.get_node_or_null("Cameras")
	_controls = level.get_node_or_null("UILayer/TouchControls")
	cue.table = table
	cue.effects = level.get_node_or_null("EffectManager")
	cue.controls = _controls
	cue.player = self
	cue.fired.connect(_on_fired)
	_rd.shooter_changed.connect(_on_shooter_changed)
	_rd.shot_clock_started.connect(func(seconds: float) -> void: _clock_end_msec = Time.get_ticks_msec() + int(seconds * 1000.0))
	_rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], _f: bool) -> void: _clock_end_msec = 0)
	_sim.shot_rejected.connect(func(reason: StringName) -> void: _toast(String(reason).replace("_", " ")))
	if _world != null:
		_world.interaction_rejected.connect(func(_k: StringName, reason: StringName) -> void: _toast(String(reason).replace("_", " ")))
	if _cameras != null:
		_cameras.holders_changed.connect(_sync_carry)
	if _picker != null:
		_picker.picked.connect(_on_picked)
		_picker.shop_requested.connect(func() -> void:
			if _shop != null:
				_shop.open())
	if _controls != null:
		_controls.interact_pressed.connect(interact)
		_controls.shoot_pressed.connect(toggle_cue)
		_controls.jump_pressed.connect(func() -> void: _jump_queued = true)
		_controls.back_pressed.connect(exit_cue)
		_controls.place_pressed.connect(place_camera.bind(false))
		_controls.drop_pressed.connect(place_camera.bind(true))
		_controls.pocket_tapped.connect(cue.call_pocket)
		_controls.power.released.connect(cue.release_power)
		_controls.spin_pad.changed.connect(cue.set_spin)
		_controls.elevation.changed.connect(cue.set_elevation)
		if not _controls.touch:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_sync_can_shoot()
	set_physics_process(true)
	set_process(true)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and mode != Mode.CUE:
			look(-event.relative.x * mouse_sensitivity, -event.relative.y * mouse_sensitivity)
	elif event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if _controls == null or not _controls.touch:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(&"interact"):
		interact()
	elif event.is_action_pressed(&"cue_mode"):
		toggle_cue()


func look(yaw_rad: float, pitch_rad: float) -> void:
	rotate_y(yaw_rad)
	head.rotation.x = clampf(head.rotation.x + pitch_rad, -PITCH_LIMIT, PITCH_LIMIT)


func _process(_delta: float) -> void:
	if is_local:
		if _controls != null and mode != Mode.CUE:
			_controls.set_clock(shot_clock_text())
			var d := _controls.look.consume()
			if d != Vector2.ZERO:
				var k := deg_to_rad(touch_look_deg_per_px)
				look(-d.x * k, -d.y * k)
	else:
		_puppet_step()


func _physics_process(delta: float) -> void:
	if mode == Mode.CUE:
		return
	if not is_on_floor():
		velocity += get_gravity() * delta
	if is_on_floor() and (Input.is_action_just_pressed(&"jump") or _jump_queued):
		velocity.y = jump_velocity
	_jump_queued = false
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	if _controls != null:
		input = (input + _controls.stick.value).limit_length(1.0)
	var direction := transform.basis * Vector3(input.x, 0.0, input.y)
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()
	_scan()


# --- interact -------------------------------------------------------------------------------------

## Nearest Interactable within REACH_M. The probe sphere is the broad phase; the reach test is the host's
## own (feet to prop origin), so a prompt never shows for a use the host would refuse.
func _scan() -> void:
	var best: Interactable
	var best_d := REACH_M
	for i in _probe.get_collision_count():
		var it := _probe.get_collider(i) as Interactable
		if it == null:
			continue
		var rig := it.get_parent() as CameraRig
		if rig != null and rig.held_by != 0:  # someone is carrying it
			continue
		var d := global_position.distance_to(it.global_position)
		if d <= best_d:
			best = it
			best_d = d
	_target = best
	var text := best.prompt if best != null else ""
	if best != null and best.effective_kind() in BAR_KINDS:
		text = "Bar counter"
	elif _picker != null and _picker.is_open():
		_picker.close()  # walked away
	if mode == Mode.CARRY:
		text = "Place the camera"
	if text != prompt:
		prompt = text
		if _controls != null:
			_controls.set_prompt(text)


func interact() -> void:
	if mode == Mode.CUE:
		return
	if mode == Mode.CARRY:
		place_camera(false)
		return
	if _target == null:
		return
	if _target.effective_kind() in BAR_KINDS:  # the counter menu: serve / throw here, or on to the Shop
		if _picker != null:
			_picker.open(&"bar_serve")
		return
	if not _target.try_use({}):
		_toast("wait")


func place_camera(at_feet: bool) -> void:
	if mode != Mode.CARRY or _world == null:
		return
	var fwd := -global_basis.z
	var spot := global_position + (Vector3.ZERO if at_feet else Vector3(fwd.x, 0.0, fwd.z).normalized() * PLACE_AHEAD_M)
	_placing = true
	_world.request(&"move_camera", _held_rig, {&"place_at": Vector3(spot.x, 0.0, spot.z)})


## The bar counter menu's pick: the host validates reach, cooldown, Cash and the hostile caps (03 §3.4).
func _on_picked(kind: StringName, drink_id: StringName, target_peer: int) -> void:
	if _world != null:
		_world.request(kind, 0, {&"drink_id": drink_id, &"target_peer": target_peer})


## CARRY follows the host's mirrored `held_by`, never our own request: a grab the host ignored (rig already
## held) leaves us walking, and losing the rig to someone else ends CARRY.
func _sync_carry() -> void:
	var mine := 0
	for i in _cameras.rigs.size():
		if _cameras.rigs[i].held_by == multiplayer.get_unique_id():
			mine = i + 1
	if mine != 0 and mode == Mode.WALK:
		_held_rig = mine
		_set_mode(Mode.CARRY)
	elif mine == 0 and mode == Mode.CARRY:
		if not _placing:
			_toast("camera taken")
		_held_rig = 0
		_set_mode(Mode.WALK)
	_placing = false


# --- CUE mode -------------------------------------------------------------------------------------

func toggle_cue() -> void:
	if mode == Mode.CUE:
		exit_cue()
	elif mode == Mode.WALK:
		enter_cue()


## Shooter + balls at rest + within reach of the cue ball. Returns whether CUE started.
func enter_cue() -> bool:
	if mode != Mode.WALK or _rd == null:
		return false
	if _rd.current_shooter_id != multiplayer.get_unique_id():
		_toast("not your turn")
		return false
	var ball := _cue_ball()
	if ball == null or _sim.awake > 0 or not _rd.can_strike(ball):
		_toast("balls moving")
		return false
	if cam.global_position.distance_to(ball.global_position) > ball.spec.cue_reach_m:
		_toast("too far from the cue ball")
		return false
	_saved_pos = global_position
	_saved_yaw = rotation.y
	_saved_pitch = head.rotation.x
	_floor_y = global_position.y
	var eye_y := _floor_y + EYE_M
	_cue_pitch = atan2(ball.global_position.y - eye_y, CueController.BACK_M + CueController.LOOK_AHEAD_M)
	velocity = Vector3.ZERO
	_set_mode(Mode.CUE)
	if _controls != null and not _controls.touch:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	cue.begin(ball, rotation.y)
	return true


func exit_cue() -> void:
	if mode != Mode.CUE:
		return
	cue.end()
	global_position = _saved_pos
	rotation.y = _saved_yaw
	head.rotation.x = _saved_pitch
	_set_mode(Mode.WALK)


## CueController each frame: the body sits behind the cue ball on the aim line, looking down it.
func pin_to_cue(ball_pos: Vector3, yaw: float) -> void:
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	global_position = Vector3(ball_pos.x, _floor_y, ball_pos.z) - fwd * CueController.BACK_M
	rotation.y = yaw
	head.rotation.x = _cue_pitch


func _on_fired(_intent: ShotIntent) -> void:
	exit_cue()


func _on_shooter_changed(peer_id: int) -> void:
	if peer_id != multiplayer.get_unique_id():
		exit_cue()
	_sync_can_shoot()


func _sync_can_shoot() -> void:
	if _controls != null:
		_controls.set_can_shoot(_rd.current_shooter_id == multiplayer.get_unique_id())


## "Shot clock N" while a clock runs and it is my turn (CUE adds it to its own status line); "" otherwise.
func shot_clock_text() -> String:
	if _clock_end_msec == 0 or _rd.current_shooter_id != multiplayer.get_unique_id():
		return ""
	return "Shot clock %d" % maxi(0, ceili((_clock_end_msec - Time.get_ticks_msec()) / 1000.0))


func _cue_ball() -> Ball:
	for b: Ball in _rd.get_balls():
		if b.is_cue_ball and not b.is_pocketed:
			return b
	return null


func _set_mode(m: Mode) -> void:
	mode = m
	if _controls != null:
		_controls.set_mode(m)
	mode_changed.emit(m)


func _toast(text: String) -> void:
	if _controls != null:
		_controls.toast(text.substr(0, 1).to_upper() + text.substr(1))


# --- pose (04 push_player_pose) and puppet avatar -----------------------------------------------------

## pos 3×f32 | yaw u16 (0..2π) | u16 = mode << 14 | pitch (14 bit, ±π/2). 16 B, trusted (friends-only, 04 §6).
func pack_pose() -> PackedByteArray:
	var p := global_position
	_pose.encode_float(0, p.x)
	_pose.encode_float(4, p.y)
	_pose.encode_float(8, p.z)
	_pose.encode_u16(12, int(wrapf(rotation.y, 0.0, TAU) / TAU * 65535.0))
	var q := int((clampf(head.rotation.x / (PI / 2.0), -1.0, 1.0) * 0.5 + 0.5) * 16383.0)
	_pose.encode_u16(14, (int(mode) << 14) | q)
	return _pose


func apply_pose(blob: PackedByteArray) -> void:
	if blob.size() != POSE_BYTES:
		return
	var tail := blob.decode_u16(14)
	var s := PackedFloat64Array([
		Time.get_ticks_msec(), blob.decode_float(0), blob.decode_float(4), blob.decode_float(8),
		blob.decode_u16(12) * TAU / 65536.0, ((tail & 0x3FFF) / 16383.0 * 2.0 - 1.0) * (PI / 2.0), tail >> 14,
	])
	if _samples.is_empty():
		_show(s, s, 0.0)
	_samples.append(s)
	if _samples.size() > 8:
		_samples.pop_front()


## Turn this Player into a remote peer's avatar: no camera, no cue, no input; body + head + tag + cue stick.
func make_puppet(display_name: String, colour: Color) -> void:
	is_local = false
	cam.queue_free()
	cue.queue_free()
	set_physics_process(false)
	set_process(true)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	_avatar = Node3D.new()
	add_child(_avatar)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.3
	capsule.height = 1.75
	capsule.radial_segments = 12
	capsule.rings = 4
	body.mesh = capsule
	body.material_override = mat
	body.position.y = 0.875
	_avatar.add_child(body)
	_avatar_head = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.13
	sphere.height = 0.26
	sphere.radial_segments = 12
	sphere.rings = 6
	_avatar_head.mesh = sphere
	_avatar_head.material_override = mat
	head.add_child(_avatar_head)
	_avatar_head.position.z = -0.1
	var tag := Label3D.new()
	tag.text = display_name
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.fixed_size = true
	tag.pixel_size = 0.0009
	tag.font_size = 32
	tag.outline_size = 8
	tag.position.y = 2.05
	add_child(tag)
	_avatar_cue = MeshInstance3D.new()
	var stick := CylinderMesh.new()
	stick.top_radius = 0.008
	stick.bottom_radius = 0.015
	stick.height = 1.45
	stick.radial_segments = 8
	_avatar_cue.mesh = stick
	_avatar_cue.hide()
	add_child(_avatar_cue)


func _puppet_step() -> void:
	if _samples.is_empty():
		return
	var t := Time.get_ticks_msec() - INTERP_DELAY_MSEC
	var i := 0
	while i < _samples.size() - 2 and _samples[i + 1][0] <= t:
		i += 1
	var a := _samples[i]
	var b := _samples[mini(i + 1, _samples.size() - 1)]
	var span := maxf(b[0] - a[0], 1.0)
	_show(a, b, clampf((t - a[0]) / span, 0.0, 1.0))


func _show(a: PackedFloat64Array, b: PackedFloat64Array, w: float) -> void:
	global_position = Vector3(a[1], a[2], a[3]).lerp(Vector3(b[1], b[2], b[3]), w)
	rotation.y = lerp_angle(a[4], b[4], w)
	head.rotation.x = lerpf(a[5], b[5], w)
	var m := int((b if w >= 0.5 else a)[6]) as Mode
	if m != _puppet_mode and _avatar_cue != null:
		_puppet_mode = m
		_avatar_cue.visible = m == Mode.CUE
		if m == Mode.CUE:  # tip on the ball spot in front of the shooter, cue lying along the aim line
			var reach := CueController.BACK_M - 0.06
			_avatar_cue.position = Vector3(0.0, 0.957, -reach + 0.725)
			_avatar_cue.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
