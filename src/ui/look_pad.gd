class_name LookPad
extends Control
## Drag-look surface (08 §2.3). Only the first finger moves the view; a second finger down
## flips `fine` (aim ×0.25 in CUE). Controls above it (stick, buttons, sliders) take their own touches first.

var fine := false
var _fingers: Array[int] = []
var _delta := Vector2.ZERO


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_fingers.append(event.index)
		else:
			_fingers.erase(event.index)
		fine = _fingers.size() >= 2
		accept_event()
	elif event is InputEventScreenDrag and not _fingers.is_empty() and event.index == _fingers[0]:
		_delta += event.relative
		accept_event()


## Pixels dragged since the last call.
func consume() -> Vector2:
	var d := _delta
	_delta = Vector2.ZERO
	return d


func release() -> void:
	_fingers.clear()
	fine = false
	_delta = Vector2.ZERO
