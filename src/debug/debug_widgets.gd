class_name DebugWidgets
extends RefCounted

## Touch-sized controls for the debug panel (finger targets of 56 px, like Settings). Every builder returns the control
## and adds it to `parent`.

const ROW_H := 56.0
const FONT := 22  ## buttons: three to a row must fit a 540 px drawer


static func button(parent: Control, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, ROW_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	b.add_theme_font_size_override(&"font_size", FONT)
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


static func toggle(parent: Control, text: String, on: bool, on_toggle: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.custom_minimum_size = Vector2(0.0, ROW_H)
	c.toggled.connect(on_toggle)
	parent.add_child(c)
	return c


static func label(parent: Control, text: String, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(120.0, 0.0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(l)
	return l


static func row(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override(&"separation", 8)
	parent.add_child(h)
	return h


## A header button that folds its body away; the body is returned.
static func section(parent: Control, title: String, open := true) -> VBoxContainer:
	var head := Button.new()
	head.toggle_mode = true
	head.button_pressed = open
	head.custom_minimum_size = Vector2(0.0, ROW_H)
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.clip_text = true
	head.add_theme_font_size_override(&"font_size", FONT)
	parent.add_child(head)
	var body := VBoxContainer.new()
	body.visible = open
	body.add_theme_constant_override(&"separation", 6)
	parent.add_child(body)
	var sync := func() -> void:
		head.text = ("▼  " if head.button_pressed else "▶  ") + title
		body.visible = head.button_pressed
	head.toggled.connect(func(_on: bool) -> void: sync.call())
	sync.call()
	return body


## Title + value, then [−] slider [+]. `on_change(value: float)` runs for every move. The slider carries its value label
## and format in meta so `put()` can refresh it from outside without firing `on_change`.
static func slider(parent: Control, title: String, lo: float, hi: float, step: float, value: float, on_change: Callable) -> HSlider:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	parent.add_child(box)
	var head := row(box)
	var name_l := label(head, title)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value_l := label(head, "")
	value_l.custom_minimum_size = Vector2(110.0, 0.0)
	value_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var line := row(box)
	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(ROW_H, ROW_H)
	line.add_child(minus)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(0.0, 52.0)
	line.add_child(s)
	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(ROW_H, ROW_H)
	line.add_child(plus)
	s.set_meta(&"value_label", value_l)
	s.set_meta(&"decimals", _decimals(step))
	s.value_changed.connect(func(v: float) -> void:
		_show(s, v)
		on_change.call(v))
	minus.pressed.connect(func() -> void: s.value -= s.step)
	plus.pressed.connect(func() -> void: s.value += s.step)
	put(s, value)
	return s


## Moves a slider to `v` and refreshes its label, without calling the change handler.
static func put(s: HSlider, v: float) -> void:
	s.set_value_no_signal(v)
	_show(s, v)


static func _show(s: HSlider, v: float) -> void:
	(s.get_meta(&"value_label") as Label).text = String.num(v, int(s.get_meta(&"decimals")))


static func _decimals(step: float) -> int:
	var d := 0
	var x := step
	while d < 5 and not is_equal_approx(x, roundf(x)):
		x *= 10.0
		d += 1
	return maxi(d, 1) if step < 1.0 else 0
