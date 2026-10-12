class_name SettingsScreen
extends UIModal
## Settings (docs/plan/06 P11): rows are built from `Settings.RANGES` / `QUALITY`, applied live and saved when a change is
## final (slider released, toggle, screen closed). From the main menu or from Pause.

var _widgets := {}  # key -> Control, so a reset can push the stored values back

@onready var _tabs: TabContainer = %Tabs
@onready var _back: Button = %Back


func _init() -> void:
	super()
	add_to_group(&"ui_settings")


func _ready() -> void:
	super()
	keep_on_phase = true
	priority = 60
	var video := _page("Video & Audio")
	_slider(video, "Master volume", &"master_volume", func(v: float) -> String: return "%d%%" % roundi(v * 100.0))
	_quality(video)
	_slider(video, "Field of view", &"fov", func(v: float) -> String: return "%d°" % roundi(v))
	_check(video, "Show FPS", &"show_fps")
	if OS.is_debug_build():
		_check(video, "Debug mode (physics, replay, table)", &"debug_mode")
	var input := _page("Input")
	var times := func(v: float) -> String: return "%.2fx" % v
	_slider(input, "Mouse sensitivity", &"mouse_sens", times)
	_slider(input, "Touch look sensitivity", &"touch_look_sens", times)
	_slider(input, "Cue aim sensitivity", &"cue_aim_sens", times)
	_check(input, "Invert look Y", &"invert_y")
	_check(input, "Left-handed touch layout (mirror)", &"touch_mirror")
	_back.pressed.connect(close)
	%Reset.pressed.connect(func() -> void:
		Settings.reset_values()
		Settings.save()
		_sync())


func _on_open() -> void:
	_sync()
	_back.grab_focus()


func _on_close() -> void:
	Settings.save()


func _page(title: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = title
	_tabs.add_child(page)
	return page


func _row(page: Control, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(300, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	page.add_child(row)
	return row


func _slider(page: Control, label: String, key: StringName, fmt: Callable) -> void:
	var row := _row(page, label)
	var r: Array = Settings.RANGES[key]
	var s := HSlider.new()
	s.min_value = r[0]
	s.max_value = r[1]
	s.step = r[2]
	s.custom_minimum_size = Vector2(0, 52)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var shown := Label.new()
	shown.custom_minimum_size = Vector2(96, 0)
	shown.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(s)
	row.add_child(shown)
	s.value_changed.connect(func(v: float) -> void:
		Settings.set_value(key, v)
		shown.text = fmt.call(v))
	s.drag_ended.connect(func(_changed: bool) -> void: Settings.save())
	_widgets[key] = [s, shown, fmt]


func _check(page: Control, label: String, key: StringName) -> void:
	var c := CheckBox.new()
	c.text = label
	c.custom_minimum_size = Vector2(0, 56)
	c.toggled.connect(func(on: bool) -> void:
		Settings.set_value(key, on)
		Settings.save())
	page.add_child(c)
	_widgets[key] = [c]


func _quality(page: Control) -> void:
	var row := _row(page, "Graphics")
	var group := ButtonGroup.new()
	var buttons: Array[Button] = []
	for q in Settings.QUALITY:
		var b := Button.new()
		b.text = String(q).capitalize()
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			Settings.set_value(&"quality", q)
			Settings.save())
		row.add_child(b)
		buttons.append(b)
	_widgets[&"quality"] = buttons


func _sync() -> void:
	for key: StringName in _widgets:
		var w: Array = _widgets[key]
		var v: Variant = Settings.value(key)
		if key == &"quality":
			for i in w.size():
				(w[i] as Button).set_pressed_no_signal(Settings.QUALITY[i] == v)
		elif w[0] is HSlider:
			(w[0] as HSlider).set_value_no_signal(v)
			(w[1] as Label).text = (w[2] as Callable).call(v)
		else:
			(w[0] as CheckBox).set_pressed_no_signal(v)
