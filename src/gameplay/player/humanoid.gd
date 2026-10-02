class_name Humanoid
extends Node3D
## Low-poly person built in code (06 P15, 08 §2.7): 11 bones, one vertex-coloured material, two skinned
## meshes (body; head + hat) = 2 draw calls. Animated procedurally (breath, walk from measured speed, CUE and
## CARRY stances, hand targets). `ragdoll()` hands the bones to a PhysicalBoneSimulator3D; its 11 bodies are
## static on layer 0 (not simulated, not in the broad phase) until then, and `get_up()` blends back to the pose.
## Rests facing -Z with the feet at this node's origin, like the CharacterBody3D it hangs from.

signal got_up  ## simulation stopped (the blend back to the pose starts); `pelvis_at_getup` is where the body lay

enum Stance { STAND, CUE, CARRY }  ## same order as Player.Mode
enum B { PELVIS, TORSO, HEAD, UARM_R, LARM_R, UARM_L, LARM_L, THIGH_R, SHIN_R, THIGH_L, SHIN_L }

const HEAD_LAYER := 1 << 19    ## render layer 20: the local player's camera culls it, shadows still fall
const RAG_LAYER := 1 << 4      ## collision layer 5 `ragdoll` (07 §1): bones never touch each other or balls
const RAG_MASK := 2 | 8        ## table rails + world (floor, walls, bar)
const BLEND_SEC := 0.4
const WALK_MPS := 3.5
const STRIDE_RAD_PER_M := 4.5  ## gait phase per metre walked
const SMOOTH := 18.0           ## pose smoothing rate (1/s)
const GOLD := Color("e8b923")

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
const UPPER := 0.30     ## shoulder → elbow
const FORE := 0.295     ## elbow → hand centre
const THIGH := 0.43
const SHIN := 0.42
const ANKLE := 0.08

static var _material: StandardMaterial3D  ## every Humanoid shares it: colours live in the vertices

var stance := Stance.STAND
var pelvis_at_getup := Vector3.ZERO

var _skin: CharacterSkin
var _skel: Skeleton3D
var _sim: PhysicalBoneSimulator3D
var _pbs: Array[PhysicalBone3D] = []
var _body_mi: MeshInstance3D
var _head_mi: MeshInstance3D
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
var _rot: Array[Quaternion] = []
var _pelvis_pos := ORIGIN[0]
var _t_rot: Array[Quaternion] = []
var _t_pelvis := ORIGIN[0]


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


## Local player: the head and hat leave the camera's cull mask (the Player removes HEAD_LAYER from it) but keep casting shadows.
func set_first_person(on: bool) -> void:
	_first_person = on
	_head_mi.layers = HEAD_LAYER if on else 1


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


## Limp: the bones are handed to physics. `impulse` is a velocity change (m/s) every bone gets, on top of the
## speed the body was walking at.
func ragdoll(impulse: Vector3) -> void:
	if not _ragdoll:
		_ragdoll = true
		_blend = 1.0
		_skel.force_update_all_bone_transforms()
		_set_layers(RAG_LAYER, RAG_MASK)
		_sim.physical_bones_start_simulation()
		impulse += _vel
	for pb in _pbs:
		pb.linear_velocity += impulse
		pb.angular_velocity += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * impulse.length() * 0.4


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
	if v.length() > 9.0:  # a teleport (CUE pin, respawn), not walking
		v = Vector3.ZERO
	_vel = v
	_speed = lerpf(_speed, Vector2(v.x, v.z).length(), 1.0 - exp(-10.0 * delta))


func _process(delta: float) -> void:
	if _ragdoll:
		return
	_time += delta
	_phase += _speed * delta * STRIDE_RAD_PER_M
	_compute_pose()
	var a := 1.0 - exp(-SMOOTH * delta)
	for i in _rot.size():
		_rot[i] = _rot[i].slerp(_t_rot[i], a)
	_pelvis_pos = _pelvis_pos.lerp(_t_pelvis, a)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / BLEND_SEC)
	_write_pose(_blend)


## Fills _t_rot / _t_pelvis: where every bone wants to be this frame, before smoothing.
func _compute_pose() -> void:
	var k := clampf(_speed / WALK_MPS, 0.0, 1.3)
	var s := sin(_phase)
	var c := cos(_phase)
	var cue := stance == Stance.CUE
	var carry := stance == Stance.CARRY
	var reaching := _hand[0] != null or _hand[1] != null
	var th_r := 0.0
	var th_l := 0.0
	var fl_r := 0.05
	var fl_l := 0.05
	if cue:  # bridge leg forward and bent, back leg long
		th_r = -0.30
		fl_r = 0.08
		th_l = 0.42
		fl_l = 0.45
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
	var pelvis := Vector3(sway + 0.012 * k * s, maxf(ext_r, ext_l) + 0.003 * breath, 0.0)
	var lean := 0.0
	if cue:
		lean = 0.65
		pelvis.x -= 0.2  # stands left of the cue line so the stick passes the right shoulder
	elif carry:
		lean = 0.08
	elif reaching:
		lean = 0.22
	var pelvis_rot := Quaternion(Vector3.UP, 0.07 * k * s)
	var torso_rot := Quaternion(Vector3.RIGHT, -lean + 0.014 * breath) * Quaternion(Vector3.UP, -0.1 * k * s)
	_t_pelvis = pelvis
	_t_rot[B.PELVIS] = pelvis_rot
	_t_rot[B.TORSO] = torso_rot
	_t_rot[B.HEAD] = Quaternion(Vector3.UP, _look.x) * Quaternion(Vector3.RIGHT, _look.y + lean * 0.9)
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
			target = Vector3(0.0, 0.957, -0.28) if side == 0 else Vector3(0.0, 0.93, -0.78)
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

static func _shared_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.roughness = 0.85
	return _material


func _new_st() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## The whole character: body surface (torso, limbs, feet) and head surface (head, face, hat).
func _paint(body: SurfaceTool, head: SurfaceTool, skin: CharacterSkin) -> void:
	var shirt := skin.body_color
	var legs := skin.accent_color
	var flesh := skin.skin_color
	var shoe := legs.darkened(0.55)
	_cyl(body, B.PELVIS, legs, Vector3(0, 0.86, 0), 0.17, Vector2(0.155, 0.10), Vector2(0.155, 0.10), 8)
	_cyl(body, B.TORSO, shirt, Vector3(0, 1.03, 0), 0.47, Vector2(0.15, 0.092), Vector2(0.205, 0.11), 8)
	_cyl(body, B.TORSO, flesh, Vector3(0, 1.49, 0), 0.08, Vector2(0.045, 0.045), Vector2(0.04, 0.04), 6)
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


## Vertical frustum from `base` up by `h`, elliptical radii (x, z) at the bottom and top, closed with fans.
func _cyl(st: SurfaceTool, bone: int, col: Color, base: Vector3, h: float, r0: Vector2, r1: Vector2, sides: int) -> void:
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
		_quad(st, bone, col, bottom[n], bottom[m], top[m], top[n], centre)
		_tri(st, bone, col, [hub0, bottom[m], bottom[n]], [Vector3.DOWN, Vector3.DOWN, Vector3.DOWN])
		if r1.x > 0.0:
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
