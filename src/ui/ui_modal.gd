class_name UIModal
extends Control
## Base of every modal screen (docs/plan/06 P12, contract §1): a full-rect, input-stopping Control in group
## `ui_modal` with a dim backdrop. `visible` IS the open state; UIRouter watches it, keeps at most one modal open and
## owns the mouse. Subclasses build their panel and refresh in `_on_open()`. Duck-typed screens (open / close /
## is_open, no base class) work with the router too.

signal dismissed  ## close() was called, even while the router has this screen suspended under a higher one

@export var keep_on_phase := false  ## stay open across GameLoop.phase_changed (Pause, Settings, the phase screen itself)
@export var priority := 0  ## a lower-priority screen never displaces a higher one, it waits and returns when that closes
@export var dismissable := true  ## Esc closes it; false = Esc opens Pause over it instead
@export var dim := true


func _init() -> void:
	add_to_group(&"ui_modal")  # in _init so UIRouter's node_added scan sees it
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _ready() -> void:
	if dim:
		var shade := ColorRect.new()
		shade.color = Color(0.02, 0.01, 0.01, 0.68)
		shade.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(shade)
		move_child(shade, 0)
	visibility_changed.connect(_on_visibility)


func open() -> void:
	visible = true


func close() -> void:
	visible = false
	dismissed.emit()


func is_open() -> bool:
	return visible


## Esc / Back: the router calls this instead of close() when a screen defines it.
func go_back() -> void:
	close()


func _on_visibility() -> void:
	if visible:
		_on_open()
	else:
		_on_close()


func _on_open() -> void:
	pass


func _on_close() -> void:
	pass
