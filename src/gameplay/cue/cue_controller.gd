class_name CueController
extends Node3D
## Owns CUE mode (08 §2.2): aim yaw, power, spin, elevation, called pocket, wobble; builds the `ShotIntent`
## and hands it to `shot_sink` (= PhysicsSim.request_shot — the host validates and strikes).
## Desktop keys/mouse and the TouchControls widgets write the same state through `turn`, `set_spin`,
## `set_elevation`, `call_pocket` and `release_power`, so the intent never learns the device (P1).

signal fired(intent: ShotIntent)

@export var cue_spec: CueSpec = preload("res://src/resources/cues/demo_cue.tres")
@export var charge_time := 0.8   # seconds 0 -> 1 (desktop hold)
@export var decay_time := 1.6    # seconds 1 -> 0, slower than the climb
@export var spin_rate := 1.5     # unit-disc units per second held
@export var elevation_rate_deg := 60.0
@export var max_elevation_deg := 80.0
@export var mouse_aim_rad_per_px := 0.0025
@export var touch_aim_deg_per_px := 0.12   # [tune]
@export var fine_aim_mult := 0.25          # second finger down

const WOBBLE_HZ := 0.8         # [tune]
const STAT_PERIOD := 0.25      # wobble / call-pocket stats re-read this often, not per frame
const BACK_M := 1.2            # camera distance behind the cue ball along the aim line [tune]
const LOOK_AHEAD_M := 0.5      # the camera looks at the point this far past the ball
const CUE_GAP_M := 0.005
const PULLBACK_RADII := 4.0    # cue pulls back this many ball radii at full power
const POCKET_ACTIONS: Array[StringName] = [
	&"call_pocket_1", &"call_pocket_2", &"call_pocket_3", &"call_pocket_4", &"call_pocket_5", &"call_pocket_6",
]

var active := false
var aim_yaw := 0.0              # radians, Godot yaw: forward = (−sin, −cos) in (x, z)
var power := 0.0
var charging := false
var rising := true
var spin := Vector2.ZERO        # unit disc: x = side (right +), y = follow (+) / draw (−)
var elevation_deg := 0.0
var called_pocket: StringName = &""
var call_required := false
## Where a release goes: `PhysicsSim.request_shot(intent)`. Installed by MainLevel; invalid = nothing fires.
var shot_sink: Callable
var effects: Node               # EffectManager (get_stat), optional
var table: Table                # pocket ids for call-pocket, optional
var controls: TouchControls     # optional: headless probes and puppets have none
var player: Node                # Player: pinned to the aim line while active
var ball: Ball

var _t := 0.0
var _stat_wait := 0.0
var _wobble_deg := 0.0

@onready var cue_mesh: MeshInstance3D = $CueMesh
@onready var _cue_len: float = (cue_mesh.mesh as CylinderMesh).height


func _ready() -> void:
	cue_mesh.top_level = true
	cue_mesh.hide()
	set_process(false)
	set_process_unhandled_input(false)


func begin(cue_ball: Ball, yaw: float) -> void:
	ball = cue_ball
	aim_yaw = yaw
	power = 0.0
	charging = false
	called_pocket = &""
	_t = 0.0
	refresh_stats()
	active = true
	cue_mesh.show()
	set_process(true)
	set_process_unhandled_input(true)
	if controls != null:
		controls.spin_pad.miscue = cue_spec.miscue_threshold
		controls.set_call_pockets(call_required)
		controls.set_called_pocket(-1)
	_push_ui()


func end() -> void:
	active = false
	charging = false
	power = 0.0
	cue_mesh.hide()
	set_process(false)
	set_process_unhandled_input(false)
	if controls != null:
		controls.set_clock("")
		controls.power.set_value(0.0)


func refresh_stats() -> void:
	_wobble_deg = maxf(0.0, _stat(&"cue_aim_wobble_deg", 0.0) - cue_spec.wobble_reduction)
	call_required = _stat(&"rule_call_pocket", 0.0) > 0.0
	_stat_wait = STAT_PERIOD


func _stat(stat: StringName, base: float) -> float:
	return effects.call(&"get_stat", stat, multiplayer.get_unique_id(), base) if effects != null else base


# --- state writers: the one path desktop and touch share ------------------------------------------

func turn(rad: float) -> void:
	aim_yaw = wrapf(aim_yaw + rad, -PI, PI)


func set_spin(v: Vector2) -> void:
	spin = v.limit_length(1.0)


