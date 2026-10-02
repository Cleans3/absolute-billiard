class_name TouchButton
extends Control
## Multi-touch-safe button: fires on finger-down by index, so a held stick never eats the tap
## (BaseButton only follows the emulated mouse, i.e. the first finger). Drawn from the project sprites + theme font.

signal pressed

const SPRITE := preload("res://assets/ui/touch_btn.svg")
const SPRITE_SELECTED := preload("res://assets/ui/touch_btn_sel.svg")

var text := "":
	set(v):
		if v != text:
			text = v
			queue_redraw()
var icon: Texture2D:
	set(v):
		icon = v
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
	draw_texture_rect(SPRITE_SELECTED if selected else SPRITE, Rect2(Vector2.ZERO, size), false)
	if icon != null:
		var s := size * 0.5
		draw_texture_rect(icon, Rect2((size - s) * 0.5, s), false)
	if text != "":
		var font := get_theme_default_font()
		var fs := 30 if text.length() == 1 else 22
		var w := size.x * 0.78
		var box := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, w, fs, 3)
		var ascent := font.get_ascent(fs)
		draw_multiline_string(font, Vector2((size.x - w) * 0.5, (size.y - box.y) * 0.5 + ascent), text, HORIZONTAL_ALIGNMENT_CENTER, w, fs, 3, get_theme_color(&"cream", &"Game"))
