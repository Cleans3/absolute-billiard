class_name BartenderMenu
extends Control
## The Bartender's counter (docs/plan/02 §3.6, 06 P17, polish contract §1 and §9): a `ui_modal` with two tabs.
## Drinks = the host's random shelf as tier-framed cards (serve a crewmate, or throw one at the shooter);
## Upgrades = the fixed ball / cue / camera / table rows. A Drink tap is only reported (`picked`): the Player sends
## the host-validated world interaction. Upgrades ask the host through request_purchase. The UIRouter owns the mouse.

signal picked(kind: StringName, drink_id: StringName, target_peer: int)

const FRAME_DIR := "res://assets/ui/bartender/"
const CARD_SIZE := Vector2(216, 372)
const FRAME_MARGIN := 28  # 9-slice corner of the frame SVGs
const ROW_HEIGHT := 64
const BUTTON_HEIGHT := 52  # touch-sized
const CATEGORY_TITLES := {&"ball": "Balls", &"cue": "Cue", &"camera": "Cameras", &"table": "Table"}
const REASON_TEXT := {
	&"cant_afford": "Can't afford", &"sold_out": "Sold out", &"not_stocked": "Not stocked",
	&"intermission_only": "Between Rounds", &"closed": "Between Rounds", &"locked": "Locked", &"owned": "Owned",
	&"once_per_night": "Once a Night", &"night_limit": "Night limit", &"drink_cap": "3 drinks max",
	&"needs_live": "Live Round only", &"unknown_item": "Unknown",
}

@export var economy: EconomyManager
@export var game_loop: GameLoop

var keep_on_phase := false  # the UIRouter closes modals on a phase change unless this is true
var kind := &"bar_serve"  # bar_serve | throw_drink
var target_peer := 0  ## 0 = me
var _frames: Dictionary = {}  # DrinkTier.Tier -> StyleBox
var _glitch := GlitchEffect.new()
var _targets: Dictionary = {}  # peer id -> Button
var _drink_buttons: Dictionary = {}  # drink id -> Buy / Throw button of its card
var _upgrade_buttons: Dictionary = {}  # item id -> Buy button of its row

@onready var _cash: Label = %Cash
@onready var _tabs: TabContainer = %Tabs
@onready var _serve: Button = %Serve
@onready var _throw: Button = %Throw
@onready var _target_row: HBoxContainer = %Targets
@onready var _cards: HBoxContainer = %Cards
@onready var _note: Label = %Note
@onready var _upgrades: VBoxContainer = %List
@onready var _status: Label = %Status


func _ready() -> void:
	add_to_group(&"ui_modal")
	%Close.pressed.connect(close)
	_serve.pressed.connect(set_mode.bind(&"bar_serve"))
	_throw.pressed.connect(set_mode.bind(&"throw_drink"))
	_tabs.tab_changed.connect(func(_i: int) -> void: _refresh())
	if economy != null:
		economy.cash_changed.connect(func(_b: int, _d: int, _r: StringName) -> void: _refresh())
		economy.owned_changed.connect(_refresh)
		economy.stock_changed.connect(_refresh)
		economy.purchase_rejected.connect(_on_rejected)
	if game_loop != null:
		game_loop.phase_changed.connect(func(_p: GameLoop.Phase) -> void: _refresh())
	hide()


func is_open() -> bool:
	return visible


func open() -> void:
	_status.text = ""
	_tabs.current_tab = 0
	show()
	_build_targets()
	_refresh()


func close() -> void:
	hide()


func set_mode(k: StringName) -> void:
	kind = k
	_build_targets()
	_refresh()


## The Buy / Throw button of a shelf card, null when that drink is not on the shelf (probes press it).
func drink_button(drink_id: StringName) -> Button:
	return _drink_buttons.get(drink_id)


func upgrade_button(item_id: StringName) -> Button:
	return _upgrade_buttons.get(item_id)


func _pick(drink_id: StringName) -> void:
	var target := target_peer if target_peer != 0 else multiplayer.get_unique_id()
	picked.emit(kind, drink_id, target)
	if kind == &"throw_drink":
		close()  # you want to watch it land


