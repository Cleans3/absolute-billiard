class_name Ball
extends RigidBody3D

## Jolt does contact friction; rolling resistance and the rest-snap are ours (01 §4).

const MISCUE_POWER_SCALE := 0.35
const MISCUE_SCATTER_DEG := 4.0

@export var ball_type: BallType
@export var spec: TableSpec

var id := ""
var is_cue_ball := false
var is_pocketed := false
var pocketed_in: StringName
var spawn_index := 0

@onready var radius: float = spec.ball_radius_m * ball_type.radius_multiplier


func _ready() -> void:
	mass = 0.17 * ball_type.mass_multiplier
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	is_cue_ball = ball_type.behaviour_tags.has(&"cue")
	var shape: SphereShape3D = $Shape.shape.duplicate()
	shape.radius = radius
	$Shape.shape = shape
	var mesh: SphereMesh = $Mesh.mesh.duplicate()
	mesh.radius = radius
	mesh.height = radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ball_type.color
	mesh.material = mat
	$Mesh.mesh = mesh


func strike(intent: ShotIntent, cue: CueSpec) -> void:
	var aim := intent.aim_dir.normalized()
	var power := clampf(intent.power, 0.0, 1.0)
	var spin := intent.spin_offset.limit_length(1.0)
	if spin.length() > cue.miscue_threshold:
		power *= MISCUE_POWER_SCALE
		aim = aim.rotated(deg_to_rad(randf_range(-MISCUE_SCATTER_DEG, MISCUE_SCATTER_DEG)))
	var aim3 := Vector3(aim.x, 0.0, aim.y)
	if intent.elevation_deg > 0.0:
		aim3 = aim3.rotated(aim3.cross(Vector3.UP).normalized(), -deg_to_rad(intent.elevation_deg))
	var offset := -aim3 * radius + Vector3(spin.x, spin.y, 0.0) * radius * cue.spin_offset_radius
	sleeping = false
	apply_impulse(aim3 * power * cue.power_cap_impulse, offset)


func pocket(pocket_id: StringName) -> void:
	is_pocketed = true
	pocketed_in = pocket_id
	# ponytail: pocketed balls just vanish; RoundDirector owns respawn/scoring later
	get_tree().create_timer(0.4).timeout.connect(func() -> void:
		freeze = true
		visible = false
		$Shape.disabled = true)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var v := state.linear_velocity
	if v.length() < spec.rest_speed_mps and state.angular_velocity.length() < 0.15:
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		return
	if v.length() < 0.001:
		return
	var up := Vector3.UP
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	var f_roll := -v.normalized() * mass * g * spec.rolling_resistance
	state.apply_central_force(f_roll)
	state.apply_torque((-up * radius).cross(f_roll))
	var spin := up * state.angular_velocity.dot(up)
	state.apply_torque(-spin * mass * radius * spec.rolling_resistance * spec.spin_decay)
