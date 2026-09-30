extends Node3D

## Hold `shoot`: power climbs to max, then bleeds down slower, then climbs again.
## Release strikes the Ball under the crosshair with a ShotIntent (01 §2).
## Spin cursor (I/J/K/L), elevation (Q/E) and reset (C) live here until the Player module lands.
## Reach and pullback follow the struck ball's own TableSpec (A1): no metre literal here, so the
## cue works unmodified at any table scale.

@export var cue_spec: CueSpec = preload("res://src/resources/cues/demo_cue.tres")
@export var charge_time := 0.8   # seconds 0 -> 1
@export var decay_time := 1.6    # seconds 1 -> 0, slower than the climb
@export var spin_rate := 1.5     # unit-disc units per second held
@export var elevation_rate_deg := 60.0
@export var max_elevation_deg := 80.0

const RAY_MAX_M := 20.0      # search radius only, NOT reach — see ball.spec.cue_reach_m below
const PULLBACK_RADII := 4.0  # cue pulls back this many of the aimed ball's radii at full power

var power := 0.0
var charging := false
var rising := true
var spin := Vector2.ZERO        # unit disc: x = side (right +), y = follow (+) / draw (−)
var elevation_deg := 0.0
var _aim_radius := 0.0          # last-aimed ball's radius, drives the pullback visual
## Where a release goes: `PhysicsSim.request_shot(intent)` — host validates and strikes, clients ask.
## Installed by MainLevel; invalid = nothing fires.
var shot_sink: Callable

@onready var cue_mesh: Node3D = $CueMesh
@onready var bar: ProgressBar = $HUD/PowerBar
@onready var disc: Control = $HUD/SpinDisc
@onready var _rest_z: float = cue_mesh.position.z
@onready var _rest_rot: Vector3 = cue_mesh.rotation


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("shoot"):
		charging = true
		rising = true
		power = 0.0
	elif event.is_action_released("shoot") and charging:
		charging = false
		_fire()
		power = 0.0
	elif event.is_action_pressed("spin_reset"):
		spin = Vector2.ZERO
		elevation_deg = 0.0


func _process(delta: float) -> void:
	if charging:
		if rising:
			power += delta / charge_time
			if power >= 1.0:
				power = 1.0
				rising = false
		else:
			power -= delta / decay_time
			if power <= 0.0:
				power = 0.0
				rising = true
	var d := Input.get_vector("spin_left", "spin_right", "spin_down", "spin_up")
	if d != Vector2.ZERO:
		spin = (spin + d * spin_rate * delta).limit_length(1.0)
	var e := Input.get_axis("elevate_down", "elevate_up")
	if e != 0.0:
		elevation_deg = clampf(elevation_deg + e * elevation_rate_deg * delta, 0.0, max_elevation_deg)
	var aimed := _find_ball()
	if aimed:
		_aim_radius = aimed.radius
	bar.value = power
	bar.modulate = Color.RED if power >= 1.0 else Color.WHITE
	cue_mesh.position.z = _rest_z + power * _aim_radius * PULLBACK_RADII
	cue_mesh.rotation.x = _rest_rot.x - deg_to_rad(elevation_deg)
	disc.spin = spin
	disc.elevation_deg = elevation_deg
	disc.miscue = cue_spec.miscue_threshold
	disc.queue_redraw()


## Raycasts within RAY_MAX_M and keeps the hit only if it lands within the struck ball's own
## cue_reach_m — a search radius, not a reach, so this works unmodified at any table scale.
func _find_ball() -> Ball:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var fwd := -cam.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + fwd * RAY_MAX_M)
	query.exclude = [owner.get_rid()] if owner is CollisionObject3D else []
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit.collider is Ball) or hit.collider.is_pocketed:
		return null
	var ball: Ball = hit.collider
	if cam.global_position.distance_to(hit.position) > ball.spec.cue_reach_m:
		return null
	return ball


func _fire() -> void:
	var ball := _find_ball()
	if ball == null or not ball.is_cue_ball or not shot_sink.is_valid():
		return
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_basis.z
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(fwd.x, fwd.z).normalized()
	intent.power = power
	intent.spin_offset = spin
	intent.elevation_deg = elevation_deg
	intent.shooter_id = multiplayer.get_unique_id()
	shot_sink.call(intent)
