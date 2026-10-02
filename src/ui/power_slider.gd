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
	var track := get_theme_stylebox(&"panel", &"PanelInset")
	draw_style_box(track, Rect2(Vector2.ZERO, size))
	var pad := 8.0
	var inner := Rect2(pad, pad, size.x - pad * 2.0, size.y - pad * 2.0)
	var h := inner.size.y * value / max_value
	var top := get_theme_color(&"pink" if value >= max_value else &"cyan", &"Game")
	var bottom := get_theme_color(&"pink", &"Game") if from_top else get_theme_color(&"cyan", &"Game")
	if h > 0.5:
		var r := Rect2(inner.position.x, inner.position.y if from_top else inner.end.y - h, inner.size.x, h)
		var c0 := bottom if from_top else top
		var c1 := top if from_top else bottom
		draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]), PackedColorArray([c0, c0, c1, c1]))
		var edge_y := r.end.y if from_top else r.position.y
		draw_rect(Rect2(inner.position.x - 4.0, edge_y - 3.0, inner.size.x + 8.0, 6.0), get_theme_color(&"brass_light", &"Game"))
	if locked:
		draw_style_box(track, Rect2(Vector2.ZERO, size))
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.5))
	var font := get_theme_default_font()
	draw_string(font, Vector2(0, size.y + 20), caption, HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, get_theme_color(&"muted", &"Game"))
