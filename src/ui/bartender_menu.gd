class_name BartenderMenu
extends UIModal
## The Bartender's counter (docs/plan/02 §3.6, 06 P17, polish contract §1 and §9): a `ui_modal` with two tabs.
## Drinks = the host's random shelf as tier-framed cards (serve yourself or a crewmate, or throw one at the shooter);
## Solo and the shooter see no choice, so no target row and no Throw (06 P35, 02 §3.6);
## Upgrades = the fixed ball / cue / camera / table rows. A Drink tap is only reported (`picked`): the Player sends
## the host-validated world interaction. Upgrades ask the host through request_purchase. The UIRouter owns the mouse.
## The panel never changes size (polish 2, C11): the cards are fixed-size Controls that clip their content, every
## variable string is clipped or wrapped to a bounded slot, and tests/ui/shop_ui_probe.gd measures it in every state.

signal picked(kind: StringName, drink_id: StringName, target_peer: int)

const FRAME_DIR := "res://assets/ui/bartender/"
const CARD_SIZE := Vector2(216, 468)  # 5 cards + gaps = 1136 of the panel's 1144 px; 468 of its 480 px with the tab bar hidden
const ICON_SIZE := 68
const FRAME_MARGIN := 28  # 9-slice corner of the frame SVGs
const ROW_HEIGHT := 64
const ROW_ICON := 56  # + the 4 px plate margin each side = ROW_HEIGHT
const ROW_RIM := Color("C9A24B")
const UPGRADE_BUTTON_WIDTH := 300  # fits "Opens between Rounds"
const BUTTON_HEIGHT := 52  # touch-sized
const NAME_MAX := 18  # chars of the shooter's name in the "Throws at:" line
const CATEGORY_TITLES := {&"ball": "Balls", &"cue": "Cue", &"camera": "Cameras", &"table": "Table"}
## Why a button is greyed, short enough for a card button (the shop probe measures every entry).
const REASON_TEXT := {
	&"cant_afford": "Can't afford", &"sold_out": "Sold out", &"not_stocked": "Not stocked",
	&"intermission_only": "Break only", &"closed": "Break only", &"locked": "Locked", &"owned": "Owned",
	&"once_per_night": "Once a Night", &"night_limit": "Night limit", &"drink_cap": "3 drinks max",
	&"needs_live": "Live only", &"unknown_item": "Unknown",
	&"has_cue": "You hold one", &"cues_full": "All 5 still around",
}
## The timing reasons say when the item opens: the card's gate line, an Upgrade row's button, the status line.
const WHEN_TEXT := {
	&"intermission_only": "Opens between Rounds", &"closed": "Opens between Rounds", &"needs_live": "Opens in a live Round",
}

@export var economy: EconomyManager
@export var game_loop: GameLoop
@export var round_director: RoundDirector  ## whose turn it is: the shooter cannot be thrown at by themselves

var kind := &"bar_serve"  # bar_serve | throw_drink
var target_peer := 0  ## 0 = me
var _frames: Dictionary = {}  # DrinkTier.Tier -> StyleBox
var _plates: Dictionary = {}  # rim Color -> StyleBox of the icon plate
var _glitch := GlitchEffect.new()
var _targets: Dictionary = {}  # peer id -> Button
var _drink_buttons: Dictionary = {}  # drink id -> Buy / Throw button of its card
var _upgrade_buttons: Dictionary = {}  # item id -> Buy button of its row
var cue_button: Button  ## the New cue row's Buy (08 §2.9), probes press it
var _rack: CueRack

@onready var _cash: Label = %Cash
@onready var _tabs: TabContainer = %Tabs
@onready var _tab_drinks: Button = %TabDrinks
@onready var _tab_upgrades: Button = %TabUpgrades
@onready var _serve: Button = %Serve
@onready var _throw: Button = %Throw
@onready var _hint: Label = %Hint
@onready var _target_row: HBoxContainer = %Targets
@onready var _cards: HBoxContainer = %Cards
@onready var _note: Label = %Note
@onready var _upgrades: VBoxContainer = %List
@onready var _status: Label = %Status


