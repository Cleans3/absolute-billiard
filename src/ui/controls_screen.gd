class_name ControlsScreen
extends UIModal
## Controls (docs/plan/06 P11): every keyboard / mouse gameplay action, click-to-rebind. A key or mouse button that
## another action holds is swapped between the two (Settings.rebind); the swap is named in the status line.

const HINT := "Click a binding, then press a key or mouse button. Esc cancels."

var _buttons := {}  # action -> Button
var _listening := &""

@onready var _list: VBoxContainer = %List
@onready var _status: Label = %Status
@onready var _back: Button = %Back


func _init() -> void:
	super()
	add_to_group(&"ui_controls")


func _ready() -> void:
	super()
	keep_on_phase = true
	priority = 60
	var group := ""
	var grid: GridContainer
	for entry in Settings.ACTIONS:
		if entry.group != group:
			group = entry.group
			var h := Label.new()
			h.text = group
			h.theme_type_variation = &"Heading"
			_list.add_child(h)
			grid = GridContainer.new()
			grid.columns = 4
			_list.add_child(grid)
		var l := Label.new()
		l.text = entry.label
		l.custom_minimum_size = Vector2(190, 0)
		l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(l)
		var b := Button.new()
		b.custom_minimum_size = Vector2(200, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_listen.bind(entry.action))
		grid.add_child(b)
		_buttons[entry.action] = b
	_back.pressed.connect(go_back)
	%Reset.pressed.connect(func() -> void:
		Settings.reset_bindings()
		Settings.save()
		_cancel_listen()
		_status.text = "Back to the defaults."
		_refresh())
	_refresh()


func _on_open() -> void:
	_cancel_listen()
	_refresh()
	_back.grab_focus()


func _on_close() -> void:
	_cancel_listen()


func go_back() -> void:
	if _listening != &"":
		_cancel_listen()
	else:
		close()


func _input(event: InputEvent) -> void:
	if _listening == &"" or not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE:
			_cancel_listen()
		else:
			_bind(event)
	elif event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()
		_bind(event)


func _listen(action: StringName) -> void:
	_cancel_listen()
	_listening = action
	_buttons[action].text = "Press a key…"
	_status.text = HINT


func _bind(event: InputEvent) -> void:
	var action := _listening
	var clash := Settings.rebind(action, event)
	_listening = &""
	Settings.save()
	_status.text = HINT if clash == &"" else "%s now has %s's old binding." % [_label_of(clash), _label_of(action)]
	_refresh()


func _cancel_listen() -> void:
	if _listening != &"":
		_listening = &""
		_refresh()


func _refresh() -> void:
	for action: StringName in _buttons:
		(_buttons[action] as Button).text = Settings.binding_text(action)


func _label_of(action: StringName) -> String:
	for entry in Settings.ACTIONS:
		if entry.action == action:
			return entry.label
	return String(action)
