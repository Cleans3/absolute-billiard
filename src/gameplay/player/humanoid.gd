class_name Humanoid
extends Node3D
## Low-poly person built in code (06 P15, 08 §2.7): 11 bones, one vertex-coloured material, two skinned
## meshes (body: trunk and its lid, arms, legs; head: head, face, hat, neck) = 2 draw calls. Animated procedurally (breath, walk from measured speed, CUE,
## CARRY and SIT stances, hand targets, the CUE rig that puts both hands on the real stick). `ragdoll()` hands the bones to a PhysicalBoneSimulator3D; its 11 bodies are
## on no layer and not simulated until then, and `get_up()` blends back to the pose.
## Rests facing -Z with the feet at this node's origin, like the CharacterBody3D it hangs from.

signal got_up  ## simulation stopped (the blend back to the pose starts); `pelvis_at_getup` is where the body lay

enum Stance { STAND, CUE, CARRY, SIT }  ## STAND..CARRY in Player.Mode's order; SIT is a WALK sub-state (Player.seated, 06 P33 U7)
enum B { PELVIS, TORSO, HEAD, UARM_R, LARM_R, UARM_L, LARM_L, THIGH_R, SHIN_R, THIGH_L, SHIN_L }

const HEAD_LAYER := 1 << 19    ## render layer 20: the local player's camera culls it, shadows still fall
const MIRROR_LAYER := 1 << 9   ## render layer 10: what the wall mirror's window pass draws (avatars)
const RAG_LAYER := 1 << 4      ## collision layer 5 `ragdoll` (07 §1): bones never touch each other or balls
const RAG_MASK := 2 | 8        ## table rails + world (floor, walls, bar)
const BLEND_SEC := 0.4
const WALK_MPS := 3.5
const STRIDE_RAD_PER_M := 4.5  ## gait phase per metre walked
const SMOOTH := 18.0           ## pose smoothing rate (1/s)
const GOLD := Color("e8b923")
const CAP_BOTTOM := 1  ## `_cyl` end caps
const CAP_TOP := 2
const QUIRK_BARKEEP := &"barkeep"  ## `set_quirk`: the Bartender's exaggerated surfaces

const NAMES: PackedStringArray = [
	"pelvis", "torso", "head", "uarm_r", "larm_r", "uarm_l", "larm_l", "thigh_r", "shin_r", "thigh_l", "shin_l",
]
const PARENT: PackedInt32Array = [-1, 0, 1, 1, 3, 1, 5, 0, 7, 0, 9]
## Bone origin = the joint at its proximal end, standing pose (all rest rotations are identity).
const ORIGIN: Array[Vector3] = [
	Vector3(0, 0.93, 0), Vector3(0, 1.03, 0), Vector3(0, 1.48, 0),
	Vector3(0.22, 1.43, 0), Vector3(0.22, 1.13, 0), Vector3(-0.22, 1.43, 0), Vector3(-0.22, 1.13, 0),
	Vector3(0.10, 0.93, 0), Vector3(0.10, 0.50, 0), Vector3(-0.10, 0.93, 0), Vector3(-0.10, 0.50, 0),
]
## Physical body per bone: [centre, shape kind (0 box, 1 capsule, 2 sphere), a, b, c, mass kg]
##   box (x, y, z) · capsule (radius, height, -) · sphere (radius, -, -)
const SEG: Array = [
	[Vector3(0, 0.945, 0), 0, 0.30, 0.17, 0.19, 9.0],
	[Vector3(0, 1.265, 0), 0, 0.36, 0.47, 0.20, 14.0],
	[Vector3(0, 1.60, 0), 2, 0.115, 0.0, 0.0, 4.0],
	[Vector3(0.22, 1.28, 0), 1, 0.045, 0.30, 0.0, 2.0],
	[Vector3(0.22, 0.96, 0), 1, 0.04, 0.34, 0.0, 1.5],
	[Vector3(-0.22, 1.28, 0), 1, 0.045, 0.30, 0.0, 2.0],
	[Vector3(-0.22, 0.96, 0), 1, 0.04, 0.34, 0.0, 1.5],
	[Vector3(0.10, 0.715, 0), 1, 0.065, 0.43, 0.0, 7.0],
	[Vector3(0.10, 0.29, 0), 1, 0.05, 0.42, 0.0, 4.0],
	[Vector3(-0.10, 0.715, 0), 1, 0.065, 0.43, 0.0, 7.0],
	[Vector3(-0.10, 0.29, 0), 1, 0.05, 0.42, 0.0, 4.0],
]
## How much of a knock's impulse each bone takes, in B order.
const SHOVE_SHARE: PackedFloat32Array = [1.0, 1.3, 1.6, 1.3, 1.3, 1.3, 1.3, 0.6, 0.3, 0.6, 0.3]
const LEAN_RAD := 0.55     ## trunk pitch while leaning on a rail
const LEAN_STILL_MPS := 1.0  ## walking off ends a lean early
const LEAN_HANDS := 0.12   ## the two hands rest this far either side of the point under them
const UPPER := 0.30     ## shoulder → elbow
const FORE := 0.295     ## elbow → hand centre
const THIGH := 0.43
const SHIN := 0.42
const ANKLE := 0.08
## CUE rig (06 P33 U1). Stance legs (right, left): thigh swing, knee flex; a lean past RIG_LEAN.x crouches both knees by up to CROUCH_KNEE.
const CUE_THIGH := Vector2(-0.25, 0.30)
const CUE_KNEE := Vector2(0.08, 0.45)
const CROUCH_KNEE := 0.7
const RIG_LEAN := Vector2(0.65, 1.0)  ## trunk pitch (rad) searched for hands on their spots: the stance's lean .. the deepest lean that is still a stance
const RIG_LEAN_MAX := 1.25            ## ... and, when no lean in that range reaches, the deepest the body will bend while the hands slide along the stick
const RIG_STEP := 0.05
const RIG_REACH := UPPER + FORE - 0.02  ## the arm stops short of fully straight
const RIG_SHIFT := 0.2                ## the body stands this far left of the stick so it passes the right shoulder
const GRIP_FROM_BUTT_M := Vector2(0.15, 0.6)  ## the rear hand holds the stick between these distances from its butt end
const HAND_MIN_M := 0.1               ## ... and either hand stays this far from the tip
const RIG_NEAR_M := 0.25              ## ... and holds it at least this far from its own shoulder (a stick passing by the shoulder would put the hand in it)
## SIT (06 P33 U7): thighs level on the seat, shins hanging, hands on the thighs.
const SIT_THIGH := 1.45
const SIT_SHIN := 0.1                 ## shins hang this much forward of vertical
const SEAT_LIFT := 0.075              ## hip joint above the seat surface

