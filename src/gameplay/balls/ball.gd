class_name Ball
extends RigidBody3D

## Jolt does contact friction; rolling resistance, CCD gating and the speed-dependent
## cushion rebound are ours (01 §3–§4). Mass follows radius³ so bigger balls keep real density.

signal struck(ball: Ball, intent: ShotIntent)
signal rested(ball: Ball)

const REGULATION_RADIUS_M := 0.0286
const REGULATION_MASS_KG := 0.17
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

@onready var radius: float = spec.ball_radius_m * ball_type.radius_multiplier


func _ready() -> void:
	var k := radius / REGULATION_RADIUS_M
	mass = REGULATION_MASS_KG * ball_type.mass_multiplier * k * k * k
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


func strike(intent: ShotIntent, cue: CueSpec) -> void:
	var aim := intent.aim_dir.normalized()
	var power := clampf(intent.power, 0.0, 1.0)
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
	var offset := -aim3 * radius + (right * spin.x + up_c * spin.y) * radius * cue.spin_offset_radius
	sleeping = false
	apply_impulse(aim3 * power * mass * cue.power_cap_speed_mps, offset)
	struck.emit(self, intent)


func pocket(pocket_id: StringName) -> void:
	is_pocketed = true
	pocketed_in = pocket_id
	# ponytail: pocketed balls just vanish; RoundDirector owns respawn/scoring later
	get_tree().create_timer(0.4).timeout.connect(func() -> void:
		freeze = true
		visible = false
		$Shape.disabled = true)


## Jolt never sleeps a body with a custom integrator on its own, and forcing `sleeping` emits no signal.
func _rest_now() -> void:
	sleeping = true
	rested.emit(self)


func _on_body_entered(body: Node) -> void:
	if body.has_meta(&"rail_normal"):
		_pending_rail = body.get_meta(&"rail_normal")  # signal may fire pre-solve; apply next tick


## Jolt already bounced us at e0; rescale the normal component to e(v_in) (01 §3 "Cushions").
func _rail_rebound(state: PhysicsDirectBodyState3D, n: Vector3) -> void:
	var vn := state.linear_velocity.dot(n)  # post-solve, positive = leaving the rail
	if vn <= 0.05:
		return
	var e0 := spec.cushion_restitution
	var e := spec.cushion_restitution_at(vn / e0)
	state.linear_velocity += n * vn * (e / e0 - 1.0)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _pending_rail != Vector3.ZERO:
		_rail_rebound(state, _pending_rail)
		_pending_rail = Vector3.ZERO
	var v := state.linear_velocity
	var speed := v.length()
	if speed < spec.rest_speed_mps and state.angular_velocity.length() < 0.15:
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		if not sleeping:
			_rest_now.call_deferred()
		return
	if not is_cue_ball:
		continuous_cd = speed > spec.ccd_speed_mps
	if speed < 0.001:
		return
	var up := Vector3.UP
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var dir := v / speed
	var mu := spec.rolling_resistance
	# Coulomb-like: magnitude independent of speed, opposing travel
	state.apply_central_force(-dir * mass * g * mu)
	# slow the roll in step with the slide (I = 2/5 m R², α = a/R) so it stays pure rolling
	state.apply_torque(-up.cross(dir) * 0.4 * mass * radius * g * mu)
	# english about the table normal bleeds off faster than roll
	var spin := up * state.angular_velocity.dot(up)
	state.apply_torque(-spin * mass * radius * mu * spec.spin_decay)
