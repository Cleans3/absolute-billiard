class_name TouchButton
extends Control
## Multi-touch-safe button: fires on finger-down by index, so a held stick never eats the tap
## (BaseButton only follows the emulated mouse, i.e. the first finger).

signal pressed

var text := "":
	set(v):
		if v != text:
			text = v
			queue_redraw()
var selected := false:
	set(v):
		if v != selected:
			selected = v
			queue_redraw()


func _init() -> void:
	custom_minimum_size = Vector2(72, 72)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		accept_event()
		pressed.emit()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.9, 0.7, 0.2, 0.6) if selected else Color(0, 0, 0, 0.45))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.5), false, 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(0, size.y * 0.5 + 8), text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 22)
