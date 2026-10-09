class_name ElevationPad
extends Control
## Small cue-angle control (08 §2.3): a side-view mini cue and the angle the shot will use. A tap opens ElevationOverlay.
## `value` is the requested angle (0..`MAX_DEG`), `cap` the highest angle the cue allows right now (locked Jump / Masse,
## `Ball.effective_elevation`), so `effective()` is what the ball gets. Same names as the old slider: `set_value`, `changed`.

signal changed(value: float)
signal opened  ## a tap
signal state_changed  ## value or cap moved: the overlay redraws

const MAX_DEG := 80.0
const TAP_SLOP := 14.0

var value := 0.0
var cap := MAX_DEG
var _finger := -1
var _down_at := Vector2.ZERO


func _init() -> void:
	custom_minimum_size = Vector2(120, 72)


func effective() -> float:
	return minf(value, cap)


func set_value(v: float) -> void:
	v = clampf(v, 0.0, MAX_DEG)
	if v != value:
		value = v
		queue_redraw()
		state_changed.emit()


func set_cap(v: float) -> void:
	v = clampf(v, 0.0, MAX_DEG)
	if v != cap:
		cap = v
		queue_redraw()
		state_changed.emit()


## From the overlay: the finger moved the angle.
func pick(deg: float) -> void:
	deg = clampf(deg, 0.0, MAX_DEG)
	if deg != value:
		set_value(deg)
		changed.emit(deg)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			_finger = event.index
			_down_at = event.position
			accept_event()
		elif not event.pressed and event.index == _finger:
			_finger = -1
			if event.position.distance_to(_down_at) <= TAP_SLOP:
				opened.emit()
			accept_event()
	elif event is InputEventScreenDrag and event.index == _finger:
		accept_event()


func _draw() -> void:
	draw_style_box(get_theme_stylebox(&"panel", &"PanelInset"), Rect2(Vector2.ZERO, size))
	var brass := get_theme_color(&"brass_light", &"Game")
	var capped := effective() < value - 0.01
	var ball := Vector2(size.x - 30.0, size.y - 24.0)
	draw_circle(ball, 11.0, get_theme_color(&"cream", &"Game"))
	var d := Vector2(-cos(deg_to_rad(effective())), -sin(deg_to_rad(effective())))
	draw_line(ball + d * 14.0, ball + d * 78.0, brass, 5.0)
	var font := get_theme_default_font()
	var col := get_theme_color(&"pink" if capped else &"cream", &"Game")
	draw_string(font, Vector2(10.0, 30.0), "%d°" % roundi(effective()), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 28, col)
	var m := 6.0  # the corner brackets that say "tap me", as on SpinPad
	var l := 10.0
	var p := Vector2(size.x - m, m)
	draw_line(p, p + Vector2(-l, 0.0), brass, 2.0)
	draw_line(p, p + Vector2(0.0, l), brass, 2.0)
