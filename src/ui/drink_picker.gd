class_name DrinkPicker
extends Control
## The bar counter's menu (docs/plan/08 §5, 03 §3.6): serve a drink to a crew member, throw one at the shooter,
## or jump to the Shop. Touch-sized rows. It only reports what was tapped (`picked`); the Player sends the
## world interaction and the host validates it. Rows grey out from mirrored state, so it reads the same everywhere.

signal picked(kind: StringName, drink_id: StringName, target_peer: int)
signal shop_requested

const ROW_HEIGHT := 72
const FONT_SIZE := 28

@export var economy: EconomyManager
@export var game_loop: GameLoop

var kind := &"bar_serve"
var target_peer := 0  ## 0 = me
var _rows: Dictionary = {}  # drink id -> Button
var _targets: Dictionary = {}  # peer id -> Button
var _panel: PanelContainer
var _target_row: HBoxContainer
var _mode_buttons: Dictionary = {}  # kind -> Button


func _ready() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(780, 640)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)
	var box := VBoxContainer.new()
	_panel.add_child(box)
	var modes := HBoxContainer.new()
	box.add_child(modes)
	for k: Array in [[&"bar_serve", "Serve"], [&"throw_drink", "Throw"]]:
		var b := _button(k[1])
		b.pressed.connect(open.bind(k[0]))
		modes.add_child(b)
		_mode_buttons[k[0]] = b
	var shop := _button("Shop")
	shop.pressed.connect(func() -> void:
		close()
		shop_requested.emit())
	modes.add_child(shop)
	var x := _button("Close")
	x.pressed.connect(close)
	modes.add_child(x)
	_target_row = HBoxContainer.new()
	box.add_child(_target_row)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for it in ShopCatalog.in_category(&"drink"):
		var row := _button("")
		row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		row.pressed.connect(_pick.bind(it.id))
		list.add_child(row)
		_rows[it.id] = row
	if economy != null:
		economy.cash_changed.connect(func(_b: int, _d: int, _r: StringName) -> void: _refresh())
	if game_loop != null:
		game_loop.phase_changed.connect(func(_p: GameLoop.Phase) -> void: _refresh())
	close()


func is_open() -> bool:
	return _panel.visible


func open(k: StringName = &"bar_serve") -> void:
	kind = k
	_panel.show()
	_build_targets()
	_refresh()


func close() -> void:
	_panel.hide()


func _pick(drink_id: StringName) -> void:
	var target := target_peer if target_peer != 0 else multiplayer.get_unique_id()
	close()
	picked.emit(kind, drink_id, target)


func _build_targets() -> void:
	for c in _target_row.get_children():
		c.queue_free()
	_targets.clear()
	_target_row.visible = kind == &"bar_serve"
	if kind != &"bar_serve":
		return
	var me := multiplayer.get_unique_id()
	var roster: Array = get_tree().root.get_node(^"NetManager").call(&"get_roster")  # by path: probes compile before autoloads
	if target_peer == 0:
		target_peer = me
	for e: Dictionary in roster:
		var b := _button(("You" if e.peer_id == me else str(e.name)))
		b.toggle_mode = true
		b.pressed.connect(func() -> void:
			target_peer = e.peer_id
			_refresh())
		_target_row.add_child(b)
		_targets[e.peer_id] = b


## Only while open: relabels ~11 buttons on a state change, never per frame.
func _refresh() -> void:
	if _panel == null or not _panel.visible:
		return
	for k: StringName in _mode_buttons:
		(_mode_buttons[k] as Button).disabled = k == kind
	for pid: int in _targets:
		(_targets[pid] as Button).button_pressed = pid == target_peer
	var live := game_loop != null and game_loop.phase == GameLoop.Phase.ROUND_LIVE
	for id: StringName in _rows:
		var it := ShopCatalog.item(id)
		var d := it.payload as Drink
		var why := &""
		if kind == &"throw_drink":
			if not live:
				why = &"needs a live Round"
			elif economy != null and economy.cash < it.cost_cash:
				why = &"cant_afford"
		elif live and not d.mid_round:
			why = &"intermission_only"
		elif economy != null:
			why = economy.can_buy(id)
		var row: Button = _rows[id]
		row.text = "%s  $%d" % [String(id).capitalize(), it.cost_cash] + ("" if why == &"" else "  (%s)" % why)
		row.disabled = why != &""


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(120, 56)
	b.add_theme_font_size_override(&"font_size", FONT_SIZE)
	return b
