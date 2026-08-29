extends Node3D

## Hold `shoot`: power climbs to max, then bleeds down slower, then climbs again.
## Release strikes the Ball under the crosshair with a ShotIntent (01 §2).
## Spin cursor (I/J/K/L), elevation (Q/E) and reset (C) live here until the Player module lands.

@export var cue_spec: CueSpec = CueSpec.new()
@export var charge_time := 0.8   # seconds 0 -> 1
@export var decay_time := 1.6    # seconds 1 -> 0, slower than the climb
@export var reach := 3.5
@export var pullback_m := 0.35
@export var spin_rate := 1.5     # unit-disc units per second held
@export var elevation_rate_deg := 60.0
@export var max_elevation_deg := 80.0

var power := 0.0
var charging := false
var rising := true
var spin := Vector2.ZERO        # unit disc: x = side (right +), y = follow (+) / draw (−)
var elevation_deg := 0.0

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
	bar.value = power
	bar.modulate = Color.RED if power >= 1.0 else Color.WHITE
	cue_mesh.position.z = _rest_z + power * pullback_m
	cue_mesh.rotation.x = _rest_rot.x - deg_to_rad(elevation_deg)
	disc.spin = spin
	disc.elevation_deg = elevation_deg
	disc.miscue = cue_spec.miscue_threshold
	disc.queue_redraw()


func _fire() -> void:
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + fwd * reach)
	query.exclude = [owner.get_rid()] if owner is CollisionObject3D else []
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit.collider is Ball) or hit.collider.is_pocketed:
		return
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(fwd.x, fwd.z).normalized()
	intent.power = power
	intent.spin_offset = spin
	intent.elevation_deg = elevation_deg
	intent.shooter_id = multiplayer.get_unique_id()
	hit.collider.strike(intent, cue_spec)