func _on_rejected(item_id: StringName, reason: StringName) -> void:
	_status.text = "%s: %s" % [_name_of(item_id), REASON_TEXT.get(reason, String(reason).replace("_", " "))]


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
		var b := _button("You" if e.peer_id == me else str(e.name))
		b.toggle_mode = true
		b.pressed.connect(func() -> void:
			target_peer = e.peer_id
			_refresh())
		_target_row.add_child(b)
		_targets[e.peer_id] = b


## Only while open: re-draws ~5 cards and ~20 rows on a state change (Cash, stock, phase), never per frame.
func _refresh() -> void:
	if not visible or economy == null:
		return
	_cash.text = "Cash $%d" % economy.cash
	if economy.cash < 0:
		_cash.add_theme_color_override(&"font_color", StatText.DEBUFF_COLOUR)
	else:
		_cash.remove_theme_color_override(&"font_color")
	_serve.button_pressed = kind == &"bar_serve"
	_throw.button_pressed = kind == &"throw_drink"
	for pid: int in _targets:
		(_targets[pid] as Button).button_pressed = pid == target_peer
	_rebuild_cards()
	_rebuild_upgrades()


# --- Drinks -------------------------------------------------------------------------------------

func _rebuild_cards() -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	_drink_buttons.clear()
	_note.text = "" if economy.stock_size() > 0 else "The shelf is empty. The Bartender restocks at the next Intermission."
	for i in economy.stock_size():
		_cards.add_child(_card(i))


## Why `drink_id` cannot be bought (Serve) or thrown (Throw) right now, else &"".
func _why_not(drink_id: StringName) -> StringName:
	if kind == &"bar_serve":
		return economy.can_buy(drink_id)
	if game_loop == null or game_loop.phase != GameLoop.Phase.ROUND_LIVE:
		return &"needs_live"
	var why := economy.stock_refusal(drink_id)
	if why == &"" and ShopCatalog.item(drink_id).cost_cash > economy.cash:
		why = &"cant_afford"
	return why


func _card(i: int) -> Control:
	var id := economy.stock_id(i)
	var d := FxCatalog.drink(id)
	var left := economy.stock_left(i)
	var why := _why_not(id)
	var glitch := d.tier == DrinkTier.Tier.MYSTERY
	var tint := DrinkTier.colour(d.tier)
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	card.add_theme_stylebox_override(&"panel", _frame(d.tier))
	if left <= 0:
		card.modulate = Color(1.0, 1.0, 1.0, 0.45)  # sold out stays on the shelf, greyed
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 4)
	card.add_child(box)
	box.add_child(_text(DrinkTier.label(d.tier).to_upper(), 13, tint, glitch))
	box.add_child(_text(d.display_name, 22, tint, glitch))
	box.add_child(_text(d.description, 14, Color(0.82, 0.84, 0.88), glitch))
	for l in StatText.lines(d):
		var line := _label("%s %s" % ["+" if l.kind == StatText.Kind.BUFF else ("-" if l.kind == StatText.Kind.DEBUFF else "*"), l.text], 15, HORIZONTAL_ALIGNMENT_LEFT, true)
		if l.kind == StatText.Kind.BUFF:
			line.add_theme_color_override(&"font_color", StatText.BUFF_COLOUR)
		elif l.kind == StatText.Kind.DEBUFF:
			line.add_theme_color_override(&"font_color", StatText.DEBUFF_COLOUR)
		box.add_child(line)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(fill)
	if not d.mid_round:
		box.add_child(_label("Between Rounds only", 12, HORIZONTAL_ALIGNMENT_CENTER))
	var foot := HBoxContainer.new()
	var price := _label("$%d" % d.cost_cash, 22)
	price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(price)
	foot.add_child(_label("SOLD OUT" if left <= 0 else "%d left" % left, 15, HORIZONTAL_ALIGNMENT_RIGHT))
	box.add_child(foot)
	var buy := _button(("Buy" if kind == &"bar_serve" else "Throw") if why == &"" else REASON_TEXT.get(why, String(why)))
	buy.disabled = why != &""
	buy.pressed.connect(_pick.bind(id))
	_drink_buttons[id] = buy
	box.add_child(buy)
	return card


