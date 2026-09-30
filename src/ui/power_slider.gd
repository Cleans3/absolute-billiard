class_name PowerSlider
extends Control
## One vertical drag slider, two jobs (08 §2.3). Power (`from_top`): grab within the top `START_ZONE`, pull down,
## release strikes (`released`), back under `CANCEL_BELOW` cancels. Elevation: absolute bottom = 0, holds its value.
## `value` is 0..`max_value`; set it from outside with `set_value` (no signal, redraw only on change).

signal released(value: float)
signal cancelled
signal changed(value: float)

const START_ZONE := 0.15
const CANCEL_BELOW := 0.03

@export var from_top := true
@export var max_value := 1.0
@export var caption := ""

var value := 0.0
var locked := false:
	set(v):
		if v != locked:
			locked = v
			queue_redraw()
var _finger := -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1 and not locked:
			var f := _fraction(event.position)
			if not from_top or f <= START_ZONE:
				_finger = event.index
				_drag_to(f)
				accept_event()
		elif not event.pressed and event.index == _finger:
			_finger = -1
			accept_event()
			if from_top:
				var v := value
				set_value(0.0)
				if v / max_value >= CANCEL_BELOW:
					released.emit(v)
				else:
					cancelled.emit()
	elif event is InputEventScreenDrag and event.index == _finger:
		_drag_to(_fraction(event.position))
		accept_event()


func set_value(v: float) -> void:
	v = clampf(v, 0.0, max_value)
	if v != value:
		value = v
		queue_redraw()


func _fraction(pos: Vector2) -> float:
	var f := clampf(pos.y / maxf(size.y, 1.0), 0.0, 1.0)
	return f if from_top else 1.0 - f


func _drag_to(f: float) -> void:
	var before := value
	set_value(f * max_value)
	if value != before:
		changed.emit(value)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var h := size.y * value / max_value
	var fill := Color(0.9, 0.2, 0.2, 0.8) if value >= max_value else Color(1, 1, 1, 0.6)
	if from_top:
		draw_rect(Rect2(0, 0, size.x, h), fill)
	else:
		draw_rect(Rect2(0, size.y - h, size.x, h), fill)
	if locked:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))
	draw_string(ThemeDB.fallback_font, Vector2(0, size.y + 14), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x, 12)
