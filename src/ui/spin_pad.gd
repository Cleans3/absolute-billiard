class_name SpinPad
extends SpinDisc
## Touch cue-ball face (08 §2.3). Two jobs, one class: the small corner control (`pick` false) only shows the hit point and a
## tap opens the enlarged one; the enlarged face (`pick` true, inside SpinOverlay) sets the point by tap or drag.
## Emits `changed`; the CueController owns the value and pushes it back with `set_spin`.

signal changed(spin: Vector2)
signal opened  ## a tap on the small control
signal value_set  ## `set_spin` moved the dot: the overlay redraws

const TAP_SLOP := 14.0  ## px a finger may travel and still be a tap

@export var pick := false

var _finger := -1
var _down_at := Vector2.ZERO


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			_finger = event.index
			_down_at = event.position
			if pick:
				_emit_at(event.position)
			accept_event()
		elif not event.pressed and event.index == _finger:
			_finger = -1
			if not pick and event.position.distance_to(_down_at) <= TAP_SLOP:
				opened.emit()
			accept_event()
	elif event is InputEventScreenDrag and event.index == _finger:
		if pick:
			_emit_at(event.position)
		accept_event()


func _draw() -> void:
	super()
	if not pick:  # the corner mark that says "tap me": four brackets round the disc
		var m := 6.0
		var l := 12.0
		var col := get_theme_color(&"brass_light", &"Game")
		for sx in [0.0, 1.0]:
			for sy in [0.0, 1.0]:
				var p := Vector2(size.x * sx, size.y * sy) + Vector2(m if sx == 0.0 else -m, m if sy == 0.0 else -m)
				draw_line(p, p + Vector2(l if sx == 0.0 else -l, 0.0), col, 2.0)
				draw_line(p, p + Vector2(0.0, l if sy == 0.0 else -l), col, 2.0)


func set_spin(v: Vector2) -> void:
	if v != spin:
		spin = v
		queue_redraw()
		value_set.emit()


func _emit_at(pos: Vector2) -> void:
	var c := size * 0.5
	var r := minf(c.x, c.y) - 2.0
	var v := (pos - c) / r
	changed.emit(Vector2(v.x, -v.y).limit_length(1.0))