static var _material: ShaderMaterial  ## every Humanoid shares it: colours live in the vertices (humanoid.gdshader)

var stance := Stance.STAND
var pelvis_at_getup := Vector3.ZERO

var _skin: CharacterSkin
var _skel: Skeleton3D
var _sim: PhysicalBoneSimulator3D
var _pbs: Array[PhysicalBone3D] = []
var _body_mi: MeshInstance3D
var _head_mi: MeshInstance3D
var _quirk := &""
var _face: MeshInstance3D  ## the Bartender's real face (BarkeepFace): the modelled one is not painted and this takes the head surface's layers
var _first_person := false
var _ragdoll := false
var _blend := 1.0               ## 0 → 1 over BLEND_SEC after get_up()
var _snap: Array[Transform3D] = []  ## world transform of every bone origin at get_up()
var _time := 0.0
var _phase := 0.0
var _speed := 0.0
var _vel := Vector3.ZERO
var _last_pos := Vector3.ZERO
var _look := Vector2.ZERO       ## yaw, pitch of the head (radians, relative to the body)
var _hand: Array = [null, null]  ## right, left: Vector3 target in this node's space, or null
var _lean_left := 0.0           ## seconds of rail lean to go (transient, never on the wire: 06 P25)
var _lean_to := Vector3.ZERO    ## where the hands rest, this node's space
var _rot: Array[Quaternion] = []
var _pelvis_pos := ORIGIN[0]
var _t_rot: Array[Quaternion] = []
var _t_pelvis := ORIGIN[0]
var _rig_on := false            ## CUE rig: this node stands at a floor point of its own and both hands follow the stick
var _rig_home := Transform3D.IDENTITY
var _rig_tip := Vector3.ZERO    ## world: the stick's tip,
var _rig_butt := Vector3.BACK   ## ... the unit direction from the tip to the butt,
var _rig_len := 1.45
var _rig_bridge := 0.36         ## ... and the bridge hand's distance from the tip
var _cue_lean := 0.65           ## solved by the rig each frame, else the plain stance's
var _cue_crouch := 0.0
var _rig_hand: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]  ## right, left: where the rig holds the stick, this node's space
var _rig_gap: Array[float] = [0.0, 0.0]                        ## how far short of it each arm falls (m)
var _seat_top := 0.8            ## SIT: the seat surface, this node's space


func _ready() -> void:
	_build_skeleton()
	if _skin == null:
		_skin = CharacterSkin.new()
	apply_skin(_skin)
	_last_pos = global_position
	for i in NAMES.size():
		_rot.append(Quaternion.IDENTITY)
		_t_rot.append(Quaternion.IDENTITY)
	_compute_pose()
	_rot = _t_rot.duplicate()
	_pelvis_pos = _t_pelvis
	_write_pose(1.0)


# --- public ----------------------------------------------------------------------------------------

func is_ragdoll() -> bool:
	return _ragdoll


func skin() -> CharacterSkin:
	return _skin


## Re-colours and re-hats the body (rebuilds both meshes, ~1k vertices; the skeleton is untouched).
func apply_skin(skin: CharacterSkin) -> void:
	_skin = skin
	if _skel == null:
		return
	var body := _new_st()
	var head := _new_st()
	_paint(body, head, skin)
	_body_mi.mesh = body.commit()
	_head_mi.mesh = head.commit()
	_body_mi.skin = _skel.create_skin_from_rest_transforms()
	_head_mi.skin = _body_mi.skin


## A special look for a non-player body (the Bartender): rebuilds the surfaces. `&""` = a plain person.
func set_quirk(quirk: StringName) -> void:
	_quirk = quirk
	apply_skin(_skin)


## The Bartender wears a real face (BarkeepFace, a mesh on the head bone) instead of the modelled head, eyes, brows, nose and mustache:
## those are left out of the surfaces and the mesh follows the head surface's render layers. `null` paints the modelled face again.
func set_face(face: MeshInstance3D) -> void:
	_face = face
	apply_skin(_skin)
	set_first_person(_first_person)


## Local player: the head surface (head, face, hat, neck) leaves the camera's cull mask (the Player removes HEAD_LAYER from it)
## but keeps casting shadows; trunk, arms, legs and feet stay visible when looking down. A mirror camera keeps HEAD_LAYER.
func set_first_person(on: bool) -> void:
	_first_person = on
	_head_mi.layers = HEAD_LAYER if on else 1 | MIRROR_LAYER  # the mirror camera draws HEAD_LAYER too
	if _face != null:
		_face.layers = _head_mi.layers


## Local player in CUE: the leaning trunk and arms would fill the aiming view, so the body joins the head on HEAD_LAYER: the
## player's camera culls it, the mirror's window pass and every other camera still draw it, and it keeps its shadow.
func set_body_hidden(on: bool) -> void:
	_body_mi.layers = HEAD_LAYER if on else 1 | MIRROR_LAYER


## Lean on a rail: the trunk pitches toward `world_point` and both hands rest on it for `seconds`, or until the body
## walks off. Transient and local to each peer's copy of this body: every peer starts it from the applied interaction.
func lean_on(world_point: Vector3, seconds: float) -> void:
	_lean_to = to_local(world_point)
	_lean_left = seconds


func is_leaning() -> bool:
	return _lean_left > 0.0


## Head turn relative to the body, radians (positive pitch looks up). Clamped to what a neck can do.
func set_look(yaw: float, pitch: float) -> void:
	_look = Vector2(clampf(yaw, -1.2, 1.2), clampf(pitch, -1.0, 1.0))


