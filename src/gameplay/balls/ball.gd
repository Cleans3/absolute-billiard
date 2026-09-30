class_name Ball
extends RigidBody3D

## Jolt does contact friction; rolling resistance, CCD gating and the speed-dependent
## cushion rebound are ours (01 §3–§4). Mass follows radius³ so bigger balls keep real density.

signal struck(ball: Ball, intent: ShotIntent)
signal resting_changed(ball: Ball, resting: bool)
## `kind` is &"RAIL" (cushion or jaw, `other` = the rail body) or &"BALL" (`other` = the ball).
## Only fires while PhysicsSim has contact monitoring on, i.e. during a Shot.
signal contacted(ball: Ball, other: Node, kind: StringName)

const REGULATION_MASS_KG := 0.17  # kg; regulation ball density, not a table dimension
const MISCUE_POWER_SCALE := 0.35
const MISCUE_SCATTER_DEG := 4.0
const JUMP_MIN_ELEVATION_DEG := 30.0
const MASSE_MIN_ELEVATION_DEG := 45.0
const MASSE_MIN_SPIN := 0.60

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
var sim: PhysicsSim  # set by PhysicsSim.register; null = stock TableSpec values
var _base_mass := 0.0
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
	physics_material_override.friction = spec.ball_friction
	physics_material_override.bounce = spec.ball_restitution
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


func apply_mass_mult(m: float) -> void:
	mass = _base_mass * m


func strike(intent: ShotIntent, cue: CueSpec) -> void:
	var aim := intent.aim_dir.normalized()
	var power := clampf(intent.power, 0.0, 1.0)
	var spin_radius := cue.spin_offset_radius
	if sim != null:
		power *= sim.stat(&"cue_power_mult", intent.shooter_id, 1.0)
		spin_radius = sim.stat(&"cue_spin_radius_mult", intent.shooter_id, spin_radius)
	var spin := intent.spin_offset.limit_length(1.0)
	var elevation := maxf(intent.elevation_deg, 0.0)
	# locked techniques clamp the cue below their threshold instead of failing the shot
	if not cue.jump_unlocked:
		elevation = minf(elevation, JUMP_MIN_ELEVATION_DEG - 1.0)
	if not cue.masse_unlocked and spin.length() >= MASSE_MIN_SPIN:
		elevation = minf(elevation, MASSE_MIN_ELEVATION_DEG - 1.0)
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
	sleeping = false
	_set_resting(false)
	apply_impulse(aim3 * power * mass * cue.power_cap_speed_mps, offset)
	struck.emit(self, intent)


func pocket(pocket_id: StringName) -> void:
	is_pocketed = true
	pocketed_in = pocket_id
	get_tree().create_timer(0.4).timeout.connect(retire)  # let it fall into the chute first


## Takes the ball out of play: frozen, hidden, non-colliding, and counted as resting so
## PhysicsSim.all_resting can fire once every pot has finished (A1).
func retire() -> void:
	freeze = true
	visible = false
	$Shape.disabled = true
	_set_resting(true)


## Puts a retired (or stray) ball back in play at world `pos`, stationary; it settles under gravity.
func restore(pos: Vector3) -> void:
	is_pocketed = false
	pocketed_in = &""
	freeze = true  # teleporting a frozen body is the reliable way to set its transform
	global_position = pos
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	$Shape.disabled = false
	visible = true
	freeze = false
	sleeping = false
	_set_resting(false)


## `sleeping` is Jolt's own call and, for a body still in resting contact, may never flip true
## (or take far longer than `rest_speed_mps` should tolerate) — PhysicsSim counts `is_resting`
## instead, announced via `resting_changed` on every flip (both directions: a strike or a rail
## rebound waking the ball back up matters just as much as it settling). Deferred so a flip that
## happens mid physics-step never re-enters the physics callback from a connected listener.
func _emit_resting_changed(v: bool) -> void:
	resting_changed.emit(self, v)


func _set_resting(v: bool) -> void:
	if is_resting == v:
		return
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
	var e0 := spec.cushion_restitution
	var e := spec.cushion_restitution_at(vn / e0)
	if sim != null:
		e *= sim.rail_restitution_mult(_pending_rail_id)
	state.linear_velocity += n * vn * (e / e0 - 1.0)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
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
	if speed < spec.rest_speed_mps and state.angular_velocity.length() < 0.15:
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_set_resting(true)
		_last_good_y = 0.0
		return
	_set_resting(false)
	if not is_cue_ball:
		continuous_cd = speed > spec.ccd_speed_mps
	if speed < 0.001:
		_last_good_y = state.linear_velocity.y
		return
	var up := Vector3.UP
	var mu := spec.rolling_resistance
	if sim != null:
		mu *= sim.cloth_friction_mult
		if sim.table_tilt_deg != 0.0:
			var t := deg_to_rad(sim.table_tilt_deg)
			state.apply_central_force(Vector3(sim.tilt_direction.x, 0.0, sim.tilt_direction.y) * mass * float(ProjectSettings.get_setting("physics/3d/default_gravity")) * sin(t))
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var dir := v / speed
	# Coulomb-like: magnitude independent of speed, opposing travel
	state.apply_central_force(-dir * mass * g * mu)
	# slow the roll in step with the slide (I = 2/5 m R², α = a/R) so it stays pure rolling
	state.apply_torque(-up.cross(dir) * 0.4 * mass * radius * g * mu)
	# english about the table normal bleeds off faster than roll
	var spin := up * state.angular_velocity.dot(up)
	state.apply_torque(-spin * mass * radius * mu * spec.spin_decay)
	_last_good_y = state.linear_velocity.y
