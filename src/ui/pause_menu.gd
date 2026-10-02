class_name PauseMenu
extends UIModal
## Esc / touch pause button (docs/plan/06 P11): Resume, Settings, Controls, Leave. It blocks local input only; the
## simulation and the other peers keep running. Settings and Controls open over it and hand back when closed.

const CONFIRM_SEC := 3.0

var _confirm: SceneTreeTimer

@onready var _resume: Button = %Resume
@onready var _leave: Button = %Leave


func _init() -> void:
	super()
	add_to_group(&"ui_pause")


func _ready() -> void:
	super()
	keep_on_phase = true
	priority = 50
	_resume.pressed.connect(close)
	%Settings.pressed.connect(_open_group.bind(&"ui_settings"))
	%Controls.pressed.connect(_open_group.bind(&"ui_controls"))
	%Controls.visible = not OS.has_feature("mobile")  # no keyboard to rebind on a phone
	_leave.pressed.connect(_on_leave)


func _on_open() -> void:
	_leave.text = "Leave to menu"
	_confirm = null
	_resume.grab_focus()


## Hosts end the session for everyone: ask twice, so a stray tap on a phone does not.
func _on_leave() -> void:
	var net := get_node_or_null(^"/root/NetManager")
	if net == null:
		return
	if bool(net.call(&"is_host")) and _confirm == null and (net.call(&"get_roster") as Array).size() > 1:
		_leave.text = "Tap again to end the session"
		_confirm = get_tree().create_timer(CONFIRM_SEC)
		_confirm.timeout.connect(func() -> void:
			_confirm = null
			_leave.text = "Leave to menu")
		return
	net.call(&"leave")


func _open_group(group: StringName) -> void:
	var m := get_tree().get_first_node_in_group(group)
	if m != null:
		m.call(&"open")