## Yaw and pitch that would aim the head at a world point, for `set_look` (the caller may ease toward them).
func look_angles(world_point: Vector3) -> Vector2:
	var p := to_local(world_point) - Vector3(0.0, ORIGIN[B.HEAD].y + 0.12, 0.0)
	return Vector2(atan2(-p.x, -p.z), atan2(p.y, Vector2(p.x, p.z).length()))


## Reach a hand (0 right, 1 left) to a point in this node's space with two-bone IK; `clear_hand` goes back to the stance.
func set_hand(side: int, point: Vector3) -> void:
	_hand[side] = point


func clear_hand(side: int) -> void:
	_hand[side] = null


## CUE rig (06 P33 U1, 08 §2.7): the body stands at the floor point `origin` facing `yaw` and holds the real stick, whose tip is at
## `tip` (world) and whose butt lies along the unit vector `butt_dir`; the bridge hand rests `bridge_s` back from the tip. Call it every
## frame while the stance is CUE: the trunk bends the least it needs to for the hands to hold the stick, the hands slide along it when
## the table is too wide to reach, the feet stay where `origin` is. `clear_cue_rig` puts the node back where it hung.
func set_cue_rig(origin: Vector3, yaw: float, tip: Vector3, butt_dir: Vector3, length: float, bridge_s: float) -> void:
	var first := not _rig_on
	if first:
		_rig_home = transform
	_rig_on = true
	global_transform = Transform3D(Basis(Vector3.UP, yaw), origin)
	_rig_tip = tip
	_rig_butt = butt_dir.normalized()
	_rig_len = length
	_rig_bridge = bridge_s
	if first:
		_speed = 0.0
		snap_pose()


func clear_cue_rig() -> void:
	if not _rig_on:
		return
	_rig_on = false
	transform = _rig_home
	_cue_lean = RIG_LEAN.x
	_cue_crouch = 0.0


func has_cue_rig() -> bool:
	return _rig_on


## How far short of its spot on the stick each arm falls after the last solve (0 right, 1 left), metres: 0 = holding it.
func rig_gap(side: int) -> float:
	return _rig_gap[side]


## The trunk pitch the rig solved (rad).
func rig_lean() -> float:
	return _cue_lean


## Settles the animated pose at once instead of easing toward it (a teleport, a probe).
func snap_pose() -> void:
	if _skel == null or _ragdoll:
		return
	_compute_pose()
	_rot = _t_rot.duplicate()
	_pelvis_pos = _t_pelvis
	_blend = 1.0
	_write_pose(1.0)


## World position of a hand's centre (0 right, 1 left), read back from the skeleton's pose.
func hand_world(side: int) -> Vector3:
	var fore := B.LARM_R if side == 0 else B.LARM_L
	return _skel.global_transform * (_skel.get_bone_global_pose(fore) * Vector3(0.0, -FORE, 0.0))


## World position of `local` in a bone's frame (default: the bone's origin, the joint), read back from the skeleton's pose
## (`bone_world` reads the ragdoll's bodies instead).
func bone_point(bone: int, local := Vector3.ZERO) -> Vector3:
	return _skel.global_transform * (_skel.get_bone_global_pose(bone) * local)


## SIT: the seat surface's height in this node's space. Set it before the stance.
func set_seat(top_y: float) -> void:
	_seat_top = top_y


## Where the hip joint rides on a seat whose surface is `top_y` high (the sitter's camera lowers by the same amount).
static func sit_hip_y(top_y: float) -> float:
	return top_y + SEAT_LIFT


## Limp: the bones are handed to physics. `impulse` is a velocity change (m/s) of the body, on top of the speed it
## was walking at; the head and trunk take more of it than the legs, so a shove topples rather than slides.
func ragdoll(impulse: Vector3) -> void:
	if not _ragdoll:
		if _lean_left > 0.0:
			_lean_left = 0.0
			clear_hand(0)
			clear_hand(1)
		_ragdoll = true
		_blend = 1.0
		_skel.force_update_all_bone_transforms()
		_set_layers(RAG_LAYER, RAG_MASK)
		_sim.physical_bones_start_simulation()
		impulse += _vel
	for i in _pbs.size():
		_pbs[i].linear_velocity += impulse * SHOVE_SHARE[i]
		_pbs[i].angular_velocity += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * impulse.length() * 0.4


## Stand up: remember where the body lies, stop the simulation and blend from the lying pose to the animated one.
func get_up() -> void:
	if not _ragdoll:
		return
	pelvis_at_getup = pelvis_position()
	_snap.clear()
	for i in NAMES.size():
		_snap.append(bone_world(i))
	_set_layers(0, 0)
	_sim.physical_bones_stop_simulation()
	_ragdoll = false
	_blend = 0.0
	got_up.emit()


func _set_layers(layer: int, mask: int) -> void:
	for pb in _pbs:
		pb.collision_layer = layer
		pb.collision_mask = mask


## World transform of a bone's origin (the joint), from its physical body while limp.
func bone_world(i: int) -> Transform3D:
	var pb := _pbs[i]
	return pb.global_transform * pb.body_offset.affine_inverse()


func pelvis_position() -> Vector3:
	return _pbs[B.PELVIS].global_position if _ragdoll else global_transform * _pelvis_pos


## Where a first-person camera sits while the head is a ragdoll bone: the head centre, a little forward of it.
func eye_transform() -> Transform3D:
	return bone_world(B.HEAD) * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.12, -0.09))


## Smoothed horizontal speed (m/s) measured from this node's own movement.
func speed() -> float:
	return _speed


# --- animation --------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var p := global_position
	var v := (p - _last_pos) / maxf(delta, 0.0001)
	_last_pos = p
	if v.length() > 9.0 or _rig_on or stance == Stance.SIT:  # a teleport (CUE pin, respawn), the rig sliding its feet, a seat: not walking
		v = Vector3.ZERO
	_vel = v
	_speed = lerpf(_speed, Vector2(v.x, v.z).length(), 1.0 - exp(-10.0 * delta))