func set_elevation(deg: float) -> void:
	elevation_deg = clampf(deg, 0.0, max_elevation_deg)


func call_pocket(index: int) -> void:
	if not call_required or table == null or index < 0 or index >= table.layout.pockets.size():
		return
	called_pocket = table.layout.pockets[index].id
	if controls != null:
		controls.set_called_pocket(index)


## A release (slider let go, or `shoot` released). Refused until a pocket is called when the rule is on.
func release_power(p: float) -> void:
	if not active:
		return
	if call_required and called_pocket == &"":
		if controls != null:
			controls.toast("Call a pocket first")
		return
	fire(p)


func fire(p: float) -> void:
	var intent := build_intent(p)
	end()
	if shot_sink.is_valid():
		shot_sink.call(intent)
	fired.emit(intent)


## Aim carries the swayed yaw (03 §2.2): the wobble is part of the shot, not just a visual.
func build_intent(p: float) -> ShotIntent:
	var yaw := swayed_yaw()
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(-sin(yaw), -cos(yaw))
	intent.power = p
	intent.spin_offset = spin
	intent.elevation_deg = elevation_deg
	intent.shooter_id = multiplayer.get_unique_id()
	intent.called_pocket = called_pocket
	return intent


func swayed_yaw() -> float:
	return aim_yaw + deg_to_rad(_wobble_deg) * sin(TAU * WOBBLE_HZ * _t)


# --- desktop input --------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if UIRouter.blocking():
		return
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			turn(-event.relative.x * mouse_aim_rad_per_px * float(Settings.value(&"cue_aim_sens")))
	elif event.is_action_pressed(&"shoot"):
		if call_required and called_pocket == &"":
			if controls != null:
				controls.toast("Call a pocket first (1-6)")
			return
		charging = true
		rising = true
		power = 0.0
	elif event.is_action_released(&"shoot") and charging:
		charging = false
		var p := power
		power = 0.0
		release_power(p)
	elif event.is_action_pressed(&"spin_reset"):
		spin = Vector2.ZERO
		elevation_deg = 0.0
	else:
		for i in POCKET_ACTIONS.size():
			if event.is_action_pressed(POCKET_ACTIONS[i]):
				call_pocket(i)


func _process(delta: float) -> void:
	_t += delta
	_stat_wait -= delta
	if _stat_wait <= 0.0:
		refresh_stats()
	if controls != null:
		var d := controls.look.consume()
		if d != Vector2.ZERO:
			turn(-d.x * deg_to_rad(touch_aim_deg_per_px) * float(Settings.value(&"cue_aim_sens")) * (fine_aim_mult if controls.look.fine else 1.0))
		if controls.touch:
			power = controls.power.value
	if charging and UIRouter.blocking():  # a modal opened mid-charge: drop it, the release will never arrive
		charging = false
		power = 0.0
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
	var v := Input.get_vector(&"spin_left", &"spin_right", &"spin_down", &"spin_up")
	if UIRouter.blocking():
		v = Vector2.ZERO
	if v != Vector2.ZERO:
		set_spin(spin + v * spin_rate * delta)
	var e := Input.get_axis(&"elevate_down", &"elevate_up")
	if e != 0.0 and not UIRouter.blocking():
		set_elevation(elevation_deg + e * elevation_rate_deg * delta)
	_pose_cue()
	if player != null:
		player.call(&"pin_to_cue", ball.global_position, aim_yaw)
	_push_ui()


## Cue in world space along the (swayed) aim, tip at the ball, butt up by the elevation.
func _pose_cue() -> void:
	var yaw := swayed_yaw()
	var aim3 := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := aim3.cross(Vector3.UP)
	var d := aim3.rotated(right, -deg_to_rad(elevation_deg))
	var tip := ball.global_position - d * (ball.radius + CUE_GAP_M + power * ball.radius * PULLBACK_RADII)
	cue_mesh.global_transform = Transform3D(Basis(right, d, right.cross(d)), tip - d * (_cue_len * 0.5))


func _push_ui() -> void:
	if controls == null:
		return
	controls.spin_pad.set_spin(spin)
	controls.elevation.set_value(elevation_deg)
	controls.set_elevation_cap(Ball.effective_elevation(max_elevation_deg, spin, cue_spec))
	if not controls.touch:
		controls.power.set_value(power)
	var text := "Call a pocket   " if call_required and called_pocket == &"" else ""
	if player != null:
		text += player.call(&"shot_clock_text")
	controls.set_clock(text)
