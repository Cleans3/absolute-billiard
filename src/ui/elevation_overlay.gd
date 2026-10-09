class_name ElevationOverlay
extends Control
## The enlarged cue-angle control (08 §2.3): a side view of the cue ball with a protractor, 0-80 degrees, drag anywhere
## round the ball to set the angle in whole degrees, +/- 1 for the last bit. Jump (30) and Masse (45) are marked; a range the cue
## cannot use right now is shaded and the cue it really gets is drawn bright over the one asked for. It owns no value: it
## reads the small ElevationPad and every pick goes out through the pad's `changed`.

const CARD_HALF_W_FRAC := 0.8  ## of the screen height
const RADIUS_FRAC := 0.58
const BALL_FRAC := 0.07
const TICK_STEP := 10

var pad: ElevationPad
var _card := Rect2()
var _pivot := Vector2.ZERO
var _radius := 0.0
var _finger := -1
var _title: Label
var _readout: Label
var _reason: Label
var _plus: TouchButton
var _minus: TouchButton
var _reset: TouchButton
var _ok: TouchButton


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_title = _label(&"Heading")
	_title.text = "Cue angle"
	_readout = _label(&"HudLabel")
	_reason = _label(&"HudDanger")
	_plus = _button("+1°")
	_minus = _button("-1°")
	_reset = _button("Reset")
	_ok = _button("OK")
	_ok.pressed.connect(close)
	resized.connect(_layout)


func bind(small: ElevationPad) -> void:
	pad = small
	pad.state_changed.connect(_sync)
	_plus.pressed.connect(func() -> void: pad.pick(pad.value + 1.0))
	_minus.pressed.connect(func() -> void: pad.pick(pad.value - 1.0))
	_reset.pressed.connect(func() -> void: pad.pick(0.0))


func open() -> void:
	_finger = -1
	_sync()
	_layout()
	show()


func close() -> void:
	_finger = -1
	hide()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1:
			if not _card.has_point(event.position):
				close()
			elif _on_protractor(event.position):
				_finger = event.index
				_pick_at(event.position)
		elif not event.pressed and event.index == _finger:
			_finger = -1
	elif event is InputEventScreenDrag and event.index == _finger:
		_pick_at(event.position)
	accept_event()  # nothing under the overlay sees a touch while it is open


## Angle for a finger at `pos`: the cue comes in from the left, so 0 is level with the ball and 80 nearly overhead.
func angle_at(pos: Vector2) -> float:
	var v := _pivot - pos
	var deg := rad_to_deg(atan2(v.y, v.x))  # v.y > 0: the finger is above the ball
	if deg > 90.0:  # over or right of the ball: as steep as it goes
		return ElevationPad.MAX_DEG
	return roundf(clampf(deg, 0.0, ElevationPad.MAX_DEG))


func _on_protractor(pos: Vector2) -> bool:
	return pos.x <= _pivot.x + size.y * BALL_FRAC and pos.distance_to(_pivot) <= _radius + 60.0


func _pick_at(pos: Vector2) -> void:
	pad.pick(angle_at(pos))


func _sync() -> void:
	if pad == null:
		return
	_readout.text = "%d°" % roundi(pad.value)
	_reason.text = reason(pad.cap)
	if pad.effective() < pad.value - 0.01:
		_readout.text += "   shot uses %d°" % roundi(pad.effective())
	queue_redraw()


## Why the top of the range is shut, or "" when it is open.
static func reason(cap: float) -> String:
	if cap >= ElevationPad.MAX_DEG:
		return ""
	if cap < Ball.JUMP_MIN_ELEVATION_DEG:
		return "Jump shots are locked: the cue stops at %d°" % roundi(cap)
	return "Masse is locked: hard English (%d%%+) stops the cue at %d°" % [roundi(Ball.MASSE_MIN_SPIN * 100.0), roundi(cap)]