func _process(delta: float) -> void:
	if _ragdoll:
		return
	_time += delta
	_phase += _speed * delta * STRIDE_RAD_PER_M
	_step_lean(delta)
	_compute_pose()
	var a := 1.0 - exp(-SMOOTH * delta)
	for i in _rot.size():
		_rot[i] = _rot[i].slerp(_t_rot[i], a)
	_pelvis_pos = _pelvis_pos.lerp(_t_pelvis, a)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / BLEND_SEC)
	_write_pose(_blend)


func _step_lean(delta: float) -> void:
	if _lean_left <= 0.0:
		return
	_lean_left -= delta
	if _lean_left <= 0.0 or _speed > LEAN_STILL_MPS:
		_lean_left = 0.0
		clear_hand(0)
		clear_hand(1)
		return
	var side := Vector3(-_lean_to.z, 0.0, _lean_to.x).normalized() * LEAN_HANDS  # across the lean direction, + = the body's right
	set_hand(0, _lean_to + side)
	set_hand(1, _lean_to - side)


## Fills _t_rot / _t_pelvis: where every bone wants to be this frame, before smoothing.
func _compute_pose() -> void:
	var k := clampf(_speed / WALK_MPS, 0.0, 1.3)
	var s := sin(_phase)
	var c := cos(_phase)
	var cue := stance == Stance.CUE
	var carry := stance == Stance.CARRY
	var sit := stance == Stance.SIT
	var reaching := _hand[0] != null or _hand[1] != null
	var th_r := 0.0
	var th_l := 0.0
	var fl_r := 0.05
	var fl_l := 0.05
	if cue:  # bridge leg forward and bent, back leg long; a deeper lean bends both knees (the pelvis drops with them)
		if _rig_on:
			_solve_rig()
		var bend := CROUCH_KNEE * _cue_crouch
		th_r = CUE_THIGH.x
		fl_r = CUE_KNEE.x + bend
		th_l = CUE_THIGH.y
		fl_l = CUE_KNEE.y + bend
	elif sit:  # thighs level, shins hanging
		th_r = SIT_THIGH
		th_l = SIT_THIGH
		fl_r = SIT_THIGH - SIT_SHIN
		fl_l = SIT_THIGH - SIT_SHIN
	else:
		th_r = 0.45 * k * s
		th_l = -th_r
		fl_r += 0.8 * k * maxf(0.0, c)
		fl_l += 0.8 * k * maxf(0.0, -c)
	# feet on the floor: the pelvis rides at the height of the straighter leg
	var ext_r := THIGH * cos(th_r) + SHIN * cos(th_r - fl_r) + ANKLE
	var ext_l := THIGH * cos(th_l) + SHIN * cos(th_l - fl_l) + ANKLE
	var breath := sin(_time * 1.7)
	var sway := sin(_time * 0.45) * 0.006
	var pelvis := Vector3(sway + 0.012 * k * s, (sit_hip_y(_seat_top) if sit else maxf(ext_r, ext_l)) + 0.003 * breath, 0.0)
	var lean := 0.0
	var lean_axis := Vector3.RIGHT  # the trunk pitches about this (right = forward)
	if _lean_left > 0.0:
		var flat := Vector3(_lean_to.x, 0.0, _lean_to.z)
		if flat.length() > 0.05:
			lean_axis = flat.normalized().cross(Vector3.UP)
		lean = LEAN_RAD
	elif cue:
		lean = _cue_lean
		pelvis.x -= RIG_SHIFT  # stands left of the cue line so the stick passes the right shoulder
	elif sit:
		lean = 0.1
	elif carry:
		lean = 0.08
	elif reaching:
		lean = 0.22
	var pelvis_rot := Quaternion(Vector3.UP, 0.07 * k * s)
	var torso_rot := Quaternion(lean_axis, -lean + 0.014 * breath) * Quaternion(Vector3.UP, -0.1 * k * s)
	_t_pelvis = pelvis
	_t_rot[B.PELVIS] = pelvis_rot
	_t_rot[B.TORSO] = torso_rot
	_t_rot[B.HEAD] = Quaternion(Vector3.UP, _look.x) * Quaternion(Vector3.RIGHT, _look.y) * Quaternion(lean_axis, lean * 0.9)
	_t_rot[B.THIGH_R] = Quaternion(Vector3.RIGHT, th_r)
	_t_rot[B.SHIN_R] = Quaternion(Vector3.RIGHT, -fl_r)
	_t_rot[B.THIGH_L] = Quaternion(Vector3.RIGHT, th_l)
	_t_rot[B.SHIN_L] = Quaternion(Vector3.RIGHT, -fl_l)
	# arms: IK to a hand target, else the stance's, else the walk swing
	var torso_origin := pelvis + pelvis_rot * (ORIGIN[B.TORSO] - ORIGIN[B.PELVIS])
	var torso_g := pelvis_rot * torso_rot
	for side in 2:
		var sgn := 1.0 if side == 0 else -1.0
		var ua := B.UARM_R if side == 0 else B.UARM_L
		var target: Variant = _hand[side]
		if target == null and cue:
			target = _rig_hand[side] if _rig_on else (Vector3(0.0, 0.957, -0.28) if side == 0 else Vector3(0.0, 0.93, -0.78))
		elif target == null and sit:
			target = Vector3(0.16 * sgn, pelvis.y + 0.12, -0.30)  # hands on the thighs
		elif target == null and carry:
			target = Vector3(0.14 * sgn, 1.10, -0.40)
		if target != null:
			var shoulder := torso_origin + torso_g * (ORIGIN[ua] - ORIGIN[B.TORSO])
			var dirs := _reach(shoulder, target, Vector3(0.45 * sgn, -1.0, 0.25))
			var qu := Quaternion(Vector3.DOWN, dirs[0])
			var qf := Quaternion(Vector3.DOWN, dirs[1])
			_t_rot[ua] = torso_g.inverse() * qu
			_t_rot[ua + 1] = qu.inverse() * qf
		else:
			var swing := -0.5 * k * s * sgn
			_t_rot[ua] = Quaternion(Vector3.BACK, 0.10 * sgn) * Quaternion(Vector3.RIGHT, swing)
			_t_rot[ua + 1] = Quaternion(Vector3.RIGHT, 0.15 + 0.35 * k)


