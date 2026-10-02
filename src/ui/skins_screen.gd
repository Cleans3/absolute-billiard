class_name SkinsScreen
extends UIModal
## The Skins screen (06 P18): pick the character you wear and the bar you bring. A `ui_modal`, opened from the main
## menu. Test mode: everything is free and unlocked, so a card is only ever "Equip" or "Equipped"; equipping
## writes user://profile.json at once (`SkinCatalog`). Character preview = a turning Humanoid in a SubViewport,
## bar preview = the skin's palette.

signal closed  ## it was open and now is not (kept for callers; UIModal's `dismissed` fires on every close())

const CARD_SIZE := Vector2(196, 184)
const SWATCH_SIZE := Vector2(30, 30)
const TURN_RAD_PER_SEC := 0.7
const HAT_NAMES := {&"none": "No hat", &"cap": "Cap", &"tophat": "Top hat", &"beanie": "Beanie", &"crown": "Crown"}

var _sel_char: StringName = &""
var _sel_bar: StringName = &""
var _char_cards: Dictionary = {}  # id -> {button, badge}
var _bar_cards: Dictionary = {}
var _hum: Humanoid
var _turn := PI  ## the Humanoid faces -Z; PI shows its face to the camera

@onready var _tabs: TabContainer = %Tabs
@onready var _viewport: SubViewport = %Preview
@onready var _char_name: Label = %CharName
@onready var _char_hat: Label = %CharHat
@onready var _equip_char: Button = %EquipChar
@onready var _char_grid: GridContainer = %CharGrid
@onready var _bar_name: Label = %BarName
@onready var _palette: VBoxContainer = %Palette
@onready var _equip_bar: Button = %EquipBar
@onready var _bar_grid: GridContainer = %BarGrid


func _init() -> void:
	super()
	add_to_group(&"ui_skins")


func _ready() -> void:
	super()  # UIModal: dim backdrop; closed by a phase change (the main menu has none), Esc closes it
	priority = 60
	%Close.pressed.connect(close)
	_equip_char.pressed.connect(func() -> void: equip_character(_sel_char))
	_equip_bar.pressed.connect(func() -> void: equip_bar(_sel_bar))
	var chars := ButtonGroup.new()
	for skin in SkinCatalog.characters():
		_char_cards[skin.id] = _card(_char_grid, chars, skin.display_name, [skin.body_color, skin.accent_color, skin.skin_color], select_character.bind(skin.id))
	var bars := ButtonGroup.new()
	for skin in SkinCatalog.bars():
		_bar_cards[skin.id] = _card(_bar_grid, bars, skin.display_name, [skin.wall_color, skin.floor_color, skin.wood_color, skin.seat_color, skin.felt_color, skin.neon_a], select_bar.bind(skin.id))
	set_process(false)
	hide()


func open() -> void:
	_tabs.current_tab = 0
	select_character(SkinCatalog.resolve_character(SkinCatalog.equipped_character_id(), 0).id)
	select_bar(SkinCatalog.equipped_bar_id())
	show()
	set_process(true)


func close() -> void:
	var was_open := visible
	super()
	set_process(false)
	if was_open:
		closed.emit()


func select_character(id: StringName) -> void:
	var skin := SkinCatalog.character(id)
	if skin == null:
		return
	if _hum == null:  # built on first use, not when the menu loads
		_hum = Humanoid.new()
		_viewport.add_child(_hum)
	_sel_char = id
	_hum.apply_skin(skin)
	_char_name.text = skin.display_name
	_char_hat.text = HAT_NAMES.get(skin.hat, String(skin.hat))
	_char_cards[id].button.set_pressed(true)  # `toggled`, not `pressed`: no pick handler fires; the group unpresses the others
	_refresh()


func select_bar(id: StringName) -> void:
	var skin := SkinCatalog.bar(id)
	if skin == null:
		return
	_sel_bar = id
	_bar_name.text = skin.display_name
	for c in _palette.get_children():
		_palette.remove_child(c)
		c.free()
	for row: Array in [["Wall", [skin.wall_color]], ["Floor", [skin.floor_color]], ["Wood", [skin.wood_color]],
			["Seats", [skin.seat_color]], ["Felt", [skin.felt_color]], ["Neon", [skin.neon_a, skin.neon_b]]]:
		_palette.add_child(_palette_row(row[0], row[1]))
	_bar_cards[id].button.set_pressed(true)
	_refresh()


func equip_character(id: StringName) -> void:
	SkinCatalog.equip_character(id)
	_refresh()


func equip_bar(id: StringName) -> void:
	SkinCatalog.equip_bar(id)
	_refresh()


func _process(delta: float) -> void:
	_turn = wrapf(_turn + TURN_RAD_PER_SEC * delta, 0.0, TAU)
	_hum.rotation.y = _turn


## Badges and the Equip buttons follow the profile, so they are always what the next session will wear.
func _refresh() -> void:
	var worn_char := SkinCatalog.resolve_character(SkinCatalog.equipped_character_id(), 0).id
	var worn_bar := SkinCatalog.equipped_bar_id()
	for id: StringName in _char_cards:
		_char_cards[id].badge.text = "Equipped" if id == worn_char else ""
	for id: StringName in _bar_cards:
		_bar_cards[id].badge.text = "Equipped" if id == worn_bar else ""
	_equip_char.text = "Equipped" if _sel_char == worn_char else "Equip"
	_equip_char.disabled = _sel_char == worn_char
	_equip_bar.text = "Equipped" if _sel_bar == worn_bar else "Equip"
	_equip_bar.disabled = _sel_bar == worn_bar


## One toggle card: palette dots, the name, an "Equipped" badge. Children ignore the mouse so the Button gets every tap.
func _card(grid: GridContainer, group: ButtonGroup, title: String, colors: Array, on_pick: Callable) -> Dictionary:
	var button := Button.new()
	button.toggle_mode = true
	button.button_group = group
	button.custom_minimum_size = CARD_SIZE
	button.pressed.connect(on_pick)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var dots := GridContainer.new()  # 3 across: a character's three colours in one row, a bar's six in two
	dots.columns = 3
	dots.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Color in colors:
		dots.add_child(_swatch(c))
	var name_label := Label.new()
	name_label.text = title
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var badge := Label.new()
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.custom_minimum_size.y = 24
	for n: Control in [name_label, badge]:
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for n: Control in [dots, name_label, badge]:
		box.add_child(n)
	button.add_child(box)
	grid.add_child(button)
	return {button = button, badge = badge}


## A rounded chip with a pale rim: the skins are dark, and a bare dark square vanishes on a dark panel.
func _swatch(c: Color) -> Panel:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.4)
	sb.set_corner_radius_all(6)
	var r := Panel.new()
	r.add_theme_stylebox_override(&"panel", sb)
	r.custom_minimum_size = SWATCH_SIZE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _palette_row(label: String, colors: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 84
	row.add_child(l)
	for c: Color in colors:
		row.add_child(_swatch(c))
	return row
