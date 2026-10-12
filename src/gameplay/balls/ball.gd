class_name Ball
extends RigidBody3D

## Jolt does contact friction; rolling resistance, CCD gating and the speed-dependent
## cushion rebound are ours (01 §3–§4). Mass follows radius³ so bigger balls keep real density.

signal struck(ball: Ball, intent: ShotIntent)
signal resting_changed(ball: Ball, resting: bool)
## Lifecycle change PhysicsSim streams to clients; `flag` is a BallEventCodec.Flag.
signal net_flag(ball: Ball, flag: int)
## `kind` is &"RAIL" (cushion or jaw, `other` = the rail body) or &"BALL" (`other` = the ball).
## Only fires while PhysicsSim has contact monitoring on, i.e. during a Shot.
signal contacted(ball: Ball, other: Node, kind: StringName)

const REGULATION_MASS_KG := 0.17  # kg; regulation ball density, not a table dimension
const MISCUE_POWER_SCALE := 0.35
const MISCUE_SCATTER_DEG := 4.0
const JUMP_MIN_ELEVATION_DEG := 30.0
const MASSE_MIN_ELEVATION_DEG := 45.0
const MASSE_MIN_SPIN := 0.60
const POCKET_SETTLE_SEC := 0.4  # a potted ball is retired this long after it reaches the cup

static var _g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))  # hoisted: per-tick lookup
static var _materials: Dictionary = {}  # BallType -> StandardMaterial3D, shared across balls

@export var ball_type: BallType
@export var spec: TableSpec

var id := ""
var is_cue_ball := false
var is_pocketed := false
var pocketed_in: StringName
var spawn_index := 0
var _pending_rail := Vector3.ZERO  # inward normal of a rail touched this step; consumed next tick
var _last_good_y := 0.0  # linear_velocity.y as of the end of the last _integrate_forces call
var _was_touching_wall := false
var net_id := -1  # stable wire id (< 64), assigned by RoundDirector before PhysicsSim.register
var motion: BallMotion.Params  # set by PhysicsSim.register
var retired := false
var pre_solve_velocity := Vector3.ZERO  # linear velocity at the start of the current step: the pre-impact one when a contact signal fires
var sim: PhysicsSim  # set by PhysicsSim.register; null = stock TableSpec values
var _base_mass := 0.0
var _ccd_speed := 0.0  # spec.ccd_speed_mps is derived; read once (apply_spec), not per tick
var _pending_rail_id: StringName
var is_resting := false  # our own (stricter, reliable) rest flag — PhysicsSim counts on this, not `sleeping`

@onready var radius: float = spec.ball_radius_m * ball_type.radius_multiplier


func _ready() -> void:
	var k := radius / TableSpec.REG_BALL_RADIUS
	_base_mass = REGULATION_MASS_KG * ball_type.mass_multiplier * k * k * k
	mass = _base_mass
	is_cue_ball = ball_type.behaviour_tags.has(&"cue")
	continuous_cd = is_cue_ball
	contact_monitor = true
	max_contacts_reported = 8 if is_cue_ball else 6
	apply_spec()
	var shape: SphereShape3D = $Shape.shape.duplicate()
	shape.radius = radius
	$Shape.shape = shape
	var mesh: SphereMesh = $Mesh.mesh.duplicate()
	mesh.radius = radius
	mesh.height = radius * 2.0
	if not _materials.has(ball_type):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = ball_type.color
		_materials[ball_type] = mat
	mesh.material = _materials[ball_type]
	$Mesh.mesh = mesh
	body_entered.connect(_on_body_entered)


## Everything of the spec a ball carries itself: contact material, explicit damping, CCD gate. `Table.apply_physics()`
## calls it again on every live change; rolling resistance and spin decay are read per tick from `spec`.
func apply_spec() -> void:
	physics_material_override.friction = spec.ball_friction
	physics_material_override.bounce = TableSpec.BASE_BOUNCE
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = spec.ball_linear_damp
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = spec.ball_angular_damp
	_ccd_speed = spec.ccd_speed_mps


