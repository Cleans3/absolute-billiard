class_name SpinDisc
extends Control

## Cue-ball face: dot = tip contact point, red ring = miscue threshold. Scales with its size, so the small
## corner control and the enlarged overlay share it.

var spin := Vector2.ZERO
var miscue := 0.92


func _draw() -> void:
	var c := size * 0.5
	var r := minf(c.x, c.y) - 2.0  # SpinPad's hit test uses the same radius
	var brass := get_theme_color(&"brass", &"Game")
	var ink := get_theme_color(&"ink", &"Game")
	draw_circle(c, r, Color(0.04, 0.02, 0.01, 0.85))
	draw_circle(c, r - 3.0, Color(0.96, 0.92, 0.82, 0.95))
	draw_arc(c, r - 1.5, 0.0, TAU, 48, brass, 3.0)
	draw_arc(c, r * 0.5, 0.0, TAU, 48, Color(0, 0, 0, 0.12), 1.0)
	draw_arc(c, r * miscue, 0.0, TAU, 48, Color(0.9, 0.2, 0.2, 0.7), 1.5)
	draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(0, 0, 0, 0.25))
	draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(0, 0, 0, 0.25))
	var dot := c + Vector2(spin.x, -spin.y) * r
	var dr := maxf(6.0, r * 0.045)
	draw_circle(dot, dr + 2.0, ink)
	draw_circle(dot, dr, get_theme_color(&"pink", &"Game"))