func _ready() -> void:
	super()  # UIModal: the dim backdrop and the visibility hook; priority 0, dismissable, closed by a phase change
	%Close.pressed.connect(close)
	_serve.pressed.connect(set_mode.bind(&"bar_serve"))
	_throw.pressed.connect(set_mode.bind(&"throw_drink"))
	var tab_group := ButtonGroup.new()  # the tab bar is hidden (it cost a row of the card height): two buttons in the head
	for b: Button in [_tab_drinks, _tab_upgrades]:
		b.button_group = tab_group
		b.pressed.connect(func() -> void: set_tab(b.get_index() - _tab_drinks.get_index()))
	_tabs.tab_changed.connect(func(_i: int) -> void: _refresh())
	var net := get_tree().root.get_node_or_null(^"NetManager")  # by path: probes compile before autoloads
	if net != null:
		net.connect(&"roster_changed", func() -> void:
			if visible:
				_build_targets()
				_refresh())
	if economy != null:
		economy.cash_changed.connect(func(_b: int, _d: int, _r: StringName) -> void: _refresh())
		economy.owned_changed.connect(_refresh)
		economy.stock_changed.connect(_refresh)
		economy.purchase_rejected.connect(_on_rejected)
	if game_loop != null:
		game_loop.phase_changed.connect(func(_p: GameLoop.Phase) -> void: _refresh())
	_rack = get_tree().get_first_node_in_group(&"cue_rack") as CueRack
	if _rack != null:
		_rack.changed.connect(_refresh)
	if round_director != null:
		round_director.shooter_changed.connect(func(_p: int) -> void:
			if visible:
				_build_targets()
				_refresh())
	hide()


## Always opens on Drinks / Serve / yourself: nothing from the last visit stays selected.
func open() -> void:
	_status.text = ""
	kind = &"bar_serve"
	target_peer = 0
	_tabs.current_tab = 0
	show()
	_build_targets()
	_refresh()


func close() -> void:
	super()


func set_mode(k: StringName) -> void:
	kind = k
	if k == &"throw_drink":
		target_peer = 0  # the target row is hidden in Throw: nothing hidden stays selected
	_build_targets()
	_refresh()


func set_tab(i: int) -> void:
	_tabs.current_tab = i


## The Buy / Throw button of a shelf card, null when that drink is not on the shelf (probes press it).
func drink_button(drink_id: StringName) -> Button:
	return _drink_buttons.get(drink_id)


func upgrade_button(item_id: StringName) -> Button:
	return _upgrade_buttons.get(item_id)


func _pick(drink_id: StringName) -> void:
	var target := target_peer if kind == &"bar_serve" and target_peer != 0 else multiplayer.get_unique_id()
	picked.emit(kind, drink_id, target)
	if kind == &"throw_drink":
		close()  # you want to watch it land


func _on_rejected(item_id: StringName, reason: StringName) -> void:
	_status.text = "%s: %s" % [_name_of(item_id), _refusal(reason)]


## The long wording of a refusal: when it opens for a timing reason, else the short reason.
func _refusal(reason: StringName) -> String:
	return WHEN_TEXT.get(reason, REASON_TEXT.get(reason, String(reason).replace("_", " ")))


## The mode row. Serve and Throw buttons exist only when both are real (a crew, and I am not the shooter); the hint
## names the target (Solo: me; Serve: a "Serve to:" toggle per crew member; Throw: the shooter).
func _build_targets() -> void:
	for c in _target_row.get_children():
		_target_row.remove_child(c)
		c.queue_free()
	_targets.clear()
	var me := multiplayer.get_unique_id()
	var roster: Array = get_tree().root.get_node(^"NetManager").call(&"get_roster")  # by path: probes compile before autoloads
	var crew := roster.size() > 1
	var shooter := round_director.current_shooter_id if round_director != null else me
	var can_throw := crew and shooter != me  # you cannot throw at yourself
	if kind == &"throw_drink" and not can_throw:
		kind = &"bar_serve"  # the shooter changed, or the crew left, while Throw was selected
	_serve.visible = can_throw
	_throw.visible = can_throw
	_target_row.visible = crew and kind == &"bar_serve"
	if kind == &"throw_drink":
		var who := "the shooter"
		for e: Dictionary in roster:
			if e.peer_id == shooter:
				who = str(e.name) if str(e.name).length() <= NAME_MAX else str(e.name).left(NAME_MAX - 1) + "…"
		_hint.text = "Throws at: %s" % who
		return
	if target_peer == 0 or not roster.any(func(e: Dictionary) -> bool: return e.peer_id == target_peer):
		target_peer = me  # never a crewmate who has left
	_hint.text = "Serve to:" if crew else "Served to you"
	if not crew:
		return
	for e: Dictionary in roster:
		var b := _button("You" if e.peer_id == me else str(e.name))
		b.clip_text = true  # a long crew name must not widen the row, and with it the panel
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	_cash.theme_type_variation = &"Danger" if economy.cash < 0 else &""
	_tab_drinks.button_pressed = _tabs.current_tab == 0
	_tab_upgrades.button_pressed = _tabs.current_tab == 1
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
	_note.visible = _note.text != ""  # an empty line would still cost a row of height
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


