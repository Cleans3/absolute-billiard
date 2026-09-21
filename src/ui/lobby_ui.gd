extends Control
## Boot screen (docs/plan/04 §4). Solo = host with zero peers; same NetManager.host() path as M2's Host.

@onready var _solo: Button = %Solo


func _ready() -> void:
	_solo.pressed.connect(_on_solo_pressed)
	_solo.grab_focus()


func _on_solo_pressed() -> void:
	_solo.disabled = true
	NetManager.host()