## CUE rig: fills `_cue_lean`, `_cue_crouch`, `_rig_hand` and `_rig_gap` for this frame's stick. The least trunk pitch from RIG_LEAN
## at which the rear hand holds the butt end under its shoulder and the bridge hand its spot wins; if none does by RIG_LEAN.y, the body
## bends no less than that and a hand that cannot reach its spot slides along the stick to the nearest point it can (the stick is the
## only thing the hands are bound to), bending on toward RIG_LEAN_MAX only while a hand still falls short.
func _solve_rig() -> void:
	var inv := global_transform.affine_inverse()
	var tip := inv * _rig_tip
	var butt := (inv.basis * _rig_butt).normalized()
	var best := INF
	var at := RIG_LEAN_MAX
	var lean := RIG_LEAN.x
	while lean <= RIG_LEAN_MAX + 0.0001:
		var crouch := clampf((lean - RIG_LEAN.x) / (RIG_LEAN_MAX - RIG_LEAN.x), 0.0, 1.0)
		var gap := 0.0
		var exact := true
		for side in 2:
			var shoulder := _rig_shoulder(side, lean, crouch)
			var hold := _hold(tip, butt, shoulder, _rig_pref(side, tip, butt, shoulder))
			gap += hold.y
			exact = exact and hold.z > 0.5
		if exact and lean <= RIG_LEAN.y + 0.0001:
			at = lean
			break
		if lean >= RIG_LEAN.y - 0.0001 and gap < best - 0.0005:
			best = gap
			at = lean
		lean += RIG_STEP
	_cue_lean = at
	_cue_crouch = clampf((at - RIG_LEAN.x) / (RIG_LEAN_MAX - RIG_LEAN.x), 0.0, 1.0)
	for side in 2:
		var shoulder := _rig_shoulder(side, _cue_lean, _cue_crouch)
		var hold := _hold(tip, butt, shoulder, _rig_pref(side, tip, butt, shoulder))
		_rig_hand[side] = tip + butt * hold.x
		_rig_gap[side] = hold.y


## The shoulder (0 right, 1 left) with the trunk pitched `lean` and the knees crouched `crouch` (0..1), this node's space: the chain
## `_compute_pose` builds, without breath and sway (a few mm).
func _rig_shoulder(side: int, lean: float, crouch: float) -> Vector3:
	var bend := CROUCH_KNEE * crouch
	var ext_r := THIGH * cos(CUE_THIGH.x) + SHIN * cos(CUE_THIGH.x - (CUE_KNEE.x + bend)) + ANKLE
	var ext_l := THIGH * cos(CUE_THIGH.y) + SHIN * cos(CUE_THIGH.y - (CUE_KNEE.y + bend)) + ANKLE
	var torso := Vector3(-RIG_SHIFT, maxf(ext_r, ext_l), 0.0) + ORIGIN[B.TORSO] - ORIGIN[B.PELVIS]
	var ua := B.UARM_R if side == 0 else B.UARM_L
	return torso + Quaternion(Vector3.RIGHT, -lean) * (ORIGIN[ua] - ORIGIN[B.TORSO])


## Where along the stick (distance from the tip) a hand would like to be: the rear hand under its shoulder inside the grip zone, the
## bridge hand at the bridge.
func _rig_pref(side: int, tip: Vector3, butt: Vector3, shoulder: Vector3) -> float:
	if side == 1:
		return _rig_bridge
	return clampf((shoulder - tip).dot(butt), _rig_len - GRIP_FROM_BUTT_M.y, _rig_len - GRIP_FROM_BUTT_M.x)


## Where a hand on the stick (tip + butt * s) can be with the shoulder fixed: x = s, y = metres the arm still falls short, z = 1 when s is
## the wanted `pref`. The wanted spot if the arm reaches it (between RIG_NEAR_M and RIG_REACH from the shoulder), else the nearest point
## of the stick it does.
func _hold(tip: Vector3, butt: Vector3, shoulder: Vector3, pref: float) -> Vector3:
	var lo := HAND_MIN_M
	var hi := _rig_len - 0.05
	var w := tip - shoulder
	var b := w.dot(butt)
	var disc := b * b - (w.length_squared() - RIG_REACH * RIG_REACH)
	if disc >= 0.0:
		var r := sqrt(disc)
		var a := maxf(-b - r, lo)
		var c := minf(-b + r, hi)
		if a <= c:
			var s := clampf(pref, a, c)
			var in_near := b * b - (w.length_squared() - RIG_NEAR_M * RIG_NEAR_M)
			if in_near > 0.0:  # the stick passes within RIG_NEAR_M of the shoulder: slide out of that stretch, the nearer way
				var n1 := -b - sqrt(in_near)
				var n2 := -b + sqrt(in_near)
				if s > n1 and s < n2:
					if n2 <= c and (n1 < a or n2 - s <= s - n1):
						s = n2
					elif n1 >= a:
						s = n1
			return Vector3(s, 0.0, 1.0 if is_equal_approx(s, pref) else 0.0)
	var closest := clampf(-b, lo, hi)
	return Vector3(closest, maxf((tip + butt * closest - shoulder).length() - RIG_REACH, 0.0), 0.0)


## Two-bone IK in this node's space: unit directions for the upper arm and forearm.
func _reach(shoulder: Vector3, target: Vector3, pole: Vector3) -> PackedVector3Array:
	var d := target - shoulder
	var dist := clampf(d.length(), 0.08, UPPER + FORE - 0.005)
	var dir := d.normalized() if d.length() > 0.0001 else Vector3.DOWN
	var cos_a := (UPPER * UPPER + dist * dist - FORE * FORE) / (2.0 * UPPER * dist)
	var a := acos(clampf(cos_a, -1.0, 1.0))
	var side := pole - dir * pole.dot(dir)
	side = side.normalized() if side.length() > 0.0001 else Vector3.RIGHT
	var upper := dir * cos(a) + side * sin(a)
	var elbow := shoulder + upper * UPPER
	var fore := (shoulder + dir * dist - elbow).normalized()
	return PackedVector3Array([upper, fore])


