class_name DebugStrip
extends CanvasLayer

## The always-on part of debug mode: four buttons in the free stretch of the top bar (x 380-880, y 8-64 of the 1280-wide
## canvas; tests/ui/ui_probe.gd checks it against every HUD and touch widget). Open the panel, rewind or replay the last
## shot, re-rack the Round. Shown only while Settings "Debug mode" is on.

const REGION := Rect2(380.0, 8.0, 500.0, 56.0)

var session: DebugSession
var panel: DebugPanel

var _row: HBoxContainer


func _ready() -> void:
	layer = 13  # over the panel (12): the strip stays on top
	_row = HBoxContainer.new()
	_row.position = REGION.position
	_row.custom_minimum_size = REGION.size
	_row.size = REGION.size
	_row.add_theme_constant_override(&"separation", 8)
	add_child(_row)
	_add("DEBUG", func() -> void: panel.close() if panel.visible else panel.open())
	_add("Rewind", func() -> void: _last(false))
	_add("Replay", func() -> void: _last(true))
	_add("Re-rack", func() -> void: session.rerack(true))


func _add(text: String, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0.0, REGION.size.y)
	b.clip_text = true  # four equal buttons in REGION whatever the font
	b.add_theme_font_size_override(&"font_size", 22)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(on_press)
	_row.add_child(b)


func _last(play: bool) -> void:
	var rec := session.last()
	if rec == null:
		return
	if play:
		session.replay(rec)
	else:
		session.rewind(rec)


func buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c in _row.get_children():
		out.append(c)
	return out
