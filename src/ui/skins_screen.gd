class_name SkinsScreen
extends UIModal
## Placeholder (docs/plan/06 P18): the character / bar skin picker lands in a later slice.

@onready var _back: Button = %Back


func _ready() -> void:
	super()
	keep_on_phase = true
	priority = 60
	_back.pressed.connect(close)


func _on_open() -> void:
	_back.grab_focus()
