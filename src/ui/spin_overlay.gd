class_name SpinOverlay
extends Control
## The enlarged cue ball (08 §2.3): about 60% of the screen height, tap or drag sets the hit point, Reset centres it, OK or a
## tap outside the card closes it. It owns no value: it reads the small pad's, and every pick goes out through the pad's
## `changed` (the Player wires that to CueController.set_spin). The card starts below the HUD and the shot clock, which stay visible.

const CARD_TOP := 108.0  ## clear of the HUD bar (y < 64) and the shot clock (y 64-104)
const FACE_FRAC := 0.6  ## of the screen height
const CARD_HALF_W_FRAC := 0.55  ## of the screen height
const MASSE_SPIN := 0.60  ## Ball.MASSE_MIN_SPIN, named in the caption

var pad: SpinPad  ## the small control this one enlarges
var face: SpinPad  ## the picking face
var _card := Rect2()
var _readout: Label
var _reset: Button
var _ok: Button


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	face = SpinPad.new()
	face.pick = true
	face.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(face)
	_readout = Label.new()
	_readout.theme_type_variation = &"HudLabel"
	_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_readout)
	_reset = _button("Reset", &"")
	_ok = _button("OK", &"PrimaryButton")
	_ok.pressed.connect(close)
	resized.connect(_layout)


## `small` is the corner control; its value, miscue ring and `changed` are this overlay's too.
func bind(small: SpinPad) -> void:
	pad = small
	pad.value_set.connect(_sync)
	face.changed.connect(_pick)
	_reset.pressed.connect(_pick.bind(Vector2.ZERO))


## Out through the small pad's `changed`, then echoed into it so the dot moves before the cue pushes the value back.
func _pick(v: Vector2) -> void:
	pad.changed.emit(v)
	pad.set_spin(v)


func open() -> void:
	_sync()
	_layout()
	show()


func close() -> void:
	hide()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed and not _card.has_point(event.position):
		close()
	accept_event()  # nothing under the overlay sees a touch while it is open


func _sync() -> void:
	if pad == null:
		return
	face.spin = pad.spin
	face.miscue = pad.miscue
	face.queue_redraw()
	_readout.text = describe(pad.spin, pad.miscue)
	queue_redraw()


## "Follow 40% · Right 25%"; the miscue and hard-English warnings ride on the end.
static func describe(spin: Vector2, miscue: float) -> String:
	if spin.length() < 0.02:
		return "Centre ball"
	var parts: Array[String] = []
	if absf(spin.y) >= 0.02:
		parts.append("%s %d%%" % ["Follow" if spin.y > 0.0 else "Draw", roundi(absf(spin.y) * 100.0)])
	if absf(spin.x) >= 0.02:
		parts.append("%s %d%%" % ["Right" if spin.x > 0.0 else "Left", roundi(absf(spin.x) * 100.0)])
	var text := " · ".join(parts)
	if spin.length() > miscue:
		text += "   MISCUE"
	elif spin.length() >= MASSE_SPIN:
		text += "   hard English"
	return text


func _layout() -> void:
	var h := size.y
	var half_w := h * CARD_HALF_W_FRAC
	_card = Rect2(size.x * 0.5 - half_w, CARD_TOP, half_w * 2.0, h - CARD_TOP - 24.0)
	var side := h * FACE_FRAC
	face.size = Vector2(side, side)
	face.position = Vector2(size.x * 0.5 - side * 0.5, _card.position.y + 8.0)
	_readout.position = Vector2(_card.position.x, face.position.y + side + 4.0)
	_readout.size = Vector2(_card.size.x, 36.0)
	var bw := 190.0
	var bh := 72.0
	var by := _card.end.y - bh - 12.0
	_reset.position = Vector2(size.x * 0.5 - bw - 16.0, by)
	_reset.size = Vector2(bw, bh)
	_ok.position = Vector2(size.x * 0.5 + 16.0, by)
	_ok.size = Vector2(bw, bh)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.6))
	draw_style_box(get_theme_stylebox(&"panel", &"PanelContainer"), _card)


func _button(text: String, variation: StringName) -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	add_child(b)
	return b