## One style box per tier from its SVG frame; a flat bordered box stands in when the SVG is not imported.
func _frame(tier: DrinkTier.Tier) -> StyleBox:
	if _frames.has(tier):
		return _frames[tier]
	var tex := load("%sframe_%s.svg" % [FRAME_DIR, DrinkTier.label(tier).to_lower()]) as Texture2D
	var sb: StyleBox
	if tex != null:
		var t := StyleBoxTexture.new()
		t.texture = tex
		t.texture_margin_left = FRAME_MARGIN
		t.texture_margin_top = FRAME_MARGIN
		t.texture_margin_right = FRAME_MARGIN
		t.texture_margin_bottom = FRAME_MARGIN
		sb = t
	else:
		var f := StyleBoxFlat.new()
		f.bg_color = Color("12141A")
		f.border_color = DrinkTier.colour(tier)
		f.set_border_width_all(3)
		f.set_corner_radius_all(10)
		sb = f
	sb.set_content_margin_all(FRAME_MARGIN - 8)
	_frames[tier] = sb
	return sb


## A centred line; Mystery text is a RichTextLabel with `[glitch]`, everything else a plain Label.
func _text(text: String, size: int, colour: Color, glitch: bool) -> Control:
	if not glitch:
		var l := _label(text, size, HORIZONTAL_ALIGNMENT_CENTER, true)
		l.add_theme_color_override(&"font_color", colour)
		return l
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override(&"normal_font_size", size)
	r.add_theme_color_override(&"default_color", colour)
	r.install_effect(_glitch)
	r.text = "[center][glitch]%s[/glitch][/center]" % text
	return r


# --- Upgrades -----------------------------------------------------------------------------------

func _rebuild_upgrades() -> void:
	for c in _upgrades.get_children():
		_upgrades.remove_child(c)
		c.queue_free()
	_upgrade_buttons.clear()
	for category in ShopCatalog.CATEGORIES:
		if category == &"drink":
			continue
		var head := _label(CATEGORY_TITLES[category], 22)
		head.add_theme_color_override(&"font_color", DrinkTier.colour(DrinkTier.Tier.LEGENDARY))
		_upgrades.add_child(head)
		for it in ShopCatalog.in_category(category):
			_upgrades.add_child(_upgrade_row(it))


func _upgrade_row(it: ShopItem) -> Control:
	var why := economy.can_buy(it.id)
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = ROW_HEIGHT
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_child(_label(it.display_name, 20))
	var desc := _label(it.description, 14, HORIZONTAL_ALIGNMENT_LEFT, true)
	desc.modulate = Color(1.0, 1.0, 1.0, 0.75)
	text.add_child(desc)
	row.add_child(text)
	var price := _label("$%d" % it.cost_cash, 20, HORIZONTAL_ALIGNMENT_RIGHT)
	price.custom_minimum_size.x = 84
	row.add_child(price)
	var buy := _button("Buy" if why == &"" else REASON_TEXT.get(why, String(why)))
	buy.disabled = why != &""
	buy.pressed.connect(_buy_upgrade.bind(it.id))
	row.add_child(buy)
	_upgrade_buttons[it.id] = buy
	return row


func _buy_upgrade(item_id: StringName) -> void:
	economy.request_purchase.rpc_id(1, item_id)


# --- bits ---------------------------------------------------------------------------------------

func _name_of(item_id: StringName) -> String:
	var it := ShopCatalog.item(item_id)
	return it.display_name if it != null and not it.display_name.is_empty() else String(item_id).capitalize()


## `wrap` = flowing text (descriptions, effect lines); short single-line labels must not wrap or a narrow cell stacks them letter by letter.
func _label(text: String, size: int, align := HORIZONTAL_ALIGNMENT_LEFT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override(&"font_size", size)
	return l


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(120, BUTTON_HEIGHT)
	b.add_theme_font_size_override(&"font_size", 20)
	return b