func _layout() -> void:
	var h := size.y
	var half_w := minf(h * CARD_HALF_W_FRAC, size.x * 0.5 - 16.0)
	_card = Rect2(size.x * 0.5 - half_w, h * 0.05, half_w * 2.0, h * 0.9)
	_radius = h * RADIUS_FRAC
	_pivot = Vector2(_card.position.x + 36.0 + _radius, _card.end.y - h * 0.2)
	_title.position = _card.position + Vector2(0.0, 8.0)
	_title.size = Vector2(_card.size.x, 44.0)
	_readout.position = _title.position + Vector2(0.0, 50.0)
	_readout.size = Vector2(_card.size.x, 34.0)
	_reason.position = _readout.position + Vector2(0.0, 36.0)
	_reason.size = Vector2(_card.size.x, 34.0)
	var col_x := _pivot.x + h * BALL_FRAC + 40.0
	var col_w := _card.end.x - col_x - 24.0
	var bh := 72.0
	var gap := 14.0
	var y := _card.position.y + h * 0.3
	_minus.position = Vector2(col_x, y)
	_minus.size = Vector2((col_w - gap) * 0.5, bh)
	_plus.position = Vector2(col_x + (col_w + gap) * 0.5, y)
	_plus.size = _minus.size
	_reset.position = Vector2(col_x, y + bh + gap)
	_reset.size = Vector2(col_w, bh)
	_ok.position = Vector2(col_x, y + (bh + gap) * 2.0)
	_ok.size = Vector2(col_w, bh)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.6))
	draw_style_box(get_theme_stylebox(&"panel", &"PanelContainer"), _card)
	if pad == null:
		return
	var cyan := get_theme_color(&"cyan", &"Game")
	var pink := get_theme_color(&"pink", &"Game")
	var brass := get_theme_color(&"brass_light", &"Game")
	var cream := get_theme_color(&"cream", &"Game")
	var font := get_theme_default_font()
	var band := 22.0
	var cap := pad.cap
	# the usable range, then the shut one
	draw_arc(_pivot, _radius, _a(0.0), _a(cap), 48, Color(cyan, 0.4), band)
	if cap < ElevationPad.MAX_DEG:
		draw_arc(_pivot, _radius, _a(cap), _a(ElevationPad.MAX_DEG), 32, Color(pink, 0.45), band)
	# the table plane through the ball, ticks and the two thresholds
	draw_line(_pivot - Vector2(_radius + 40.0, 0.0), _pivot, Color(cream, 0.35), 2.0)
	for deg in range(0, int(ElevationPad.MAX_DEG) + 1, TICK_STEP):
		var d := _dir(deg)
		draw_line(_pivot + d * (_radius - band * 0.5 - 8.0), _pivot + d * (_radius + band * 0.5 + 6.0), Color(cream, 0.7), 2.0)
		draw_string(font, _pivot + d * (_radius + band * 0.5 + 34.0) - Vector2(14.0, -8.0), str(deg), HORIZONTAL_ALIGNMENT_CENTER, 28.0, 22, Color(cream, 0.8))
	for mark: Array in [[Ball.JUMP_MIN_ELEVATION_DEG, "Jump"], [Ball.MASSE_MIN_ELEVATION_DEG, "Masse"]]:
		var d := _dir(mark[0])
		draw_line(_pivot + d * (_radius - band - 12.0), _pivot + d * (_radius + band * 0.5 + 10.0), brass, 4.0)
		draw_string(font, _pivot + d * (_radius - band - 20.0) - Vector2(46.0, 0.0), mark[1], HORIZONTAL_ALIGNMENT_CENTER, 92.0, 22, brass)
	# the ball, then the cue: what was asked (ghost) and what the shot gets (bright)
	var br := size.y * BALL_FRAC
	draw_circle(_pivot, br, Color(cream, 0.95))
	draw_arc(_pivot, br, 0.0, TAU, 48, get_theme_color(&"brass", &"Game"), 3.0)
	var eff := pad.effective()
	if eff < pad.value - 0.01:
		_cue(pad.value, br, Color(cream, 0.3))
	_cue(eff, br, brass)
	draw_arc(_pivot, br + 18.0, _a(0.0), _a(eff), 24, brass, 3.0)


func _cue(deg: float, ball_radius: float, col: Color) -> void:
	var d := _dir(deg)
	var tip := _pivot + d * (ball_radius + 6.0)
	var butt := _pivot + d * (_radius + 4.0)
	draw_line(tip, butt, Color(0.04, 0.02, 0.01, 0.9), 15.0)
	draw_line(tip, butt, col, 10.0)


## Unit vector from the ball towards the cue butt at `deg` above level (left and up on screen).
static func _dir(deg: float) -> Vector2:
	return Vector2(-cos(deg_to_rad(deg)), -sin(deg_to_rad(deg)))


## draw_arc angle for `deg` (the screen angle of `_dir`).
static func _a(deg: float) -> float:
	return PI + deg_to_rad(deg)


func _label(variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _button(text: String) -> TouchButton:
	var b := TouchButton.new()
	b.text = text
	add_child(b)
	return b
