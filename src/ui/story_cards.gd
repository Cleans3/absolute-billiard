class_name StoryCards
extends UIModal
## The story cards (docs/plan/09 §3.1): full-screen text over the dimmed bar, one tap per card, Skip closes them all.
## Local to each peer: nothing here is networked. Above the Intermission screens and below nothing but the vote's hold
## (priority 25 > EventVote 20, so the intro reads before the hazard vote), and it survives the NIGHT_START -> INTERMISSION
## phase change. `finished` fires on any close: the last card read, Skip, or Esc.

signal finished(skipped: bool)

const FONT_SIZE := 30
const PANEL_WIDTH := 680.0

var cards: Array[String] = []
var index := 0

var _read_all := false
var _page: Label
var _body: Label
var _next: Button
var _skip: Button


func _ready() -> void:
	super()
	priority = 25
	keep_on_phase = true
	_build()
	gui_input.connect(_on_gui_input)


## Opens at the first card. `list` is not kept by reference.
func show_cards(list: Array[String]) -> void:
	if list.is_empty():
		return
	cards = list.duplicate()
	index = 0
	_read_all = false
	_show_card()
	open()
	if is_visible_in_tree():
		_next.grab_focus()


func advance() -> void:
	if not is_open():
		return
	if index + 1 >= cards.size():
		_read_all = true
		close()
		return
	index += 1
	_show_card()


func _on_close() -> void:
	finished.emit(not _read_all)


func _show_card() -> void:
	_body.text = cards[index].replace("*", "")  # the script's *emphasis* marks are for the page, not the label
	_page.text = "%d / %d" % [index + 1, cards.size()]
	_next.text = "Next" if index + 1 < cards.size() else "Got it"
	_skip.visible = index + 1 < cards.size()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		advance()


func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(panel)
	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(rows)
	_page = Label.new()
	_page.theme_type_variation = &"Caption"
	_page.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(_page)
	_body = Label.new()
	_body.custom_minimum_size = Vector2(PANEL_WIDTH - 80.0, 190.0)
	_body.add_theme_font_size_override(&"font_size", FONT_SIZE)
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(_body)
	_next = Button.new()
	_next.custom_minimum_size = Vector2(0.0, 76.0)
	_next.theme_type_variation = &"PrimaryButton"
	_next.pressed.connect(advance)
	rows.add_child(_next)
	_skip = Button.new()
	_skip.custom_minimum_size = Vector2(0.0, 64.0)
	_skip.text = "Skip"
	_skip.pressed.connect(close)
	rows.add_child(_skip)