## Pushes the smoothed pose to the skeleton; `w` < 1 blends from the lying pose captured at get_up().
func _write_pose(w: float) -> void:
	var t := smoothstep(0.0, 1.0, w)
	for i in NAMES.size():
		var pos := ORIGIN[i] - (ORIGIN[PARENT[i]] if PARENT[i] >= 0 else Vector3.ZERO)
		var rot := _rot[i]
		if i == B.PELVIS:
			pos = _pelvis_pos
		if w < 1.0:
			var from := _snap_local(i)
			rot = from.basis.get_rotation_quaternion().slerp(rot, t)
			if i == B.PELVIS:
				pos = from.origin.lerp(pos, t)
		_skel.set_bone_pose_position(i, pos)
		_skel.set_bone_pose_rotation(i, rot)


## The lying pose of bone `i` relative to its parent (the pelvis: relative to the skeleton), from the world snapshot.
func _snap_local(i: int) -> Transform3D:
	if PARENT[i] < 0:
		return _skel.global_transform.affine_inverse() * _snap[i]
	return _snap[PARENT[i]].affine_inverse() * _snap[i]


# --- skeleton and physical bones ---------------------------------------------------------------------

func _build_skeleton() -> void:
	_skel = Skeleton3D.new()
	_skel.name = "Skeleton"
	for i in NAMES.size():
		_skel.add_bone(NAMES[i])
		_skel.set_bone_parent(i, PARENT[i])
	for i in NAMES.size():
		_skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, ORIGIN[i] - (ORIGIN[PARENT[i]] if PARENT[i] >= 0 else Vector3.ZERO)))
	_skel.reset_bone_poses()
	_skel.animate_physical_bones = false  # idle bones are not driven by the animation
	_sim = PhysicalBoneSimulator3D.new()
	_skel.add_child(_sim)
	for i in NAMES.size():
		var pb := _make_pb(i)
		_pbs.append(pb)
		_sim.add_child(pb)
	_body_mi = MeshInstance3D.new()
	_head_mi = MeshInstance3D.new()
	for mi in [_body_mi, _head_mi]:
		mi.material_override = _shared_material()
		mi.layers = 1 | MIRROR_LAYER
		mi.extra_cull_margin = 2.0
		_skel.add_child(mi)
		mi.skeleton = NodePath("..")  # unset by default when built in code
	add_child(_skel)


func _make_pb(i: int) -> PhysicalBone3D:
	var seg: Array = SEG[i]
	var centre: Vector3 = seg[0]
	var pb := PhysicalBone3D.new()
	pb.name = NAMES[i]
	pb.bone_name = NAMES[i]
	pb.mass = seg[5]
	pb.friction = 0.9
	pb.linear_damp = 0.15
	pb.angular_damp = 2.0
	pb.collision_layer = 0  # idle: no layer, no mask (ragdoll() sets them for the limp)
	pb.collision_mask = 0
	pb.body_offset = Transform3D(Basis.IDENTITY, centre - ORIGIN[i])
	var shape: Shape3D
	match int(seg[1]):
		0:
			var box := BoxShape3D.new()
			box.size = Vector3(seg[2], seg[3], seg[4])
			shape = box
		1:
			var cap := CapsuleShape3D.new()
			cap.radius = seg[2]
			cap.height = seg[3]
			shape = cap
		_:
			var sph := SphereShape3D.new()
			sph.radius = seg[2]
			shape = sph
	var cs := CollisionShape3D.new()
	cs.shape = shape
	pb.add_child(cs)
	_set_joint(pb, i, centre)
	return pb


## Joint frames sit on the bone origin. Cone joints twist about their X axis, so X is aligned with the limb;
## the hinge turns about Z, so Z is aligned with world X (elbows and knees flex about the body's X axis).
func _set_joint(pb: PhysicalBone3D, i: int, centre: Vector3) -> void:
	if PARENT[i] < 0:
		return
	var down := Basis(Vector3.DOWN, Vector3.RIGHT, Vector3.BACK)
	var up := Basis(Vector3.UP, Vector3.LEFT, Vector3.BACK)
	var at := ORIGIN[i] - centre
	match i:
		B.TORSO:
			_cone(pb, up, at, 25.0, 20.0)
		B.HEAD:
			_cone(pb, up, at, 45.0, 40.0)
		B.UARM_R, B.UARM_L:
			_cone(pb, down, at, 100.0, 45.0)
		B.THIGH_R, B.THIGH_L:
			_cone(pb, down, at, 70.0, 25.0)
		B.LARM_R, B.LARM_L:
			_hinge(pb, at, -0.05, 2.4)   # forearm folds forward
		_:
			_hinge(pb, at, -2.3, 0.05)   # shin folds backward


func _cone(pb: PhysicalBone3D, basis: Basis, at: Vector3, swing_deg: float, twist_deg: float) -> void:
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
	pb.joint_offset = Transform3D(basis, at)
	pb.set("joint_constraints/swing_span", deg_to_rad(swing_deg))
	pb.set("joint_constraints/twist_span", deg_to_rad(twist_deg))


func _hinge(pb: PhysicalBone3D, at: Vector3, lower: float, upper: float) -> void:
	pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
	pb.joint_offset = Transform3D(Basis(Vector3.UP, PI / 2.0), at)
	pb.set("joint_constraints/angular_limit_enabled", true)
	pb.set("joint_constraints/angular_limit_lower", lower)
	pb.set("joint_constraints/angular_limit_upper", upper)


# --- mesh --------------------------------------------------------------------------------------------

static func _shared_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = preload("res://src/shaders/humanoid.gdshader")
	return _material


