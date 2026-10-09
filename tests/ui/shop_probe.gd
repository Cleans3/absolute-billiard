extends SceneTree
## Shop UI probe (polish 2, C11 C12 C15): the Bartender panel keeps its size in every mode, phase, shelf and refusal text;
## Serve / Throw never leave a hidden target selected; no card clips its content; every Drink, Upgrade and hazard
## has an icon of its own, distinct from the others, shown on the card, the row and the vote.
##   godot --path . --headless -s tests/ui/shop_probe.gd
## Prints SHOP OK, or the failing checks and SHOP FAIL (exit 1).

const COUNTER := Vector3(3.5, 0.05, 2.5)  # customer side of the counter: the Player closes the menu when out of reach

var fails := 0
var finished := false
var level: Node
var menu: BartenderMenu
var econ: EconomyManager
var loop: GameLoop
var player: Player
var panel_size := Vector2.ZERO
var picks: Array = []
var net: Variant  ## the NetManager autoload, by path: probes compile before autoloads


func _init() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		if not finished:
			print("SHOP FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	net = root.get_node("NetManager")
	SaveManager.root = "user://test_shop"
	DirAccess.make_dir_recursive_absolute(SaveManager.root.path_join("checkpoints"))
	_icons()
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _frames(8)
	level = current_scene
	menu = level.get_node("UILayer/BartenderMenu")
	econ = level.get_node("EconomyManager")
	loop = level.get_node("GameLoop")
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	var panel: Control = menu.get_node("Panel")
	panel_size = Vector2(panel.offset_right - panel.offset_left, panel.offset_bottom - panel.offset_top)
	menu.picked.connect(func(k: StringName, id: StringName, t: int) -> void: picks.append([k, id, t]))
	econ.add_cash(5000, &"probe")
	await _stand_at_counter()
	await _sizes()
	await _modes()
	await _texts()
	await _upgrades()
	await _vote()
	DirAccess.remove_absolute(SaveManager.root)
	finished = true
	print("SHOP OK" if fails == 0 else "SHOP FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _stand_at_counter() -> void:
	player.collision_mask |= 1
	player.global_position = COUNTER
	player.velocity = Vector3.ZERO
	for i in 6:
		await physics_frame


# --- icons: one file per row, none missing, none alike ----------------------------------------------------

func _icons() -> void:
	var kinds := {&"drink": [], &"hazard": [], &"upgrade": []}
	for d: Drink in FxCatalog.DRINKS:
		kinds[&"drink"].append([d.id, IconCatalog.drink(d)])
	for e: Event in FxCatalog.EVENTS:
		kinds[&"hazard"].append([e.id, IconCatalog.hazard(e)])
	for it in ShopCatalog.all():
		if it.category != &"drink":
			kinds[&"upgrade"].append([it.id, IconCatalog.upgrade(it)])
		else:
			_check(IconCatalog.upgrade(it) == IconCatalog.drink(it.payload), "a Drink's shop item shows its glass: %s" % it.id)
	_check(kinds[&"drink"].size() >= 26 and kinds[&"hazard"].size() >= 8 and kinds[&"upgrade"].size() >= 16, "the catalogs are as large as the art: %d / %d / %d" % [kinds[&"drink"].size(), kinds[&"hazard"].size(), kinds[&"upgrade"].size()])
	for kind: StringName in kinds:
		var seen := {}
		for row: Array in kinds[kind]:
			var p := IconCatalog.path(kind, row[0])
			_check(row[1] != null, "%s %s has an icon" % [kind, row[0]])
			_check(ResourceLoader.exists(p), "%s %s has its own file (%s), not the unknown fallback" % [kind, row[0], p])
			if row[1] != null:
				_check(row[1].get_width() >= 96, "%s %s icon is %d px wide" % [kind, row[0], row[1].get_width()])
			var hash := FileAccess.get_sha256(p)
			_check(not seen.has(hash), "%s %s is not the same picture as %s" % [kind, row[0], seen.get(hash)])
			seen[hash] = row[0]
		_check(ResourceLoader.exists(IconCatalog.path(kind, &"unknown")), "%s has an unknown fallback" % kind)


# --- the panel never changes size -----------------------------------------------------------------------

func _panel_ok(tag: String) -> void:
	var p: Control = menu.get_node("Panel")
	_check(p.size == panel_size, "%s: panel is %s, not %s" % [tag, p.size, panel_size])


## Every Drink on the shelf, five at a time, in both modes: the panel holds still and no card clips anything.
func _sizes() -> void:
	var all: Array[StringName] = []
	for d: Drink in FxCatalog.DRINKS:
		all.append(d.id)
	for phase_name in ["intermission", "live"]:
		if phase_name == "live":
			loop.advance()
			await _frames(4)
			_check(loop.phase == GameLoop.Phase.ROUND_LIVE, "the Round is live")
			await _stand_at_counter()
		menu.open()
		await _frames(2)
		_check(menu.visible, "%s: the menu opens at the counter" % phase_name)
		_panel_ok("%s open" % phase_name)
		for mode in [&"bar_serve", &"throw_drink"]:
			menu.set_mode(mode)
			for start in range(0, all.size(), 5):
				var ids: Array[StringName] = all.slice(start, start + 5)
				var left: Array[int] = []
				for i in ids.size():
					left.append(0 if (start + i) % 7 == 3 else 1 + i % 3)  # a few sold out
				econ.set_stock(econ.stock_key, ids, left)
				await _frames(3)
				var tag := "%s %s shelf %d" % [phase_name, mode, start]
				_panel_ok(tag)
				_check(menu._cards.get_child_count() == ids.size(), "%s: a card per offer" % tag)
				for card: Control in menu._cards.get_children():
					var frame: Control = card.get_child(0)
					_check(card.get_combined_minimum_size() == BartenderMenu.CARD_SIZE, "%s: card minimum is %s" % [tag, card.get_combined_minimum_size()])
					var need := frame.get_combined_minimum_size()
					_check(need.x <= BartenderMenu.CARD_SIZE.x and need.y <= BartenderMenu.CARD_SIZE.y, "%s: a card clips its content, needs %s of %s (%s)" % [tag, need, BartenderMenu.CARD_SIZE, _all_text(frame).replace("\n", " | ")])
				_check(menu._cards.get_combined_minimum_size().x <= menu._tabs.size.x, "%s: the shelf fits the panel (%s of %s)" % [tag, menu._cards.get_combined_minimum_size().x, menu._tabs.size.x])
		econ.set_stock(econ.stock_key, [] as Array[StringName], [] as Array[int])
		await _frames(3)
		_panel_ok("%s empty shelf" % phase_name)
		menu.close()


# --- Serve / Throw keep one coherent selection ---------------------------------------------------------

func _modes() -> void:
	var me := root.multiplayer.get_unique_id()
	var roster: Array = net.get_roster()
	var shelf: Array[StringName] = [&"beer", &"energy_drink", &"static_shot", &"moonshine", &"bar_nuts"]
	econ.set_stock(econ.stock_key, shelf, [3, 2, 1, 1, 3] as Array[int])
	roster.append({peer_id = 77, name = "A crew member with a really very long name indeed", seat = 1, ready = true})
	net.roster_changed.emit()
	menu.open()
	await _frames(2)
	_check(menu.kind == &"bar_serve" and menu.target_peer == me, "opens on Serve with You selected: %s %d" % [menu.kind, menu.target_peer])
	_check(menu._targets.size() == 2 and menu._targets[me].button_pressed, "two targets, You pressed")
	_panel_ok("long crew name")
	menu._targets[77].pressed.emit()
	_check(menu.target_peer == 77 and menu._targets[77].button_pressed and not menu._targets[me].button_pressed, "tapping the crewmate selects them")
	menu.set_mode(&"throw_drink")
	await _frames(2)
	_check(menu.target_peer == 0 and menu._targets.is_empty() and not menu._target_row.visible, "Throw: no hidden target stays selected (%d)" % menu.target_peer)
	_check(menu._throw.button_pressed and not menu._serve.button_pressed, "Throw is the pressed mode")
	_panel_ok("throw")
	picks.clear()
	menu.drink_button(&"beer").pressed.emit()
	_check(picks.size() == 1 and picks[0][0] == &"throw_drink" and picks[0][2] == me, "a throw reports no crewmate target: %s" % [picks])
	_check(not menu.visible, "a throw closes the menu")
	menu.open()
	await _frames(2)
	menu.set_mode(&"bar_serve")
	await _frames(2)
	_check(menu.target_peer == me and menu._targets[me].button_pressed and menu._target_row.visible, "back on Serve it is You again, not the crewmate: %d" % menu.target_peer)
	menu._targets[77].pressed.emit()
	menu.close()
	menu.open()
	await _frames(2)
	_check(menu.kind == &"bar_serve" and menu.target_peer == me and menu._tabs.current_tab == 0, "reopening resets to Drinks / Serve / You")
	menu._targets[77].pressed.emit()
	roster.pop_back()  # the crewmate leaves while selected
	net.roster_changed.emit()
	await _frames(2)
	_check(menu.target_peer == me and menu._targets.size() == 1, "a departed crewmate is not selected: %d" % menu.target_peer)
	_panel_ok("roster change")
	menu.close()


# --- every refusal text fits where it is shown ------------------------------------------------------------

func _texts() -> void:
	menu.open()
	await _frames(2)
	for reason: StringName in BartenderMenu.REASON_TEXT:
		var b: Button = menu._card_button(BartenderMenu.REASON_TEXT[reason])
		menu.add_child(b)
		await process_frame
		var inner := BartenderMenu.CARD_SIZE.x - 28.0
		_check(b.get_combined_minimum_size().x <= inner, "card button '%s' (%s) needs %d of %d px" % [BartenderMenu.REASON_TEXT[reason], reason, b.get_combined_minimum_size().x, inner])
		b.queue_free()
		menu._on_rejected(&"beer", reason)
		await process_frame
		_panel_ok("status line for %s" % reason)
	for reason: StringName in BartenderMenu.WHEN_TEXT:
		var l: Label = menu._label(BartenderMenu.WHEN_TEXT[reason], &"Caption")
		menu.add_child(l)
		var b: Button = menu._button(BartenderMenu.WHEN_TEXT[reason])
		menu.add_child(b)
		await process_frame
		_check(l.get_combined_minimum_size().x <= BartenderMenu.CARD_SIZE.x - 28.0, "gate line '%s' needs %d px" % [l.text, l.get_combined_minimum_size().x])
		_check(b.get_combined_minimum_size().x <= BartenderMenu.UPGRADE_BUTTON_WIDTH, "upgrade button '%s' needs %d of %d px" % [b.text, b.get_combined_minimum_size().x, BartenderMenu.UPGRADE_BUTTON_WIDTH])
		l.queue_free()
		b.queue_free()
	menu._on_rejected(&"unheard_of", &"some_new_reason")
	_panel_ok("an unknown reason")
	menu.close()


func _upgrades() -> void:
	menu.open()
	menu.set_tab(1)
	await _frames(3)
	_panel_ok("upgrades")
	var rows := 0
	for it in ShopCatalog.all():
		if it.category == &"drink":
			continue
		var buy := menu.upgrade_button(it.id)
		_check(buy != null, "upgrade row %s exists" % it.id)
		if buy == null:
			continue
		rows += 1
		var icons := buy.get_parent().find_children("*", "TextureRect", true, false)
		_check(icons.size() == 1 and (icons[0] as TextureRect).texture == IconCatalog.upgrade(it), "upgrade row %s shows its icon" % it.id)
		_check(buy.get_combined_minimum_size().x <= BartenderMenu.UPGRADE_BUTTON_WIDTH, "upgrade button %s fits" % it.id)
	_check(rows >= 16, "%d upgrade rows" % rows)
	menu.close()


# --- hazard vote ---------------------------------------------------------------------------------------------

func _vote() -> void:
	var vote: EventVote = level.get_node("UILayer/EventVote")
	var ids: Array[StringName] = []
	for e: Event in FxCatalog.EVENTS:
		ids.append(e.id)
	for start in range(0, ids.size(), 3):
		var offer: Array[StringName] = ids.slice(start, start + 3)
		vote._on_offer(1, 1, offer)
		await _frames(2)
		_check(vote._cards.get_child_count() == offer.size(), "a card per hazard")
		for i in offer.size():
			var icons := vote._cards.get_child(i).find_children("*", "TextureRect", true, false)
			_check(icons.size() == 1 and (icons[0] as TextureRect).texture == IconCatalog.hazard(FxCatalog.event(offer[i])), "hazard card %s shows its icon" % offer[i])
		vote.close()
	var forced: Array[StringName] = [ids[0]]
	vote._on_offer(1, 1, forced)
	await _frames(2)
	_check(vote._ok.visible and vote._cards.get_child_count() == 1 and vote._cards.get_child(0).find_children("*", "TextureRect", true, false).size() == 1, "a forced hazard is announced with its icon and a button")
	vote._ok.pressed.emit()


## Every Label / Button text under `node`, joined: what a player can read on a card.
func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for c in node.get_children():
		out += _all_text(c)
	return out