## A cushion or jaw was touched this step or is being touched (PhysicsSim leaves such a cluster to Jolt).
func touched_wall() -> bool:
	return _was_touching_wall or _pending_rail != Vector3.ZERO


## Puts a settled ball back in the awake set (a blast or a shove reached it).
func wake() -> void:
	sleeping = false
	_set_resting(false)


func apply_mass_mult(m: float) -> void:
	mass = _base_mass * m


## The cue angle a strike really uses: a locked technique clamps the cue below its threshold instead of failing the
## shot. The touch overlay (08 §2.3) asks the same function, so what it shows is what the ball gets.
static func effective_elevation(deg: float, spin: Vector2, cue: CueSpec) -> float:
	var elevation := maxf(deg, 0.0)
	if not cue.jump_unlocked:
		elevation = minf(elevation, JUMP_MIN_ELEVATION_DEG - 1.0)
	if not cue.masse_unlocked and spin.length() >= MASSE_MIN_SPIN:
		elevation = minf(elevation, MASSE_MIN_ELEVATION_DEG - 1.0)
	return elevation


func strike(intent: ShotIntent, cue: CueSpec) -> void:
	var aim := intent.aim_dir.normalized()
	var power := clampf(intent.power, 0.0, 1.0)
	var spin_radius := cue.spin_offset_radius
	if sim != null:
		power *= sim.stat(&"cue_power_mult", intent.shooter_id, 1.0)
		spin_radius = sim.stat(&"cue_spin_radius_mult", intent.shooter_id, spin_radius)
	var spin := intent.spin_offset.limit_length(1.0)
	var elevation := effective_elevation(intent.elevation_deg, spin, cue)
	intent.jump = cue.jump_unlocked and power >= 0.70 and elevation >= JUMP_MIN_ELEVATION_DEG
	intent.masse = cue.masse_unlocked and elevation >= MASSE_MIN_ELEVATION_DEG and spin.length() >= MASSE_MIN_SPIN
	if spin.length() > cue.miscue_threshold:
		power *= MISCUE_POWER_SCALE
		aim = aim.rotated(deg_to_rad(randf_range(-MISCUE_SCATTER_DEG, MISCUE_SCATTER_DEG)))
	var aim3 := Vector3(aim.x, 0.0, aim.y)
	var right := aim3.cross(Vector3.UP).normalized()
	if elevation > 0.0:
		aim3 = aim3.rotated(right, -deg_to_rad(elevation))
	var up_c := right.cross(aim3).normalized()  # "top of the ball" as the cue sees it
	var offset := -aim3 * radius + (right * spin.x + up_c * spin.y) * radius * spin_radius
	freeze = false  # resting balls are frozen (PhysicsSim); an impulse on a frozen body is dropped
	sleeping = false
	_set_resting(false)
	apply_impulse(aim3 * power * mass * cue.power_cap_speed_mps, offset)
	struck.emit(self, intent)


## Called once the ball is in a pocket cup (Table's pot sensor: centre `pot_depth_m` below the cloth, 06 P30).
func pocket(pocket_id: StringName) -> void:
	is_pocketed = true
	pocketed_in = pocket_id
	if motion != null:
		motion.floor_y = motion.cup_floor_y  # the model lets it fall through the cloth plane onto the cup floor, like Jolt
	net_flag.emit(self, BallEventCodec.Flag.POCKETED)
	get_tree().create_timer(POCKET_SETTLE_SEC).timeout.connect(_retire_if_pocketed)  # let it settle in the cup first


## A ball restored in the meantime (a hole opened under it between shots) must not be hidden by the old timer.
func _retire_if_pocketed() -> void:
	if is_pocketed and not retired:
		retire()


## Takes the ball out of play: frozen, hidden, non-colliding, and counted as resting so
## PhysicsSim.all_resting can fire once every pot has finished (A1).
func retire() -> void:
	retired = true
	freeze = true
	visible = false
	$Shape.disabled = true
	_set_resting(true)
	net_flag.emit(self, BallEventCodec.Flag.RETIRED)


