class_name Player
extends CharacterBody3D
## First-person walker with four modes (08 §2.2): WALK, CUE (aim and strike), CARRY (holding a camera rig),
## RAGDOLL (knocked limp for a few seconds, 06 P15); WALK has a seated sub-state (06 P33 U7). Yaw rotates the body, pitch
## rotates Head only — keeping them split is what stops the capsule tipping over. Every Player wears a `Humanoid`; the
## local one hides its head from its own camera, and in CUE its whole body (the mirror still draws it: `pose_body`). Local player:
## bound to the level once (`bind`), reads keys and TouchControls. Puppet: a remote peer's avatar, fed by `apply_pose` and
## interpolated 100 ms behind (04 push_player_pose).

enum Mode { WALK, CUE, CARRY, RAGDOLL }

signal mode_changed(mode: Mode)
signal got_up  ## a knock ended: input is back, the body stands at the pelvis

const POSE_BYTES := 16
const PITCH_MAX := 0x1FFF            # pose tail: mode << 14 | seated << 13 | pitch (13 bit)
const SEATED_BIT := 0x2000
const INTERP_DELAY_MSEC := 100
const PITCH_LIMIT := deg_to_rad(89.0)
const EYE_M := 1.6
const REACH_M := 2.0                 # same number WorldInteractions validates
const PLACE_AHEAD_M := 1.5
const BAR_KINDS: Array[StringName] = [&"bar_buy", &"bar_serve", &"throw_drink"]  # one counter, one menu
const KNOCK_SEC := 2.0
const TAG_Y := 2.05                  # name tag height, above a top hat
const HARD_LAND_MPS := 7.0           # [tune] fall speed that knocks you over on landing
const LIMP_GRACE_MSEC := 3000        # a puppet waits this long past its timer for the owner to stand
const EYE_AHEAD_M := 0.12            # eye pivot ahead of the trunk's axis, standing
const EYE_LEAN_M := 0.16             # ... and this much further when looking steeply down (stays inside the capsule, r 0.3)
const EYE_DROP_M := 0.05             # ... a little lower too
const EYE_LEAN_DEG := Vector2(50.0, 89.0)  # look-down angles where the head starts to come forward / is fully forward
const SNAP_STEP_M := 0.1             # post-shot spot search: backing away along the shot line, then rings around it
const SNAP_MAX_M := 3.0
const SNAP_LIFT_M := 0.06            # the query capsule floats clear of the floor box
const FACE_CONE_RAD := deg_to_rad(40.0)  # a prompt needs the camera yaw within this of the prop (flattened XZ) ...
const FACE_NEAR_M := 0.6             # ... unless the prop is this close (06 P33 U8)
const FACE_TIE_RAD := 0.02           # angles this close tie, and the nearer prop wins
const SIT_STAND_INPUT := 0.3         # stick / key push that gets a seated player up
const SHOOT_POLL_SEC := 0.1          # how often the Shoot button re-reads can-strike

@export var speed := 3.5             # [tune]
@export var jump_velocity := 4.5
@export var mouse_sensitivity := 0.0025
@export var touch_look_deg_per_px := 0.20  # [tune]

var mode := Mode.WALK
var is_local := false
var prompt := ""
var seated := false                  # WALK sub-state (06 P33 U7): on a stool or sofa, camera lowered, body in the SIT stance

var _rd: Node                        # RoundDirector
var _loop: GameLoop
var _sim: PhysicsSim
var _world: WorldInteractions
var _bartender: BartenderMenu
var _cameras: CameraRigs
var _net: Node
var _host_away := false
var _controls: TouchControls
var _target: Interactable
var _seat: Interactable              # the seat I am on
var _sit_from := Vector3.ZERO        # where I stood before sitting: where I get up
var _eye_m := EYE_M                  # eye height now: eases between standing and seated
var _shoot_poll := 0.0
var _held_rig := 0                   # CameraRig number while CARRY (derived from the mirrored holders)
var _placing := false
var _clock_end_msec := 0             # local end of the host's shot clock; 0 = none
var _jump_queued := false
var _saved_pos := Vector3.ZERO
var _saved_yaw := 0.0
var _saved_pitch := 0.0
var _cue_pitch := 0.0
var _floor_y := 0.0
var _verdict_pending := false        # a shot left from the snapped spot and the host has not answered yet
var _refused_inline := false         # the host refused while fire() was still on the stack
var _shot_seen := false              # the host's `shot_started_net` reached us since CUE began (the host's own strike beats `fired`)
var _pose := PackedByteArray()
var _samples: Array[PackedFloat64Array] = []  # puppet: [msec, x, y, z, yaw, pitch, mode, seated]
var _puppet_mode := Mode.WALK
var _puppet_seated := false
var _table: Table                    # puppet: found once, for the CUE body's footprint (none: a default table's spec, no footprint)
var _fallback_spec: TableSpec
var _avatar_cue: MeshInstance3D
var _tag: Label3D
var humanoid: Humanoid  # every Player wears one; the local one hides its head from `cam`
var _getup_msec := 0                 # RAGDOLL: when the knock ends (local clock)
var _cam_from := Transform3D.IDENTITY
var _cam_blend := 1.0                # < 1: the camera is settling from the head bone back onto Head
var _airborne := false