func _new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## The whole character: body surface (trunk with its lid, shoulders, arms, legs, feet) and head surface (head, face, hat,
## neck). The local camera culls the head surface only; it sits inside the neck, so the lid closes the trunk (no looking
## through to the legs) and the arms hang beside it.
func _paint(body: SurfaceTool, head: SurfaceTool, skin: CharacterSkin) -> void:
	var shirt := skin.body_color
	var legs := skin.accent_color
	var flesh := skin.skin_color
	var shoe := legs.darkened(0.55)
	_cyl(body, B.PELVIS, legs, Vector3(0, 0.86, 0), 0.17, Vector2(0.155, 0.10), Vector2(0.155, 0.10), 8, CAP_BOTTOM)
	_cyl(body, B.TORSO, shirt, Vector3(0, 1.03, 0), 0.47, Vector2(0.15, 0.092), Vector2(0.205, 0.11), 8, CAP_TOP)
	_cyl(head, B.TORSO, flesh, Vector3(0, 1.49, 0), 0.08, Vector2(0.045, 0.045), Vector2(0.04, 0.04), 6)
	for side in 2:
		var sx := 0.22 if side == 0 else -0.22
		var ua := B.UARM_R if side == 0 else B.UARM_L
		var th := B.THIGH_R if side == 0 else B.THIGH_L
		var lx := 0.10 if side == 0 else -0.10
		_cyl(body, ua, shirt, Vector3(sx, 1.13, 0), 0.32, Vector2(0.040, 0.040), Vector2(0.052, 0.052), 6)
		_ball(body, ua, shirt, Vector3(sx, 1.43, 0), Vector3(0.058, 0.058, 0.058), 6, 4)
		_cyl(body, ua + 1, flesh, Vector3(sx, 0.86, 0), 0.27, Vector2(0.033, 0.033), Vector2(0.041, 0.041), 6)
		_ball(body, ua + 1, flesh, Vector3(sx, 0.835, 0), Vector3(0.048, 0.052, 0.048), 6, 4)
		_cyl(body, th, legs, Vector3(lx, 0.50, 0), 0.43, Vector2(0.056, 0.056), Vector2(0.074, 0.074), 6)
		_cyl(body, th + 1, legs, Vector3(lx, 0.08, 0), 0.42, Vector2(0.042, 0.042), Vector2(0.056, 0.056), 6)
		_box(body, th + 1, shoe, Vector3(lx, 0.04, -0.05), Vector3(0.052, 0.04, 0.12))
	if _quirk == QUIRK_BARKEEP:
		_paint_barkeep(body, head, skin)
	else:
		_paint_head(head, skin)


func _paint_head(head: SurfaceTool, skin: CharacterSkin) -> void:
	var shirt := skin.body_color
	var legs := skin.accent_color
	var flesh := skin.skin_color
	_ball(head, B.HEAD, flesh, Vector3(0, 1.60, 0), Vector3(0.10, 0.12, 0.11), 8, 6)
	var dark := Color(0.08, 0.07, 0.07)
	_box(head, B.HEAD, dark, Vector3(0.04, 1.615, -0.099), Vector3(0.011, 0.014, 0.008))
	_box(head, B.HEAD, dark, Vector3(-0.04, 1.615, -0.099), Vector3(0.011, 0.014, 0.008))
	_box(head, B.HEAD, flesh.darkened(0.12), Vector3(0, 1.59, -0.112), Vector3(0.013, 0.016, 0.014))
	match skin.hat:
		&"cap":
			_ball(head, B.HEAD, legs, Vector3(0, 1.655, 0), Vector3(0.118, 0.075, 0.124), 8, 4)
			_box(head, B.HEAD, legs, Vector3(0, 1.665, -0.135), Vector3(0.085, 0.008, 0.06))
		&"tophat":
			var black := Color(0.07, 0.07, 0.09)
			_cyl(head, B.HEAD, black, Vector3(0, 1.695, 0), 0.012, Vector2(0.17, 0.17), Vector2(0.17, 0.17), 8)
			_cyl(head, B.HEAD, black, Vector3(0, 1.705, 0), 0.15, Vector2(0.092, 0.092), Vector2(0.088, 0.088), 8)
			_cyl(head, B.HEAD, shirt, Vector3(0, 1.707, 0), 0.03, Vector2(0.095, 0.095), Vector2(0.095, 0.095), 8)
		&"beanie":
			_ball(head, B.HEAD, shirt.lightened(0.15), Vector3(0, 1.625, 0), Vector3(0.123, 0.115, 0.13), 8, 5)
			_ball(head, B.HEAD, shirt.lightened(0.45), Vector3(0, 1.745, 0), Vector3(0.03, 0.03, 0.03), 6, 4)
		&"crown":
			_cyl(head, B.HEAD, GOLD, Vector3(0, 1.68, 0), 0.05, Vector2(0.115, 0.118), Vector2(0.115, 0.118), 8)
			for n in 5:
				var a := TAU * n / 5.0
				_cyl(head, B.HEAD, GOLD, Vector3(sin(a) * 0.095, 1.73, cos(a) * 0.095), 0.07, Vector2(0.026, 0.026), Vector2(0.0, 0.0), 4)


