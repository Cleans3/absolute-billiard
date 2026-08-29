extends Node3D

## Hold `shoot`: power climbs to max, then bleeds down slower, then climbs again.
## Release strikes the Ball under the crosshair with a ShotIntent (01 §2).

@export var cue_spec: CueSpec = CueSpec.new()
@export var charge_time := 0.8   # seconds 0 -> 1
@export var decay_time := 1.6    # seconds 1 -> 0, slower than the climb
@export var reach := 2.5
@export var pullback_m := 0.35

var power := 0.0
var charging := false
var rising := true

@onready var cue_mesh: Node3D = $CueMesh
@onready var bar: ProgressBar = $HUD/PowerBar
@onready var _rest_z: float = cue_mesh.position.z


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("shoot"):
		charging = true
		rising = true
		power = 0.0
	elif event.is_action_released("shoot") and charging:
		charging = false
		_fire()
		power = 0.0


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
	bar.value = power
	bar.modulate = Color.RED if power >= 1.0 else Color.WHITE
	cue_mesh.position.z = _rest_z + power * pullback_m


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
	intent.shooter_id = multiplayer.get_unique_id()
	hit.collider.strike(intent, cue_spec)