@onready var head: Node3D = $Head
@onready var cam: Camera3D = $Head/headCam
@onready var cue: CueController = $Head/CueController
@onready var _probe: ShapeCast3D = $InteractProbe
@onready var _body: CollisionShape3D = $Body


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # camera is driven from _process
	_pose.resize(POSE_BYTES)
	humanoid = Humanoid.new()
	humanoid.name = "Humanoid"
	add_child(humanoid)
	humanoid.apply_skin(SkinCatalog.default_character(0))
	add_to_group(&"players")
	set_physics_process(false)
	set_process(false)
	set_process_unhandled_input(false)


## One-time wiring of the local player to the level (contract §3 names). Never called on puppets.
func bind(level: Node) -> void:
	is_local = true
	cam.make_current()  # claim the view: the first Camera3D in tree (Debug's freecam) is current otherwise
	cam.cull_mask &= ~Humanoid.HEAD_LAYER  # neck down only: the head and hat stay (they still cast shadows)
	humanoid.set_first_person(true)
	var table: Table = level.get_node("Table")
	_rd = level.get_node("RoundDirector")
	_sim = table.sim
	_world = level.get_node_or_null("WorldInteractions")
	_loop = level.get_node_or_null("GameLoop") as GameLoop
	_bartender = level.get_node_or_null("UILayer/BartenderMenu")
	_cameras = level.get_node_or_null("Cameras")
	_controls = level.get_node_or_null("UILayer/TouchControls")
	cue.table = table
	cue.effects = level.get_node_or_null("EffectManager")
	cue.controls = _controls
	cue.player = self
	add_to_group(Settings.GROUP)
	_on_settings_changed()
	cue.fired.connect(_on_fired)
	_sim.shot_rejected.connect(_on_shot_rejected)
	_sim.shot_started_net.connect(func(_id: int, _shooter: int, _tick: int) -> void:
		_shot_seen = true
		_verdict_pending = false)
	_rd.shooter_changed.connect(_on_shooter_changed)
	_rd.staging_changed.connect(_on_staging_changed)
	_rd.shot_clock_started.connect(func(seconds: float) -> void: _clock_end_msec = Time.get_ticks_msec() + int(seconds * 1000.0))
	_rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], _f: bool) -> void: _clock_end_msec = 0)
	_sim.shot_rejected.connect(func(reason: StringName) -> void: _toast(WaitText.shot(reason, _shooter_name(), _sim.awake)))
	if _world != null:
		_world.interaction_rejected.connect(func(kind: StringName, reason: StringName) -> void: _toast(WaitText.interaction(kind, reason, _world.last_wait_sec)))
		_world.interaction_applied.connect(_on_interaction_applied)
	if _cameras != null:
		_cameras.holders_changed.connect(_sync_carry)
	if _bartender != null:
		_bartender.picked.connect(_on_picked)
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
	_net = get_tree().root.get_node(^"NetManager")
	_net.host_away_changed.connect(_on_host_away)
	if _loop != null:
		_loop.round_ended.connect(func(_r: StringName, _p: int) -> void: _clock_end_msec = 0)
		_loop.phase_changed.connect(_on_phase_changed)
	_on_host_away(_net.host_away)
	_sync_can_shoot()
	set_physics_process(true)
	set_process(true)
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if UIRouter.blocking():  # a modal owns the input (Esc is UIRouter's: it opens Pause)
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and mode != Mode.CUE:
			var k := mouse_sensitivity * float(Settings.value(&"mouse_sens"))
			look(-event.relative.x * k, -event.relative.y * k * _y_sign())
	elif event is InputEventMouseButton and event.pressed:
		if _controls == null or not _controls.touch:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(&"interact"):
		interact()
	elif event.is_action_pressed(&"cue_mode"):
		toggle_cue()


func _on_settings_changed() -> void:
	cam.fov = float(Settings.value(&"fov"))


func _y_sign() -> float:
	return -1.0 if Settings.value(&"invert_y") else 1.0


func look(yaw_rad: float, pitch_rad: float) -> void:
	if mode == Mode.RAGDOLL:
		return
	rotate_y(yaw_rad)
	head.rotation.x = clampf(head.rotation.x + pitch_rad, -PITCH_LIMIT, PITCH_LIMIT)