## The Bartender's look (06 P24): an oversized head with bulging eyes, a red nose, a handlebar mustache and a very tall
## striped hat, a bow tie and gold sleeve garters. The same bones as everyone; only the surfaces differ.
func _paint_barkeep(body: SurfaceTool, head: SurfaceTool, skin: CharacterSkin) -> void:
	var flesh := skin.skin_color
	var nose := flesh.lerp(Color(0.85, 0.25, 0.2), 0.45)
	var stache := Color(0.42, 0.2, 0.07)
	var white := Color(0.96, 0.96, 0.92)
	var dark := Color(0.08, 0.07, 0.07)
	var plum := Color(0.32, 0.1, 0.42)
	var red := Color(0.75, 0.1, 0.12)
	var cy := 1.62  # head centre
	if _face == null:  # with a real face on the head bone (set_face) none of this is painted
		_ball(head, B.HEAD, flesh, Vector3(0, cy, 0), Vector3(0.135, 0.16, 0.145), 10, 7)
		for sx in [-1.0, 1.0]:
			_ball(head, B.HEAD, white, Vector3(0.055 * sx, cy + 0.04, -0.125), Vector3(0.036, 0.04, 0.03), 6, 4)
			_ball(head, B.HEAD, dark, Vector3(0.05 * sx, cy + 0.04, -0.153), Vector3(0.014, 0.016, 0.01), 5, 3)
			_box(head, B.HEAD, stache, Vector3(0.06 * sx, cy + 0.10, -0.12), Vector3(0.05, 0.012, 0.014))
			for lump: Array in [[0.035, 0.0], [0.08, -0.008], [0.125, 0.0], [0.16, 0.03], [0.185, 0.065]]:  # the bar sags, then curls up
				_ball(head, B.HEAD, stache, Vector3(lump[0] * sx, cy - 0.075 + lump[1], -0.135), Vector3(0.032, 0.02, 0.02), 6, 4)
		_ball(head, B.HEAD, nose, Vector3(0, cy - 0.02, -0.155), Vector3(0.036, 0.034, 0.04), 6, 4)
	var hat_y := cy + 0.14
	_cyl(head, B.HEAD, plum, Vector3(0, hat_y, 0), 0.014, Vector2(0.2, 0.2), Vector2(0.2, 0.2), 10)
	for i in 5:
		var top := i == 4
		_cyl(head, B.HEAD, plum if i % 2 == 0 else GOLD, Vector3(0, hat_y + 0.014 + 0.085 * i, 0), 0.085, Vector2(0.105, 0.105), Vector2(0.105, 0.105), 10, CAP_TOP if top else 0)
	_box(body, B.TORSO, red, Vector3(0.075, 1.465, -0.105), Vector3(0.065, 0.032, 0.018))
	_box(body, B.TORSO, red, Vector3(-0.075, 1.465, -0.105), Vector3(0.065, 0.032, 0.018))
	_ball(body, B.TORSO, GOLD, Vector3(0, 1.465, -0.108), Vector3(0.026, 0.026, 0.026), 6, 4)
	for side in 2:
		_cyl(body, B.UARM_R if side == 0 else B.UARM_L, GOLD, Vector3(0.22 if side == 0 else -0.22, 1.27, 0), 0.03, Vector2(0.056, 0.056), Vector2(0.056, 0.056), 6)


## Vertical frustum from `base` up by `h`, elliptical radii (x, z) at the bottom and top, closed with fans.
func _cyl(st: SurfaceTool, bone: int, col: Color, base: Vector3, h: float, r0: Vector2, r1: Vector2, sides: int, caps := CAP_BOTTOM | CAP_TOP) -> void:
	var bottom: Array[Vector3] = []
	var top: Array[Vector3] = []
	for n in sides:
		var a := TAU * n / sides
		bottom.append(base + Vector3(cos(a) * r0.x, 0.0, sin(a) * r0.y))
		top.append(base + Vector3(cos(a) * r1.x, h, sin(a) * r1.y))
	var hub0 := base
	var hub1 := base + Vector3(0.0, h, 0.0)
	var centre := base + Vector3(0.0, h * 0.5, 0.0)
	for n in sides:
		var m := (n + 1) % sides
		if h > 0.01:
			_quad(st, bone, col, bottom[n], bottom[m], top[m], top[n], centre)
		if caps & CAP_BOTTOM:
			_tri(st, bone, col, [hub0, bottom[m], bottom[n]], [Vector3.DOWN, Vector3.DOWN, Vector3.DOWN])
		if caps & CAP_TOP and r1.x > 0.0:
			_tri(st, bone, col, [hub1, top[n], top[m]], [Vector3.UP, Vector3.UP, Vector3.UP])


func _box(st: SurfaceTool, bone: int, col: Color, centre: Vector3, half: Vector3) -> void:
	var c: Array[Vector3] = []
	for n in 8:
		c.append(centre + Vector3(half.x if n & 1 else -half.x, half.y if n & 2 else -half.y, half.z if n & 4 else -half.z))
	for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		_quad(st, bone, col, c[f[0]], c[f[1]], c[f[2]], c[f[3]], centre)


## Ellipsoid, smooth normals.
func _ball(st: SurfaceTool, bone: int, col: Color, centre: Vector3, radii: Vector3, seg: int, rings: int) -> void:
	var grid: Array = []
	for r in rings + 1:
		var row: Array[Vector3] = []
		var phi := PI * r / rings
		for s in seg:
			var th := TAU * s / seg
			row.append(Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th)))
		grid.append(row)
	for r in rings:
		for s in seg:
			var s2 := (s + 1) % seg
			var q: Array[Vector3] = [grid[r][s], grid[r][s2], grid[r + 1][s2], grid[r + 1][s]]
			var p: Array[Vector3] = []
			for v in q:
				p.append(centre + v * radii)
			if r > 0:
				_tri(st, bone, col, [p[0], p[1], p[2]], [q[0], q[1], q[2]])
			if r < rings - 1:
				_tri(st, bone, col, [p[0], p[2], p[3]], [q[0], q[2], q[3]])


func _quad(st: SurfaceTool, bone: int, col: Color, a: Vector3, b: Vector3, c: Vector3, d: Vector3, inside: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length() < 0.000001:
		n = (c - a).cross(d - a)
	n = n.normalized()
	if n.dot((a + b + c + d) * 0.25 - inside) < 0.0:
		n = -n
	_tri(st, bone, col, [a, b, c], [n, n, n])
	_tri(st, bone, col, [a, c, d], [n, n, n])


## One triangle, wound clockwise seen from outside (Godot's front face) whatever order it was given in.
func _tri(st: SurfaceTool, bone: int, col: Color, p: Array, n: Array) -> void:
	var cross: Vector3 = (p[1] - p[0]).cross(p[2] - p[0])
	if cross.length() < 0.0000001:
		return
	var order := [0, 2, 1] if cross.dot(n[0] + n[1] + n[2]) > 0.0 else [0, 1, 2]
	for k: int in order:
		st.set_color(col)
		st.set_normal(n[k])
		st.set_bones(PackedInt32Array([bone, 0, 0, 0]))
		st.set_weights(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
		st.add_vertex(p[k])
