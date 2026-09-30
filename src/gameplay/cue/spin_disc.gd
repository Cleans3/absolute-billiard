class_name SpinDisc
extends Control

## Cue-ball face: dot = tip contact point, red ring = miscue threshold, label = elevation.

var spin := Vector2.ZERO
var elevation_deg := 0.0
var miscue := 0.92


func _draw() -> void:
	var c := size * 0.5
	var r := minf(c.x, c.y) - 2.0
	draw_circle(c, r, Color(1, 1, 1, 0.85))
	draw_arc(c, r * miscue, 0.0, TAU, 48, Color(0.9, 0.2, 0.2, 0.7), 1.5)
	draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(0, 0, 0, 0.25))
	draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(0, 0, 0, 0.25))
	draw_circle(c + Vector2(spin.x, -spin.y) * r, 4.0, Color(0.1, 0.3, 0.9))
	draw_string(ThemeDB.fallback_font, Vector2(0, size.y + 14), "elev %d°" % roundi(elevation_deg), HORIZONTAL_ALIGNMENT_CENTER, size.x, 12)