func _process(delta: float) -> void:
	if is_local:
		humanoid.set_look(0.0, head.rotation.x)
		_eye_m = move_toward(_eye_m, _eye_target(), 3.0 * delta)
		_lean_eye()
		_shoot_poll -= delta
		if _shoot_poll <= 0.0:
			_shoot_poll = SHOOT_POLL_SEC
			_sync_can_shoot()
		if mode == Mode.RAGDOLL:
			cam.global_transform = cam.global_transform.interpolate_with(humanoid.eye_transform(), 1.0 - exp(-25.0 * delta))
			if Time.get_ticks_msec() >= _getup_msec:
				_end_knock()
		elif _cam_blend < 1.0:
			_settle_cam(delta)
		if _controls != null and mode != Mode.CUE:
			_controls.set_clock(shot_clock_text())
			var d := _controls.look.consume()
			if d != Vector2.ZERO:
				var k := deg_to_rad(touch_look_deg_per_px)
				look(-d.x * k, -d.y * k)
	else:
		_puppet_step()


## Looking down the head comes forward over the chest (first-person body, C17): at the eye the trunk's top is 10 cm below
## the camera, so a pivot on the trunk's axis would fill the view with the shoulder line; ahead of the chest the view
## clears it and shows the chest sloping away, both arms hanging and the legs and shoes beyond.
func _lean_eye() -> void:
	var s := smoothstep(EYE_LEAN_DEG.x, EYE_LEAN_DEG.y, rad_to_deg(-head.rotation.x))
	head.position = Vector3(0.0, _eye_m - EYE_DROP_M * s, -(EYE_AHEAD_M + EYE_LEAN_M * s))


func _physics_process(delta: float) -> void:
	if mode == Mode.CUE or mode == Mode.RAGDOLL:
		return
	if seated:
		_sit_step()
		_scan()  # the counter's Bartender is still in reach from a stool
		return  # (also the frame one stands up: the capsule collides again from the next)
	if not is_on_floor():
		velocity += get_gravity() * delta
	if is_on_floor() and ((Input.is_action_just_pressed(&"jump") and not UIRouter.blocking()) or _jump_queued):
		velocity.y = jump_velocity
	_jump_queued = false
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	if UIRouter.blocking():
		input = Vector2.ZERO
	if _controls != null:
		input = (input + _controls.stick.value).limit_length(1.0)
	var direction := transform.basis * Vector3(input.x, 0.0, input.y)
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	var fall := velocity.y
	move_and_slide()
	if _airborne and is_on_floor() and fall < -HARD_LAND_MPS:
		var shove := Vector3(direction.x * 2.0, 1.5, direction.z * 2.0)
		knock(shove, KNOCK_SEC)
		var slot := get_parent()
		if slot != null and slot.has_method(&"broadcast_knock"):  # the owner decides a fall: everyone else's puppet goes limp too
			slot.call(&"broadcast_knock", shove, KNOCK_SEC)
	_airborne = not is_on_floor()
	_scan()


# --- interact -------------------------------------------------------------------------------------

## The Interactable the player is using: within REACH_M and facing it (06 P33 U8), the smallest angle first, the nearer on a tie.
## The probe sphere is the broad phase; the reach test is the host's own (feet to prop origin), so a prompt never shows for a use the
## host would refuse. Facing is yaw only (flattened XZ, so looking down at a prop beside you still counts), measured from the camera
## to the prop; a prop within FACE_NEAR_M needs no facing. Hostile props (heckle, kick_stool, bump_table, throw_drink, flick_lights)
## are not offered when the host would refuse them anyway (06 P33 U6).
func _scan() -> void:
	var best: Interactable
	var best_angle := INF
	var best_d := INF
	var fwd := Vector2(-global_basis.z.x, -global_basis.z.z).normalized()
	var eye := Vector2(cam.global_position.x, cam.global_position.z)
	var hostile_ok := _hostile_ok()
	for i in _probe.get_collision_count():
		var it := _probe.get_collider(i) as Interactable
		if it == null:
			continue
		var rig := it.get_parent() as CameraRig
		if rig != null and rig.held_by != 0:  # someone is carrying it
			continue
		if it.interaction != null and it.interaction.hostile and not hostile_ok:
			continue
		if seated and it.effective_kind() == Interactable.SIT:
			continue
		var d := global_position.distance_to(it.global_position)
		if d > REACH_M:
			continue
		var to := Vector2(it.global_position.x, it.global_position.z) - eye
		var angle := absf(fwd.angle_to(to)) if to.length() > 0.001 else 0.0
		if angle > FACE_CONE_RAD and d > FACE_NEAR_M:
			continue
		if best == null or angle < best_angle - FACE_TIE_RAD or (absf(angle - best_angle) <= FACE_TIE_RAD and d < best_d):
			best = it
			best_angle = angle
			best_d = d
	_target = best
	var text := best.prompt if best != null else ("Stand up" if seated else "")
	if best != null and best.effective_kind() in BAR_KINDS:
		text = "Bartender"
	elif _bartender != null and _bartender.is_open():
		_bartender.close()  # walked away
	if mode == Mode.CARRY:
		text = "Place the camera"
	if text != prompt:
		prompt = text
		if _controls != null:
			_controls.set_prompt(text)


