class_name VirtualStick
extends Control
## Floating move stick (08 §2.3): origin is wherever the finger lands, radius 80, dead zone 0.15.
## `value` uses Input.get_vector's convention (up = −y) so it adds straight onto the keyboard vector.

const RING := preload("res://assets/ui/touch_stick_ring.svg")
const KNOB := preload("res://assets/ui/touch_stick_knob.svg")
const RADIUS := 80.0
const DEAD_ZONE := 0.15

var value := Vector2.ZERO
var _finger := -1
var _origin := Vector2.ZERO
var _knob := Vector2.ZERO


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			_finger = event.index
			_origin = event.position
			_knob = _origin
			accept_event()
			queue_redraw()
		elif not event.pressed and event.index == _finger:
			release()
			accept_event()
	elif event is InputEventScreenDrag and event.index == _finger:
		var d: Vector2 = (event.position - _origin).limit_length(RADIUS)
		_knob = _origin + d
		var mag := d.length() / RADIUS
		value = d.normalized() * ((mag - DEAD_ZONE) / (1.0 - DEAD_ZONE)) if mag >= DEAD_ZONE else Vector2.ZERO
		accept_event()
		queue_redraw()


func release() -> void:
	_finger = -1
	value = Vector2.ZERO
	queue_redraw()


func _draw() -> void:
	if _finger == -1:
		return
	draw_texture_rect(RING, Rect2(_origin - Vector2(RADIUS, RADIUS), Vector2(RADIUS, RADIUS) * 2.0), false)
	draw_texture_rect(KNOB, Rect2(_knob - Vector2(32, 32), Vector2(64, 64)), false)