## Puts a retired (or stray) ball back in play at world `pos`, stationary; it settles under gravity.
func restore(pos: Vector3) -> void:
	is_pocketed = false
	pocketed_in = &""
	retired = false
	if motion != null:
		motion.floor_y = spec.bed_height_m + radius
	freeze = true  # teleporting a frozen body is the reliable way to set its transform
	global_position = pos
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	$Shape.disabled = false
	visible = true
	freeze = false
	sleeping = false
	_set_resting(false)
	net_flag.emit(self, BallEventCodec.Flag.RESTORED)


## Client balls are kinematic puppets of PhysicsSim's replica: no Jolt, no contacts, no interpolation.
func set_client_mode() -> void:
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	contact_monitor = false
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


## Applies a streamed lifecycle flag on a client (host already did the real thing).
func net_apply_flag(flag: int) -> void:
	match flag:
		BallEventCodec.Flag.POCKETED:
			is_pocketed = true
			motion.floor_y = motion.cup_floor_y
		BallEventCodec.Flag.RETIRED:
			retired = true
			visible = false
			$Shape.disabled = true
		BallEventCodec.Flag.RESTORED:
			is_pocketed = false
			retired = false
			motion.floor_y = spec.bed_height_m + radius
			$Shape.disabled = false
			visible = true


## `sleeping` is Jolt's own call and, for a body still in resting contact, may never flip true
## (or take far longer than `rest_speed_mps` should tolerate) — PhysicsSim counts `is_resting`
## instead, announced via `resting_changed` on every flip (both directions: a strike or a rail
## rebound waking the ball back up matters just as much as it settling). Deferred so a flip that
## happens mid physics-step never re-enters the physics callback from a connected listener.
func _emit_resting_changed(v: bool) -> void:
	resting_changed.emit(self, v)


func _set_resting(v: bool) -> void:
	if is_resting == v or (v and is_pocketed and not retired):
		return  # a pot only finishes at RETIRED (A1): a ball settling on the cup floor must not end the shot before it
	is_resting = v
	_emit_resting_changed.call_deferred(v)


func _on_body_entered(body: Node) -> void:
	if body.has_meta(&"rail_normal"):
		_pending_rail = body.get_meta(&"rail_normal")
		_pending_rail_id = body.get_meta(&"rail_id", &"")  # signal may fire pre-solve; apply next tick
		contacted.emit(self, body, &"RAIL")
	elif body is Ball:
		contacted.emit(self, body, &"BALL")


## True if this step's own solved contacts (not last tick's deferred `body_entered`) include a
## cushion or jaw — checked directly against Jolt's per-step contact list so it is available the
## same frame the contact happens, before `_last_good_y` below moves on to a post-contact value.
func _touching_wall(state: PhysicsDirectBodyState3D) -> bool:
	for i in state.get_contact_count():
		var collider := state.get_contact_collider_object(i)
		if collider is Node and (collider.has_meta(&"rail_normal") or collider.has_meta(&"jaw")):
			return true
	return false