## Hostile prompts (06 P33 U6) show where the host would accept the move: a Round is live, nothing is staged and I am not the
## shooter. Every peer knows all three, so nothing here waits on the host; its other refusals (cap, cooldown, reach) still toast.
func _hostile_ok() -> bool:
	return _loop == null or (_loop.phase == GameLoop.Phase.ROUND_LIVE and not _staging() and _rd.current_shooter_id != multiplayer.get_unique_id())


## RoundDirector.staging: true while the table is being set up (the saucer beams the rack in) or cleared (the bed opens, the balls fall away),
## 06 P33 A4. Read by name so a RoundDirector stand-in without the flag simply never stages.
func _staging() -> bool:
	return _rd != null and _rd.get(&"staging") == true


func interact() -> void:
	if mode == Mode.CUE or mode == Mode.RAGDOLL or UIRouter.blocking():
		return
	if mode == Mode.CARRY:
		place_camera(false)
		return
	if _target == null:
		if seated:
			stand_up()
		return
	if _target.effective_kind() == Interactable.SIT:  # local, no host check
		sit_on(_target)
		return
	if _target.effective_kind() in BAR_KINDS:  # the Bartender: Drinks (serve / throw) and Upgrades
		if _bartender != null:
			_bartender.open()
		return
	if not _target.try_use({}):
		_toast(WaitText.cooling(_target.effective_kind(), _target.cooldown_left_sec()) if _target.cooldown_left_sec() > 0.0 else WaitText.interaction(&"", &"no_prop"))


func place_camera(at_feet: bool) -> void:
	if mode != Mode.CARRY or _world == null:
		return
	var fwd := -global_basis.z
	var spot := global_position + (Vector3.ZERO if at_feet else Vector3(fwd.x, 0.0, fwd.z).normalized() * PLACE_AHEAD_M)
	_placing = true
	_world.request(&"move_camera", _held_rig, {&"place_at": Vector3(spot.x, 0.0, spot.z)})


## The Bartender menu's Drink pick: the host validates reach, cooldown, Cash and the hostile caps (03 §3.4).
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


# --- sit (06 P33 U7) ------------------------------------------------------------------------------

## Sit on a stool or sofa: the player snaps to the seat's floor point and facing, the capsule stops colliding (the collision
## exception: a seated body is nobody's obstacle and the stool's own box is not in its way), the camera lowers, the body takes the SIT
## stance. Local; the pose stream carries the flag. Jump, a push on the stick, a knock, kick_stool, CUE or a phase change stand up.
func sit_on(seat: Interactable) -> void:
	if seated or mode != Mode.WALK or seat == null:
		return
	seated = true
	_seat = seat
	_sit_from = global_position
	velocity = Vector3.ZERO
	_body.set_deferred(&"disabled", true)
	global_position = seat.global_position
	rotation.y = seat.seat_yaw
	humanoid.set_seat(seat.seat_top)
	humanoid.stance = Humanoid.Stance.SIT
	if _bartender != null and _bartender.is_open():
		_bartender.close()


## Get up where I stood before sitting, else the nearest spot that fits (the same search a CUE strike uses).
func stand_up() -> void:
	if not seated:
		return
	_unseat()
	global_position = _free_spot(_sit_from, global_basis.z, _sit_from)
	velocity = Vector3.ZERO
	_airborne = false
	_body.set_deferred(&"disabled", false)


## Out of the seat without moving the player (a knock takes the body from where it sits).
func _unseat() -> void:
	seated = false
	_seat = null
	humanoid.stance = Humanoid.Stance.STAND


## A seated player's input: a jump or a real push on the stick gets up.
func _sit_step() -> void:
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	if _controls != null:
		input = (input + _controls.stick.value).limit_length(1.0)
	var jump := (Input.is_action_just_pressed(&"jump") or _jump_queued) and not UIRouter.blocking()
	_jump_queued = false
	if jump or (input.length() > SIT_STAND_INPUT and not UIRouter.blocking()):
		stand_up()


## Eye height now wanted: standing, or the hip on the seat plus the same rise to the eye.
func _eye_target() -> float:
	if seated and _seat != null:
		return Humanoid.sit_hip_y(_seat.seat_top) + EYE_M - Humanoid.ORIGIN[Humanoid.B.PELVIS].y
	return EYE_M