## A plain Control of CARD_SIZE (so its minimum is exactly that, whatever the text wants) clipping a framed column:
## icon, tier, name, the flavour line(s), effect lines, then price / stock, the gate line and the button. The flavour
## takes the height the effect lines leave over, in whole lines (`_flavour`), so a drink with five effects shows none.
func _card(i: int) -> Control:
	var id := economy.stock_id(i)
	var d := FxCatalog.drink(id)
	var left := economy.stock_left(i)
	var why := _why_not(id)
	var glitch := d.tier == DrinkTier.Tier.MYSTERY
	var tint := DrinkTier.colour(d.tier)
	var card := Control.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = true
	if left <= 0:
		card.modulate = Color(1.0, 1.0, 1.0, 0.45)  # sold out stays on the shelf, greyed
	var frame := PanelContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_stylebox_override(&"panel", _frame(d.tier))
	card.add_child(frame)
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightBox"
	frame.add_child(box)
	box.add_child(_icon(IconCatalog.drink(d), tint))
	box.add_child(_text(DrinkTier.label(d.tier).to_upper(), &"Caption", tint, glitch))
	box.add_child(_text(d.display_name, &"CardName", tint, glitch))
	box.add_child(_flavour(d.description))
	for l in StatText.lines(d):
		var line := _label("%s %s" % ["+" if l.kind == StatText.Kind.BUFF else ("-" if l.kind == StatText.Kind.DEBUFF else "*"), l.text], &"Caption", HORIZONTAL_ALIGNMENT_LEFT, true)
		if l.kind == StatText.Kind.BUFF:
			line.add_theme_color_override(&"font_color", StatText.BUFF_COLOUR)
		elif l.kind == StatText.Kind.DEBUFF:
			line.add_theme_color_override(&"font_color", StatText.DEBUFF_COLOUR)
		box.add_child(line)
	if WHEN_TEXT.has(why):  # a timing refusal says when it opens, on the card; the button stays Buy / Throw, greyed
		box.add_child(_label(WHEN_TEXT[why], &"Caption", HORIZONTAL_ALIGNMENT_CENTER))
	var foot := HBoxContainer.new()
	var price := _label("$%d" % d.cost_cash)
	price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(price)
	foot.add_child(_label("SOLD OUT" if left <= 0 else "%d left" % left, &"Caption", HORIZONTAL_ALIGNMENT_RIGHT))
	box.add_child(foot)
	var buy := _card_button(("Buy" if kind == &"bar_serve" else "Throw") if why == &"" or WHEN_TEXT.has(why) else REASON_TEXT.get(why, String(why)))
	buy.disabled = why != &""
	buy.pressed.connect(_pick.bind(id))
	_drink_buttons[id] = buy
	box.add_child(buy)
	return card


## The flavour line in a slot that takes the spare height: it shows as many whole lines as fit, ellipsis on the last.
func _flavour(text: String) -> Control:
	var slot := Control.new()
	slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot.clip_contents = true
	var l := _label(text, &"Caption", HORIZONTAL_ALIGNMENT_CENTER, true)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_color_override(&"font_color", Color(0.82, 0.84, 0.88))
	slot.add_child(l)
	slot.resized.connect(func() -> void:
		var gap := l.get_theme_constant(&"line_spacing")
		var lines := floori((slot.size.y + gap) / (l.get_line_height() + gap))
		l.visible = lines > 0
		l.max_lines_visible = maxi(lines, 1))
	return slot


## The icon on a tier-rimmed plate: the rim colour comes from the Drink's tier, so no icon file carries it.
func _icon(tex: Texture2D, rim: Color, size := ICON_SIZE) -> Control:
	var plate := PanelContainer.new()
	plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	plate.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plate.add_theme_stylebox_override(&"panel", _plate(rim))
	var r := TextureRect.new()
	r.texture = tex
	r.custom_minimum_size = Vector2(size, size)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(r)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return plate


func _plate(rim: Color) -> StyleBox:
	if _plates.has(rim):
		return _plates[rim]
	var f := StyleBoxFlat.new()
	f.bg_color = Color(0.03, 0.03, 0.05, 0.92)
	f.border_color = rim
	f.set_border_width_all(3)
	f.set_corner_radius_all(16)
	f.set_content_margin_all(4)
	_plates[rim] = f
	return f


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
	sb.set_content_margin_all(FRAME_MARGIN - 12)
	_frames[tier] = sb
	return sb


