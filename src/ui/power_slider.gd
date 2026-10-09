class_name PowerSlider
extends Control
## The power slider (08 §2.3): grab within the top `START_ZONE`, pull down, release strikes (`released`), back under
## `CANCEL_BELOW` cancels. `value` is 0..1; set it from outside with `set_value` (no signal, redraw only on change).
## The cue angle is no longer a slider: it is ElevationPad / ElevationOverlay.

signal released(value: float)
signal cancelled

const START_ZONE := 0.15
const CANCEL_BELOW := 0.03

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
			if f <= START_ZONE:
				_finger = event.index
				set_value(f)
				accept_event()
		elif not event.pressed and event.index == _finger:
			_finger = -1
			accept_event()
			var v := value
			set_value(0.0)
			if v >= CANCEL_BELOW:
				released.emit(v)
			else:
				cancelled.emit()
	elif event is InputEventScreenDrag and event.index == _finger:
		set_value(_fraction(event.position))
		accept_event()


func set_value(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if v != value:
		value = v
		queue_redraw()


func _fraction(pos: Vector2) -> float:
	return clampf(pos.y / maxf(size.y, 1.0), 0.0, 1.0)


func _draw() -> void:
	var track := get_theme_stylebox(&"panel", &"PanelInset")
	draw_style_box(track, Rect2(Vector2.ZERO, size))
	var pad := 8.0
	var inner := Rect2(pad, pad, size.x - pad * 2.0, size.y - pad * 2.0)
	var h := inner.size.y * value
	if h > 0.5:
		var r := Rect2(inner.position, Vector2(inner.size.x, h))
		var c0 := get_theme_color(&"pink", &"Game")
		var c1 := get_theme_color(&"pink" if value >= 1.0 else &"cyan", &"Game")
		draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]), PackedColorArray([c0, c0, c1, c1]))
		draw_rect(Rect2(inner.position.x - 4.0, r.end.y - 3.0, inner.size.x + 8.0, 6.0), get_theme_color(&"brass_light", &"Game"))
	if locked:
		draw_style_box(track, Rect2(Vector2.ZERO, size))
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))
	var font := get_theme_default_font()
	draw_string(font, Vector2(0, size.y + 20), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, get_theme_color(&"muted", &"Game"))
