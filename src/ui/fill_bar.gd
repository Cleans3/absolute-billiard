class_name FillBar
extends Control
## A thin progress bar drawn from the theme's `Game` palette: `value` 0..1, cyan while filling, green once full.
## Used by the HUD's Cash vs Quota group and by the blackboard's hype line.

const HEIGHT := 8.0

var value := 0.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if not is_equal_approx(v, value):
			value = v
			queue_redraw()

var _box := StyleBoxFlat.new()


func _init() -> void:
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.set_corner_radius_all(int(HEIGHT * 0.5))


func _draw() -> void:
	_box.bg_color = get_theme_color(&"ink", &"Game")
	draw_style_box(_box, Rect2(Vector2.ZERO, size))
	if value > 0.0:
		_box.bg_color = get_theme_color(&"green" if value >= 1.0 else &"cyan", &"Game")
		draw_style_box(_box, Rect2(Vector2.ZERO, Vector2(maxf(size.x * value, HEIGHT), size.y)))