## A centred line; Mystery text is a RichTextLabel with `[glitch]`, everything else a plain Label.
func _text(text: String, variation: StringName, colour: Color, glitch: bool) -> Control:
	if not glitch:
		var l := _label(text, variation, HORIZONTAL_ALIGNMENT_CENTER, true)
		l.add_theme_color_override(&"font_color", colour)
		return l
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override(&"normal_font_size", ThemeDB.get_project_theme().get_font_size(&"font_size", variation))  # RichTextLabel has no Label variation
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
	if _rack != null:
		_upgrades.add_child(_label("Cue rack", &"Heading"))
		_upgrades.add_child(_cue_row())
	for category in ShopCatalog.CATEGORIES:
		if category == &"drink":
			continue
		_upgrades.add_child(_label(CATEGORY_TITLES[category], &"Heading"))
		for it in ShopCatalog.in_category(category):
			_upgrades.add_child(_upgrade_row(it))


func _upgrade_row(it: ShopItem) -> Control:
	var why := economy.can_buy(it.id)
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = ROW_HEIGHT
	row.add_child(_icon(IconCatalog.upgrade(it), ROW_RIM, ROW_ICON))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_child(_label(it.display_name))
	text.add_child(_label(it.description, &"Caption", HORIZONTAL_ALIGNMENT_LEFT, true))
	row.add_child(text)
	var price := _label("$%d" % it.cost_cash, &"", HORIZONTAL_ALIGNMENT_RIGHT)
	price.custom_minimum_size.x = 84
	row.add_child(price)
	var buy := _button("Buy" if why == &"" else _refusal(why))
	buy.custom_minimum_size.x = UPGRADE_BUTTON_WIDTH  # one column whatever the refusal text says
	buy.clip_text = true
	buy.disabled = why != &""
	buy.pressed.connect(_buy_upgrade.bind(it.id))
	row.add_child(buy)
	_upgrade_buttons[it.id] = buy
	return row


## A new cue for the campaign's rack (08 §2.9): any phase, straight into the buyer's hand; the host checks it all again (`cue_buy`).
func _cue_row() -> Control:
	var me := multiplayer.get_unique_id()
	var cost := _rack.price()
	var why := &""
	if _rack.holds(me):
		why = &"has_cue"
	elif _rack.intact_count() >= CueRack.SLOTS:
		why = &"cues_full"
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = ROW_HEIGHT
	row.add_child(_icon(IconCatalog._load(&"upgrade", &"heavy_shaft"), ROW_RIM, ROW_ICON))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_child(_label("New cue"))
	text.add_child(_label("%d of the %d cues left in the campaign. Straight into your hand." % [_rack.intact_count(), CueRack.SLOTS], &"Caption", HORIZONTAL_ALIGNMENT_LEFT, true))
	row.add_child(text)
	var price := _label("$%d" % cost, &"", HORIZONTAL_ALIGNMENT_RIGHT)
	price.custom_minimum_size.x = 84
	row.add_child(price)
	var credit := why == &"" and economy.cash < cost  # 08 §2.9 step 3: on credit, washed off at the sink
	cue_button = _button(("Buy on credit" if credit else "Buy") if why == &"" else _refusal(why))
	if credit:
		cue_button.theme_type_variation = &"Danger"
		text.add_child(_label("No Cash for it: ZAP, then the sink.", &"Caption"))
	cue_button.custom_minimum_size.x = UPGRADE_BUTTON_WIDTH
	cue_button.clip_text = true
	cue_button.disabled = why != &""
	cue_button.pressed.connect(_rack.request_buy)
	row.add_child(cue_button)
	return row


func _buy_upgrade(item_id: StringName) -> void:
	economy.request_purchase.rpc_id(1, item_id)


# --- bits ---------------------------------------------------------------------------------------

func _name_of(item_id: StringName) -> String:
	var it := ShopCatalog.item(item_id)
	return it.display_name if it != null and not it.display_name.is_empty() else String(item_id).capitalize()


## `wrap` = flowing text (descriptions, effect lines); short single-line labels must not wrap or a narrow cell stacks them letter by letter.
func _label(text: String, variation := &"", align := HORIZONTAL_ALIGNMENT_LEFT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.horizontal_alignment = align
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A card is ~190 px of text wide: tighter padding and a size smaller than a plain button.
func _card_button(text: String) -> Button:
	var b := _button(text)
	b.theme_type_variation = &"CardButton"
	return b


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(120, BUTTON_HEIGHT)
	return b
