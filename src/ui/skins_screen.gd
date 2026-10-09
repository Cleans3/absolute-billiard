class_name SkinsScreen
extends UIModal
## The Skins screen (06 P18): pick the character you wear and the bar you bring. A `ui_modal`, opened from the main
## menu. Test mode: everything is free and unlocked, so a card is only ever "Equip" or "Equipped"; equipping
## writes user://profile.json at once (`SkinCatalog`). Cards show names only (polish 2 C1): the preview alone shows the
## look. Character preview = a turning Humanoid in a SubViewport; bar preview = the pre-rendered turntable of the room in
## that skin (assets/ui/bar_preview/<id>.png, src/tools/render_bar_previews.gd) blended by src/shaders/bar_preview.gdshader.

signal closed  ## it was open and now is not (kept for callers; UIModal's `dismissed` fires on every close())

const CARD_SIZE := Vector2(190, 100)
const TURN_RAD_PER_SEC := 0.7
## The bar turntable's panorama, shared with render_bar_previews.gd: a full turn of the room folded into PREVIEW_ROWS rows.
const PREVIEW_DIR := "res://assets/ui/bar_preview/"
const PREVIEW_SHEET := Vector2i(1024, 752)  ## <= 1024 px a side (07 §8)
const PREVIEW_ROWS := 2
const PREVIEW_VIEW_DEG := 108.0  ## how much of the turn the picture shows at once
const BAR_TURN_SEC := 14.0  ## one full turn of the room
const HAT_NAMES := {&"none": "No hat", &"cap": "Cap", &"tophat": "Top hat", &"beanie": "Beanie", &"crown": "Crown"}

var _sel_char: StringName = &""
var _sel_bar: StringName = &""
var _char_cards: Dictionary = {}  # id -> {button, badge}
var _bar_cards: Dictionary = {}
var _hum: Humanoid
var _turn := PI  ## the Humanoid faces -Z; PI shows its face to the camera
var _phase := 0.0  ## the bar turntable's position, 0..1 of a turn
var _sheets: Dictionary = {}  # skin id -> Texture2D, loaded the first time it is previewed

@onready var _tabs: TabContainer = %Tabs
@onready var _viewport: SubViewport = %Preview
@onready var _char_name: Label = %CharName
@onready var _char_hat: Label = %CharHat
@onready var _equip_char: Button = %EquipChar
@onready var _char_grid: GridContainer = %CharGrid
@onready var _bar_name: Label = %BarName
@onready var _preview: TextureRect = %BarPreview
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
		_char_cards[skin.id] = _card(_char_grid, chars, skin.display_name, select_character.bind(skin.id))
	var bars := ButtonGroup.new()
	for skin in SkinCatalog.bars():
		_bar_cards[skin.id] = _card(_bar_grid, bars, skin.display_name, select_bar.bind(skin.id))
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
	_show_sheet(id)
	_bar_cards[id].button.set_pressed(true)
	_refresh()


func equip_character(id: StringName) -> void:
	SkinCatalog.equip_character(id)
	_refresh()


func equip_bar(id: StringName) -> void:
	SkinCatalog.equip_bar(id)
	_refresh()


func _process(delta: float) -> void:
	if _tabs.current_tab == 0:
		_turn = wrapf(_turn + TURN_RAD_PER_SEC * delta, 0.0, TAU)
		_hum.rotation.y = _turn
	elif _preview.visible:  # only the visible turntable advances
		_phase = fposmod(_phase + delta / BAR_TURN_SEC, 1.0)
		(_preview.material as ShaderMaterial).set_shader_parameter(&"phase", _phase)


## The turntable sheet of a bar skin; no file (a skin added without re-running the tool) hides the picture, never errors.
func _show_sheet(id: StringName) -> void:
	if not _sheets.has(id):
		var path := "%s%s.png" % [PREVIEW_DIR, id]
		_sheets[id] = load(path) if ResourceLoader.exists(path) else null
	var tex: Texture2D = _sheets[id]
	_preview.visible = tex != null
	_preview.texture = tex
	var mat := _preview.material as ShaderMaterial
	mat.set_shader_parameter(&"sheet", tex)
	mat.set_shader_parameter(&"rows", PREVIEW_ROWS)
	mat.set_shader_parameter(&"view", PREVIEW_VIEW_DEG / 360.0)
	mat.set_shader_parameter(&"sheet_px", Vector2(PREVIEW_SHEET))


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


## One toggle card: the skin's name and an "Equipped" badge, nothing else. Children ignore the mouse so the Button gets every tap.
func _card(grid: GridContainer, group: ButtonGroup, title: String, on_pick: Callable) -> Dictionary:
	var button := Button.new()
	button.toggle_mode = true
	button.button_group = group
	button.custom_minimum_size = CARD_SIZE
	button.pressed.connect(on_pick)
	var box := VBoxContainer.new()
	box.anchor_right = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 10.0
	box.offset_top = 10.0
	box.offset_right = -10.0
	box.offset_bottom = -10.0  # the whole card, so the centred pair sits in the middle of it
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var name_label := Label.new()
	name_label.text = title
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var badge := Label.new()
	badge.theme_type_variation = &"Caption"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.custom_minimum_size.y = 24
	for n: Control in [name_label, badge]:
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(n)
	button.add_child(box)
	grid.add_child(button)
	return {button = button, badge = badge}