## A kick on the stool (anyone's) knocks a sitter off.
func _on_interaction_applied(_peer: int, kind: StringName, _target_id: int, _payload: Dictionary) -> void:
	if kind == &"kick_stool" and seated:
		stand_up()


func _on_phase_changed(phase: GameLoop.Phase) -> void:
	if seated:
		stand_up()
	if phase != GameLoop.Phase.ROUND_LIVE:
		exit_cue()  # a Round that is over, or not begun, has no shot to aim: the table is about to be cleared and re-racked (V10)


## The table is being set up or cleared (RoundDirector.staging): nobody stays in the shooting stance over it.
func _on_staging_changed(on: bool) -> void:
	if on:
		exit_cue()


# --- CUE mode -------------------------------------------------------------------------------------

## The host's app went to the background: show the banner and leave CUE (no strike could land).
func _on_host_away(away: bool) -> void:
	_host_away = away
	if _controls != null:
		_controls.set_host_away(away)
	if away:
		exit_cue()


func toggle_cue() -> void:
	if UIRouter.blocking():
		return
	if mode == Mode.CUE:
		exit_cue()
	elif mode == Mode.WALK:
		enter_cue()


## Shooter + balls at rest + within reach of the cue ball. Returns whether CUE started.
func enter_cue() -> bool:
	if mode != Mode.WALK or _rd == null:
		return false
	if _host_away:
		_toast("Can't shoot yet: " + get_node(^"/root/NetManager").host_away_text())
		return false
	if _loop != null and _loop.phase != GameLoop.Phase.ROUND_LIVE:  # nothing is racked between Rounds: not "balls moving"
		_toast(WaitText.shot(&"no_round"))
		return false
	if _staging():
		_toast(WaitText.shot(&"staging"))
		return false
	if _rd.current_shooter_id != multiplayer.get_unique_id():
		_toast(WaitText.shot(&"not_your_turn", _shooter_name()))
		return false
	var ball := _cue_ball()
	if ball == null or _sim.awake > 0 or not _rd.can_strike(ball):
		_toast(WaitText.shot(&"balls_moving", "", _sim.awake))
		return false
	var away := cam.global_position.distance_to(ball.global_position)
	if away > ball.spec.cue_reach_m:
		_toast("Too far from the cue ball: %.1f m away, reach is %.1f m" % [away, ball.spec.cue_reach_m])
		return false
	stand_up()  # a seated shooter gets up first: the spot to restore is where they stand
	_saved_pos = global_position
	_saved_yaw = rotation.y
	_saved_pitch = head.rotation.x
	_verdict_pending = false
	_refused_inline = false
	_shot_seen = false
	_floor_y = global_position.y
	var eye_y := _floor_y + EYE_M
	_cue_pitch = atan2(ball.global_position.y - eye_y, CueController.BACK_M + CueController.LOOK_AHEAD_M)
	velocity = Vector3.ZERO
	_set_mode(Mode.CUE)
	if _controls != null and not _controls.touch:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	cue.begin(ball, rotation.y)
	return true


## Leave CUE. `restore`: back to where the player stood before aiming (Back, shooter change, host away, knock);
## otherwise stay by the shot (C16) on the nearest spot clear of the table, yaw and pitch as aimed.
func exit_cue(restore := true) -> void:
	if mode != Mode.CUE:
		return
	cue.end()
	if restore:
		_restore_spot()
	else:
		global_position = _free_spot(global_position, Vector3(sin(rotation.y), 0.0, cos(rotation.y)))
	_set_mode(Mode.WALK)


func _restore_spot() -> void:
	global_position = _saved_pos
	rotation.y = _saved_yaw
	head.rotation.x = _saved_pitch


## Where a standing player fits near `p`: `p` itself, else backing away along `away` (the shot line, off the ball),
## else rings around `p`; clear of walls and props (capsule query on the player's own mask) and of the table's outline
## including its wooden rails. Falls back to `fallback`, else to where they stood before aiming.
func _free_spot(p: Vector3, away: Vector3, fallback := Vector3.INF) -> Vector3:
	var space := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _body.shape
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	var fits := func(at: Vector3) -> bool:
		query.transform = Transform3D(Basis.IDENTITY, at + _body.position + Vector3(0.0, SNAP_LIFT_M, 0.0))
		return _clear_of_table(at) and space.intersect_shape(query, 1).is_empty()
	for i in int(SNAP_MAX_M / SNAP_STEP_M) + 1:
		var at := p + away * (i * SNAP_STEP_M)
		if fits.call(at):
			return at
	var rings := int(SNAP_MAX_M / 0.3)
	for r in range(1, rings + 1):
		for k in 16:
			var a := TAU * k / 16.0
			var at := p + Vector3(cos(a), 0.0, sin(a)) * (r * 0.3)
			if fits.call(at):
				return at
	return fallback if fallback.is_finite() else _saved_pos


