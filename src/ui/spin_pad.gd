class_name SpinPad
extends SpinDisc
## Touch spin disc (08 §2.3): drag inside the unit disc, double-tap resets. Emits `changed`; the CueController
## owns the value and pushes it back with `set_spin`.

signal changed(spin: Vector2)

const DOUBLE_TAP_MSEC := 300

var _finger := -1
var _last_tap := -100000


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			_finger = event.index
			var now := Time.get_ticks_msec()
			if now - _last_tap <= DOUBLE_TAP_MSEC:
				changed.emit(Vector2.ZERO)
			else:
				_emit_at(event.position)
			_last_tap = now
			accept_event()
		elif not event.pressed and event.index == _finger:
			_finger = -1
			accept_event()
	elif event is InputEventScreenDrag and event.index == _finger:
		_emit_at(event.position)
		accept_event()


func set_spin(v: Vector2) -> void:
	if v != spin:
		spin = v
		queue_redraw()


func _emit_at(pos: Vector2) -> void:
	var c := size * 0.5
	var r := minf(c.x, c.y) - 4.0  # SpinDisc._draw's radius
	var v := (pos - c) / r
	changed.emit(Vector2(v.x, -v.y).limit_length(1.0))
