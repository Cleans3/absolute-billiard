class_name DebugShotConsole
extends CanvasLayer

## Shot console + replay (T2.6): place the cue ball, fire a scripted ShotIntent, replay the
## last shot from the same position. Toggled by debug_console (F5). Uses the same CueSpec
## resource CueController uses (never CueSpec.new(), contract A3) and calls Ball.strike()
## directly — the identical entry point the real cue uses, so the shot executes exactly as
## if struck normally.

const CUE_SPEC := preload("res://src/resources/cues/demo_cue.tres")

var table: Table
var rack: Node3D

var _x: SpinBox
var _z: SpinBox
var _power: SpinBox
var _spin_x: SpinBox
var _spin_y: SpinBox
var _elevation: SpinBox
var _last_intent: ShotIntent
var _last_pos: Vector3


func _ready() -> void:
	layer = 10
	var panel := PanelContainer.new()
	panel.offset_left = 8
	panel.offset_top = -300
	panel.offset_right = 300
	panel.offset_bottom = -8
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)

	_x = _row(box, "cue x (m, table-local)", -5.0, 5.0)
	_z = _row(box, "cue z (m, table-local)", -3.0, 3.0)
	_power = _row(box, "power 0-1", 0.0, 1.0)
	_power.value = 0.6
	_spin_x = _row(box, "spin side -1..1", -1.0, 1.0)
	_spin_y = _row(box, "spin follow -1..1", -1.0, 1.0)
	_elevation = _row(box, "elevation deg", 0.0, 80.0)

	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	var fire := Button.new()
	fire.text = "Fire"
	fire.pressed.connect(_on_fire)
	buttons.add_child(fire)
	var replay := Button.new()
	replay.text = "Replay"
	replay.pressed.connect(_on_replay)
	buttons.add_child(replay)


func _row(parent: Control, label_text: String, lo: float, hi: float) -> SpinBox:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(180, 0)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = 0.01
	row.add_child(spin)
	parent.add_child(row)
	return spin


func _cue_ball() -> Ball:
	if not rack:
		return null
	for ball in rack.get_children():
		if ball is Ball and ball.is_cue_ball:
			return ball
	return null


func _table_forward() -> Vector2:
	var world_dir: Vector3 = table.global_transform.basis * Vector3(1, 0, 0)
	return Vector2(world_dir.x, world_dir.z).normalized()


func _on_fire() -> void:
	var cue_ball := _cue_ball()
	if not cue_ball:
		return
	var y := table.cloth_y() + cue_ball.radius + 0.002
	var pos := table.to_global(Vector3(_x.value, y, _z.value))
	cue_ball.sleeping = false
	cue_ball.global_position = pos
	cue_ball.linear_velocity = Vector3.ZERO
	cue_ball.angular_velocity = Vector3.ZERO

	var intent := ShotIntent.new()
	intent.aim_dir = _table_forward()
	intent.power = _power.value
	intent.spin_offset = Vector2(_spin_x.value, _spin_y.value)
	intent.elevation_deg = _elevation.value
	intent.shooter_id = multiplayer.get_unique_id()

	_last_intent = intent
	_last_pos = pos
	cue_ball.strike(intent, CUE_SPEC)


func _on_replay() -> void:
	if not _last_intent:
		return
	var cue_ball := _cue_ball()
	if not cue_ball:
		return
	cue_ball.sleeping = false
	cue_ball.global_position = _last_pos
	cue_ball.linear_velocity = Vector3.ZERO
	cue_ball.angular_velocity = Vector3.ZERO
	cue_ball.strike(_last_intent, CUE_SPEC)