func _clear_of_table(at: Vector3) -> bool:
	var t := cue.table
	if t == null:
		return true
	var l := t.to_local(at)
	var reach := (_body.shape as CapsuleShape3D).radius + t.spec.rail_width_m
	return absf(l.x) > t.spec.length_m * 0.5 + reach or absf(l.z) > t.spec.width_m * 0.5 + reach


## CueController each frame: the body sits behind the cue ball on the aim line, looking down it.
func pin_to_cue(ball_pos: Vector3, yaw: float) -> void:
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	global_position = Vector3(ball_pos.x, _floor_y, ball_pos.z) - fwd * CueController.BACK_M
	rotation.y = yaw
	head.rotation.x = _cue_pitch


## CueController each frame, after `pin_to_cue`: the camera stays where it was pinned, but the body is not (the table is wider than
## an arm). It stands at the nearest floor point behind the ball outside the table's outline (`CueStance`) and holds the stick the
## controller just posed: `tip`, the unit `butt_dir` from the tip to the butt, its `length`, the bridge hand `bridge_s` back from the tip.
func pose_body(tip: Vector3, butt_dir: Vector3, length: float, bridge_s: float) -> void:
	var yaw := rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var ball := global_position + fwd * CueController.BACK_M
	humanoid.set_cue_rig(CueStance.feet_for(cue.table, ball, fwd, _floor_y), yaw, tip, butt_dir, length, bridge_s)


## The shot is away: the player stays by it. A refusal the host already gave inside fire() walks them back instead.
func _on_fired(_intent: ShotIntent) -> void:
	if _refused_inline:
		_refused_inline = false
		exit_cue()
		return
	_verdict_pending = not _shot_seen  # a client waits for the host's answer; the host already knows it
	exit_cue(false)


## Refused inline (host: fire() has not reached `fired` yet) or later over the wire: back to the spot before aiming.
func _on_shot_rejected(_reason: StringName) -> void:
	if mode == Mode.CUE and not cue.active:
		_refused_inline = true
	elif _verdict_pending:
		_verdict_pending = false
		_restore_spot()


func _on_shooter_changed(peer_id: int) -> void:
	_verdict_pending = false
	if peer_id != multiplayer.get_unique_id():
		_clock_end_msec = 0
	if peer_id != multiplayer.get_unique_id():
		exit_cue()
	_sync_can_shoot()


func _sync_can_shoot() -> void:
	if _controls != null:
		_controls.set_can_shoot(can_shoot_now())


## What the Shoot button shows (06 P33 U6): a Round is live, it is my turn, nothing is moving or staged. `enter_cue` then adds the
## reach to the cue ball, which is distance, not a state of the table.
func can_shoot_now() -> bool:
	if _rd == null or _loop == null or _loop.phase != GameLoop.Phase.ROUND_LIVE or _staging():
		return false
	if _rd.current_shooter_id != multiplayer.get_unique_id() or _sim.awake > 0:
		return false
	var ball := _cue_ball()
	return ball != null and _rd.can_strike(ball)


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
	if m != Mode.WALK and seated:
		stand_up()
	if m != Mode.RAGDOLL:
		humanoid.stance = m as Humanoid.Stance  # same order
	if m != Mode.CUE:
		humanoid.clear_cue_rig()
	humanoid.set_body_hidden(is_local and m == Mode.CUE)
	if _controls != null:
		_controls.set_mode(m)
	mode_changed.emit(m)


## The roster name of whoever has the shot, for the "not your turn" refusals.
func _shooter_name() -> String:
	for e: Dictionary in _net.get_roster():
		if e.peer_id == _rd.current_shooter_id:
			return e.name
	return ""


func _toast(text: String) -> void:
	if UIRouter.instance != null:
		UIRouter.instance.toast(text.substr(0, 1).to_upper() + text.substr(1))


# --- knock: triggered ragdoll (06 P15) ----------------------------------------------------------------

