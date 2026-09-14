class_name DebugFreeCamera
extends Node3D

## Free camera (T2.3): toggled by debug_freecam (F2). Detaches from the player, flies with
## WASD (reused move_* actions) + mouse look, Q/E up/down (raw physical keys — no new input
## action budget spent), scroll wheel adjusts speed. Restores the player camera + input on
## toggle back. Player input is suppressed via built-in process flags, never by editing
## player.gd (owned by beta-4s-1) — same for the CueController child, reached the same way.

const PITCH_LIMIT := deg_to_rad(89.0)
const LOOK_SENSITIVITY := 0.0025
const MIN_SPEED := 0.5
const MAX_SPEED := 100.0

var player: CharacterBody3D
var active := false
var speed := 5.0

var _camera: Camera3D
var _cue_controller: Node


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	add_child(_camera)


func toggle() -> void:
	active = not active
	if active:
		_cue_controller = player.get_node_or_null("Head/CueController")
		var head_cam: Camera3D = player.get_node("Head/headCam")
		global_transform = head_cam.global_transform
		rotation.z = 0.0
		_camera.rotation = Vector3.ZERO
		player.set_physics_process(false)
		player.set_process_unhandled_input(false)
		if _cue_controller:
			_cue_controller.set_process(false)
			_cue_controller.set_process_unhandled_input(false)
		_camera.current = true
	else:
		player.set_physics_process(true)
		player.set_process_unhandled_input(true)
		if _cue_controller:
			_cue_controller.set_process(true)
			_cue_controller.set_process_unhandled_input(true)
		var head_cam: Camera3D = player.get_node("Head/headCam")
		head_cam.current = true


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * LOOK_SENSITIVITY)
		_camera.rotation.x = clampf(
			_camera.rotation.x - event.relative.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT
		)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = clampf(speed * 1.15, MIN_SPEED, MAX_SPEED)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = clampf(speed / 1.15, MIN_SPEED, MAX_SPEED)


func _process(delta: float) -> void:
	if not active:
		return
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := transform.basis * Vector3(input.x, 0.0, input.y)
	if Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir -= Vector3.UP
	if dir != Vector3.ZERO:
		global_position += dir.normalized() * speed * delta
