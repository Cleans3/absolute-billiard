class_name UIRouter
extends Control
## Owns every modal screen (docs/plan/06 P12, contract §1). Modals are Controls in group `ui_modal` (UIModal or any
## Control with open / close / is_open); the router watches their `visible`. At most one is open: a screen of equal or
## higher `priority` displaces the open one (which waits on a stack and returns when the newcomer closes), an equal one
## replaces it, a lower one is held back. A phase change closes every modal that is not `keep_on_phase`. It owns the mouse mode, the
## single toast line and Esc (closes the top screen, or opens Pause over one that cannot be dismissed).

signal modal_changed(open: bool)

const TOAST_SEC := 2.6
const TOAST_REGION := Rect2(-300.0, 108.0, 600.0, 44.0)  ## x from screen centre; the one fixed toast slot (docs 08 §2.7)

## The router of the running scene: Player / CueController gate input through `UIRouter.blocking()`.
static var instance: UIRouter

@export var game_loop: GameLoop
@export var capture_mouse := false  ## in-game: the mouse is captured while no modal is open (desktop only)

var current: Control
var _stack: Array[Control] = []
var _watched := {}
var _busy := false
var _toast_label: Label
var _toast_timer: Timer


func _init() -> void:
	add_to_group(&"ui_router")
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _enter_tree() -> void:
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _ready() -> void:
	_toast_label = Label.new()
	_toast_label.anchor_left = 0.5
	_toast_label.anchor_right = 0.5
	_toast_label.offset_left = TOAST_REGION.position.x
	_toast_label.offset_right = TOAST_REGION.end.x
	_toast_label.offset_top = TOAST_REGION.position.y
	_toast_label.offset_bottom = TOAST_REGION.end.y
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast_label.clip_text = true
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_label.hide()
	add_child(_toast_label)
	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(_toast_label.hide)
	add_child(_toast_timer)
	if game_loop != null:
		game_loop.phase_changed.connect(_on_phase)
	get_tree().node_added.connect(_on_node_added)
	_scan.call_deferred()  # every level node has run _ready by then
	_update_mouse()


static func blocking() -> bool:
	return instance != null and instance.is_modal_open()


func is_modal_open() -> bool:
	return current != null and is_instance_valid(current) and current.visible


## Info / good / bad: one line, newest wins. Not shown while a modal is open (it would sit under the dim).
func toast(text: String, kind: StringName = &"info") -> void:
	if is_modal_open():
		return
	_toast_label.theme_type_variation = &"Toast" + String(kind).capitalize()
	_toast_label.text = text
	_toast_label.show()
	_toast_timer.start(TOAST_SEC)


func open_pause() -> void:
	var pause := get_tree().get_first_node_in_group(&"ui_pause")
	if pause != null:
		pause.call(&"open")


## Esc / Back: close the top screen, or open Pause when there is none or it cannot be dismissed.
func escape() -> void:
	if is_modal_open() and _flag(current, &"dismissable", true):
		current.call(&"go_back" if current.has_method(&"go_back") else &"close")
	else:
		open_pause()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		escape()


func _on_phase(_phase: int) -> void:
	for m in _stack.duplicate():
		if not _flag(m, &"keep_on_phase", false):
			_stack.erase(m)
	if is_modal_open() and not _flag(current, &"keep_on_phase", false):
		if current.has_method(&"close"):
			current.call(&"close")
		else:
			current.visible = false


func _on_node_added(n: Node) -> void:
	if n is Control and n.is_in_group(&"ui_modal"):
		_watch(n)


func _scan() -> void:
	for n in get_tree().get_nodes_in_group(&"ui_modal"):
		_watch(n)
	for n in _watched:
		if n.visible and n != current:
			_shown(n)


func _watch(m: Control) -> void:
	if _watched.has(m):
		return
	_watched[m] = true
	m.visibility_changed.connect(_on_visibility.bind(m))
	if m.has_signal(&"dismissed"):
		m.connect(&"dismissed", func() -> void: _stack.erase(m))
	m.tree_exiting.connect(func() -> void:
		_watched.erase(m)
		_stack.erase(m)
		if m == current:
			_hidden(m))


func _on_visibility(m: Control) -> void:
	if _busy:
		return
	if m.visible:
		_shown(m)
	else:
		_hidden(m)


func _shown(m: Control) -> void:
	if m == current:
		return
	if is_modal_open():
		if _priority(m) < _priority(current):
			_set_visible(m, false)  # held back until the open screen closes
			_push(m)
			return
		_set_visible(current, false)
		if _priority(m) > _priority(current):
			_push(current)  # a higher screen sits over this one; an equal one replaces it
	_stack.erase(m)
	var was_open := current != null
	current = m
	if not was_open:
		_open_state_changed()


func _hidden(m: Control) -> void:
	if m != current:
		return
	current = null
	var next := _pop()
	if next != null:
		current = next
		_set_visible(next, true)
	else:
		_open_state_changed()


func _open_state_changed() -> void:
	if is_modal_open():
		_toast_label.hide()
	_update_mouse()
	modal_changed.emit(is_modal_open())


## In-game on desktop with no modal open: the mouse is the camera.
func wants_capture() -> bool:
	return capture_mouse and not is_modal_open() and not DisplayServer.is_touchscreen_available()


func _update_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if wants_capture() else Input.MOUSE_MODE_VISIBLE


func _push(m: Control) -> void:
	if not _stack.has(m):
		_stack.append(m)


func _pop() -> Control:
	var best: Control
	for c in _stack:
		if is_instance_valid(c) and c.is_inside_tree() and (best == null or _priority(c) > _priority(best)):
			best = c
	_stack.erase(best)
	return best


func _set_visible(m: Control, v: bool) -> void:
	_busy = true
	m.visible = v
	_busy = false


static func _priority(m: Control) -> int:
	var p: Variant = m.get(&"priority")
	return p if p is int else 0


static func _flag(m: Control, prop: StringName, fallback: bool) -> bool:
	var v: Variant = m.get(prop)
	return v if v is bool else fallback