## Go limp for `seconds`: leave CUE / CARRY cleanly (a carried rig is put down at the feet), hand the body to
## physics with `impulse` (a velocity change, m/s), stand up where the pelvis lies. The local camera rides the
## head bone meanwhile. A knock while limp adds the shove and extends the time.
func knock(impulse: Vector3, seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	if seated:
		_unseat()
	if mode == Mode.RAGDOLL:
		humanoid.ragdoll(impulse)
		_getup_msec = maxi(_getup_msec, until)
		return
	if is_local:
		_verdict_pending = false
		exit_cue()
		if mode == Mode.CARRY:
			place_camera(true)
		if _bartender != null and _bartender.is_open():
			_bartender.close()
		cam.top_level = true  # keeps its world transform; _process drives it from the head bone
		_cam_blend = 1.0
	_getup_msec = until
	velocity = Vector3.ZERO
	_body.set_deferred(&"disabled", true)
	if _avatar_cue != null:
		_avatar_cue.hide()
	_puppet_mode = Mode.RAGDOLL  # makes the next pose restyle the puppet
	_puppet_seated = false
	humanoid.ragdoll(impulse)
	_set_mode(Mode.RAGDOLL)


func is_ragdoll() -> bool:
	return humanoid.is_ragdoll()


## The body leans on a rail for a moment (LeanFeedback, from the applied interaction: every peer, local or puppet).
func lean_on(world_point: Vector3, seconds: float) -> void:
	if mode != Mode.RAGDOLL:
		humanoid.lean_on(world_point, seconds)


## Stand where the pelvis lies. A puppet resyncs to the owner's latest pose instead and drops the stale ones.
func _end_knock() -> void:
	var at := humanoid.pelvis_position()
	at.y = global_position.y
	humanoid.get_up()
	if not is_local and not _samples.is_empty():
		var s: PackedFloat64Array = _samples.back()
		at = Vector3(s[1], s[2], s[3])
		_samples = [s]
	global_position = at
	if _tag != null:
		_tag.position = Vector3(0.0, TAG_Y, 0.0)
	velocity = Vector3.ZERO
	_body.set_deferred(&"disabled", false)
	_airborne = false
	_set_mode(Mode.WALK)
	if is_local:
		_cam_from = cam.global_transform
		_cam_blend = 0.0
		if _cameras != null:
			_sync_carry()  # a rig the host did not take off us is still ours
	got_up.emit()


## The camera eases from the head bone back onto Head.
func _settle_cam(delta: float) -> void:
	_cam_blend = minf(1.0, _cam_blend + delta / Humanoid.BLEND_SEC)
	if _cam_blend >= 1.0:
		cam.top_level = false
		cam.transform = Transform3D.IDENTITY
	else:
		cam.global_transform = _cam_from.interpolate_with(head.global_transform, smoothstep(0.0, 1.0, _cam_blend))


# --- pose (04 push_player_pose) and puppet avatar -----------------------------------------------------

## pos 3×f32 | yaw u16 (0..2π) | u16 = mode << 14 | seated << 13 | pitch (13 bit, ±π/2). 16 B, trusted (friends-only, 04 §6).
## Mode 3 = RAGDOLL: the position is then the pelvis, where puppets resync when the owner stands. Seated: the position is the seat's
## floor point; the puppet finds the seat there.
func pack_pose() -> PackedByteArray:
	var p := global_position
	if mode == Mode.RAGDOLL:
		var pelvis := humanoid.pelvis_position()
		p = Vector3(pelvis.x, p.y, pelvis.z)
	_pose.encode_float(0, p.x)
	_pose.encode_float(4, p.y)
	_pose.encode_float(8, p.z)
	_pose.encode_u16(12, int(wrapf(rotation.y, 0.0, TAU) / TAU * 65535.0))
	var q := int((clampf(head.rotation.x / (PI / 2.0), -1.0, 1.0) * 0.5 + 0.5) * PITCH_MAX)
	_pose.encode_u16(14, (int(mode) << 14) | (SEATED_BIT if seated else 0) | q)
	return _pose


func apply_pose(blob: PackedByteArray) -> void:
	if blob.size() != POSE_BYTES:
		return
	var tail := blob.decode_u16(14)
	var s := PackedFloat64Array([
		Time.get_ticks_msec(), blob.decode_float(0), blob.decode_float(4), blob.decode_float(8),
		blob.decode_u16(12) * TAU / 65536.0, ((tail & PITCH_MAX) / float(PITCH_MAX) * 2.0 - 1.0) * (PI / 2.0), tail >> 14,
		1.0 if tail & SEATED_BIT != 0 else 0.0,
	])
	if _samples.is_empty():
		_show(s, s, 0.0)
	_samples.append(s)
	if _samples.size() > 8:
		_samples.pop_front()


func set_skin(skin: CharacterSkin) -> void:
	humanoid.apply_skin(skin)


static func skin_for_seat(seat: int) -> CharacterSkin:
	return SkinCatalog.default_character(seat)


## Turn this Player into a remote peer's avatar: no camera, no cue, no input; the humanoid + tag + cue stick.
func make_puppet(display_name: String, skin: CharacterSkin) -> void:
	is_local = false
	cam.queue_free()
	cue.queue_free()
	set_physics_process(false)
	set_process(true)
	humanoid.apply_skin(skin)
	_tag = Label3D.new()
	_tag.text = display_name
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.fixed_size = true
	_tag.pixel_size = 0.0009
	_tag.font_size = 32
	_tag.outline_size = 8
	_tag.position.y = TAG_Y
	add_child(_tag)
	_avatar_cue = MeshInstance3D.new()
	var stick := CylinderMesh.new()
	stick.top_radius = 0.008
	stick.bottom_radius = 0.015
	stick.height = CueController.CUE_LEN_M
	stick.radial_segments = 8
	_avatar_cue.mesh = stick
	_avatar_cue.layers = 1 | Humanoid.MIRROR_LAYER  # in the mirror too
	_avatar_cue.top_level = true  # placed in the world by `_puppet_cue`
	_avatar_cue.hide()
	add_child(_avatar_cue)


func _puppet_step() -> void:
	if mode == Mode.RAGDOLL:
		_tag.global_position = humanoid.pelvis_position() + Vector3(0.0, 0.8, 0.0)  # the name follows the body down
		_puppet_limp()
		return
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


## A limp puppet stands when its timer is out and the owner's latest pose says it stands too (or after a grace, so
## a silent owner cannot pin it down).
func _puppet_limp() -> void:
	var now := Time.get_ticks_msec()
	var owner_limp := not _samples.is_empty() and int(_samples.back()[6]) == Mode.RAGDOLL
	if (now >= _getup_msec and not owner_limp) or now >= _getup_msec + LIMP_GRACE_MSEC:
		_end_knock()


func _show(a: PackedFloat64Array, b: PackedFloat64Array, w: float) -> void:
	var m := int((b if w >= 0.5 else a)[6]) as Mode
	if m == Mode.RAGDOLL and mode != Mode.RAGDOLL:
		knock(Vector3.ZERO, 0.0)  # the owner is limp; stands when the owner does (a knock RPC may add time)
	if mode == Mode.RAGDOLL:
		return  # limp: the stream's position is ignored, `_end_knock` resyncs
	global_position = Vector3(a[1], a[2], a[3]).lerp(Vector3(b[1], b[2], b[3]), w)
	rotation.y = lerp_angle(a[4], b[4], w)
	head.rotation.x = lerpf(a[5], b[5], w)
	humanoid.set_look(0.0, head.rotation.x)
	var sample := b if w >= 0.5 else a
	var sat := m == Mode.WALK and sample[7] > 0.5
	if _avatar_cue != null and (m != _puppet_mode or sat != _puppet_seated):
		_puppet_mode = m
		_puppet_seated = sat
		if sat:  # the sample's own position is the seat's floor point; ours is still on its way there
			humanoid.set_seat(_seat_top_at(Vector3(sample[1], sample[2], sample[3])))
		humanoid.stance = Humanoid.Stance.SIT if sat else (m as Humanoid.Stance)
		_avatar_cue.visible = m == Mode.CUE
		if m != Mode.CUE:
			humanoid.clear_cue_rig()
			if _tag != null:
				_tag.position = Vector3(0.0, TAG_Y, 0.0)
	if m == Mode.CUE and _avatar_cue != null:
		_puppet_cue()


## The remote shooter's body and stick, the same stance the owner sees (the stick is the fixed one on the wire: at rest on the ball,
## on the aim line, no spin or pull-back): pinned `BACK_M` behind the ball like the owner's camera, the body where `CueStance` puts it.
func _puppet_cue() -> void:
	if _fallback_spec == null:
		_fallback_spec = TableSpec.new()
		_table = get_tree().root.find_child("Table", true, false) as Table
	var fwd := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	var spec := _table.spec if _table != null else _fallback_spec
	var base_y := _table.global_position.y if _table != null else 0.0
	var ball := global_position + fwd * CueController.BACK_M
	ball.y = base_y + spec.bed_height_m + spec.ball_radius_m
	var tip := ball - fwd * (spec.ball_radius_m + CueController.CUE_GAP_M)
	var right := fwd.cross(Vector3.UP)
	_avatar_cue.global_transform = Transform3D(Basis(right, fwd, right.cross(fwd)), tip - fwd * (CueController.CUE_LEN_M * 0.5))
	humanoid.set_cue_rig(CueStance.feet_for(_table, ball, fwd, global_position.y), rotation.y, tip, -fwd, CueController.CUE_LEN_M, CueController.BRIDGE_M)
	_tag.global_position = humanoid.bone_point(Humanoid.B.HEAD) + Vector3(0.0, TAG_Y - Humanoid.ORIGIN[Humanoid.B.HEAD].y, 0.0)


## A seated sample is at a seat's floor point: that seat's height (a stool's if the stream names none we know).
func _seat_top_at(floor_point: Vector3) -> float:
	var top := Bar.STOOL_TOP
	var nearest := 0.6
	for n in get_tree().get_nodes_in_group(&"interactable"):
		var it := n as Interactable
		if it == null or it.effective_kind() != Interactable.SIT:
			continue
		var d := Vector2(it.global_position.x - floor_point.x, it.global_position.z - floor_point.z).length()
		if d < nearest:
			nearest = d
			top = it.seat_top
	return top
