class_name ShopMenu
extends Control
## The Bartender's Shop (docs/plan/02 §3.6): every ShopItem by category, touch-sized. Rows grey out from the
## mirrored state (`can_buy`), so it reads the same on every peer; a tap asks the host through request_purchase.
## The bar prop (or a Player use action) calls open(); the corner button is the always-there way in.

const ROW_HEIGHT := 72
const FONT_SIZE := 28

@export var economy: EconomyManager
@export var game_loop: GameLoop

var _rows: Dictionary = {}  # item id -> Button

@onready var _panel: PanelContainer = %Panel
@onready var _list: VBoxContainer = %List
@onready var _cash: Label = %ShopCash
@onready var _toggle: Button = %Toggle


func _ready() -> void:
	_toggle.pressed.connect(toggle)
	%Close.pressed.connect(close)
	_build()
	if economy != null:
		economy.cash_changed.connect(func(_b: int, _d: int, _r: StringName) -> void: _refresh())
		economy.owned_changed.connect(_refresh)
		economy.purchase_rejected.connect(func(id: StringName, reason: StringName) -> void:
			if _rows.has(id):
				_rows[id].text = "%s — %s" % [_name(id), reason])
	if game_loop != null:
		game_loop.phase_changed.connect(func(_p: GameLoop.Phase) -> void: _refresh())
	close()


func open() -> void:
	_panel.show()
	_refresh()


func close() -> void:
	_panel.hide()


func toggle() -> void:
	close() if _panel.visible else open()


func _build() -> void:
	for category in ShopCatalog.CATEGORIES:
		var header := Label.new()
		header.text = String(category).capitalize()
		header.add_theme_font_size_override(&"font_size", FONT_SIZE)
		_list.add_child(header)
		for it in ShopCatalog.in_category(category):
			var row := Button.new()
			row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
			row.add_theme_font_size_override(&"font_size", FONT_SIZE)
			row.pressed.connect(_buy.bind(it.id))
			_list.add_child(row)
			_rows[it.id] = row


func _buy(item_id: StringName) -> void:
	economy.request_purchase.rpc_id(1, item_id)


## Only while open: rewrites ~30 button labels on a state change, never per frame.
func _refresh() -> void:
	if not _panel.visible or economy == null:
		return
	_cash.text = "Cash $%d" % economy.cash
	for id: StringName in _rows:
		var it := ShopCatalog.item(id)
		var why := economy.can_buy(id)
		var row: Button = _rows[id]
		row.text = "%s  $%d" % [_name(id), it.cost_cash] + ("" if why == &"" else "  (%s)" % why)
		row.disabled = why != &""


func _name(id: StringName) -> String:
	return String(id).capitalize()