## Jolt already bounced us at e0; rescale the normal component to e(v_in) (01 §3 "Cushions").
func _rail_rebound(state: PhysicsDirectBodyState3D, n: Vector3) -> void:
	var vn := state.linear_velocity.dot(n)  # post-solve, positive = leaving the rail
	if vn <= 0.05:
		return
	var e0 := maxf(spec.cushion_restitution, 0.001)
	var e := spec.cushion_restitution_at(vn / e0)
	if sim != null:
		e = minf(e * sim.rail_restitution_mult(_pending_rail_id), 1.0)  # a glass cushion never adds energy
	state.linear_velocity += n * vn * (e / e0 - 1.0)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	pre_solve_velocity = state.linear_velocity
	if _pending_rail != Vector3.ZERO:
		_rail_rebound(state, _pending_rail)
		_pending_rail = Vector3.ZERO
	var touching_wall := _touching_wall(state)
	if touching_wall and not _was_touching_wall:
		# Cushions and jaws are vertical walls — a purely horizontal contact normal — so the instant
		# a ball first touches one must never impart vertical velocity on its own; restoring the
		# vertical speed this function itself produced last tick (before this contact existed) leaves
		# a genuinely airborne ball (gravity, or a deliberately elevated strike) exactly as airborne
		# as it already was. Only the first frame of a new contact is corrected — a ball still
		# resting against a jaw/cushion several frames into the same contact (settling, rattling, or
		# genuinely falling through a corner facing into its pocket, case F) must keep integrating
		# normally, or it can never actually fall. A fast, high-spin ball contacting right where two
		# separate static bodies meet (a cushion's own end, a facing's start), or landing back down
		# almost level with a cushion's own short top edge, is a rough edge for any physics engine's
		# contact generation (loop-1 T4.8, gamma H at scale 1.0: Jolt resolved such contacts with
		# several m/s of spurious vertical speed and, on a second one, an almost-vertical contact
		# normal, launching the ball clean over the rail — reproducible with CCD on and collider
		# thickness well above the one-step-at-cue-power-cap floor, so it is not a tunnelling/step-
		# size problem; this undoes only the result). Checked directly against this step's own
		# `state.get_contact_count()`, not the `body_entered` signal (unlike `_pending_rail` above):
		# the signal only dispatches the *following* tick, by which point `_last_good_y` would
		# already have captured this step's own bad value.
		state.linear_velocity.y = _last_good_y
	_was_touching_wall = touching_wall
	var v := state.linear_velocity
	var speed := v.length()
	if speed < spec.rest_speed_mps and state.angular_velocity.length() < spec.rest_ang_rad_s:
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_set_resting(true)
		_last_good_y = 0.0
		return
	_set_resting(false)
	if not is_cue_ball:
		continuous_cd = speed > _ccd_speed
	var inertia := 0.4 * mass * radius * radius
	var dt := state.step
	if speed < 0.001:
		# a ball spinning in place (english after a stop) must still bleed it, or it never rests (~7 s tail)
		state.apply_torque(Vector3.DOWN * state.angular_velocity.y * mass * radius * spec.rolling_resistance * spec.spin_decay)
		_stop_spin(state, inertia, dt)
		_last_good_y = state.linear_velocity.y
		return
	var up := Vector3.UP
	var mu := spec.rolling_resistance
	if sim != null:
		mu *= sim.cloth_friction_mult
		if sim.table_tilt_deg != 0.0:
			state.apply_central_force(Vector3(sim.tilt_direction.x, 0.0, sim.tilt_direction.y) * mass * sim.tilt_accel(spec))
	var g := _g
	var dir := v / speed
	# Coulomb-like, opposing travel; a ball that has stopped slipping also settles (drag ramps up as it slows), and
	# never reverses within one step
	var w := state.angular_velocity
	var slip := Vector2(v.x + radius * w.z, v.z - radius * w.x).length()
	var settle := BallMotion.settle_factor(speed, spec.settle_speed_mps, spec.settle_boost * clampf(1.0 - slip / BallMotion.SETTLE_SLIP, 0.0, 1.0))
	var drag := minf(g * mu * settle, speed / dt)
	state.apply_central_force(-dir * mass * drag)
	# slow the roll in step with the slide (I = 2/5 m R², α = a/R) so it stays pure rolling
	state.apply_torque(-up.cross(dir) * 0.4 * mass * radius * drag)
	# english about the table normal bleeds off faster than roll
	var spin := up * state.angular_velocity.dot(up)
	state.apply_torque(-spin * mass * radius * mu * spec.spin_decay)
	_stop_spin(state, inertia, dt)
	_last_good_y = state.linear_velocity.y


## Constant (pivot) loss of spin about the table normal, never past zero within one step.
func _stop_spin(state: PhysicsDirectBodyState3D, inertia: float, dt: float) -> void:
	var w := state.angular_velocity.y
	if w != 0.0:
		state.apply_torque(Vector3.DOWN * signf(w) * inertia * minf(spec.spin_stop_rad_s2, absf(w) / dt))
