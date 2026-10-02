extends SceneTree
## Headless skins probe (06 P18): the catalog, the profile.json round-trip + fallbacks, the per-Round bar pick, the Skins screen.
##   godot --path . --headless -s tests/economy/skins_probe.gd
## Prints SKINS OK, or the failing checks and SKINS FAIL (exit 1).

var TEST_DIR := "user://test_skins_%d" % OS.get_process_id()  # per process: probes share user://

var fails := 0


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	call_deferred("_run")


func _write_raw(text: String) -> void:
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	var f := FileAccess.open(TEST_DIR.path_join("profile.json"), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _run() -> void:
	SaveManager.root = TEST_DIR
	_catalog()
	_profile()
	_pick()
	await _screen()
	DirAccess.remove_absolute(TEST_DIR.path_join("profile.json"))
	DirAccess.remove_absolute(TEST_DIR)
	print("SKINS OK" if fails == 0 else "SKINS FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _catalog() -> void:
	var chars := SkinCatalog.characters()
	var bars := SkinCatalog.bars()
	_check(chars.size() >= 6, "at least 6 selectable character skins (got %d)" % chars.size())
	_check(bars.size() >= 5, "at least 5 bar skins (got %d)" % bars.size())
	_check(not chars.any(func(s: CharacterSkin) -> bool: return s.id == SkinCatalog.BARTENDER), "the bartender is not selectable")
	_check(SkinCatalog.character(SkinCatalog.BARTENDER) != null and not SkinCatalog.is_selectable_character(SkinCatalog.BARTENDER), "the bartender still loads by id")
	_check(bars[0].id == SkinCatalog.DEFAULT_BAR, "the default bar lists first")
	var ids := {}
	for s in chars:
		_check(not ids.has(s.id) and s.display_name != "", "character %s has a unique id and a name" % s.id)
		ids[s.id] = true
	for i in 6:  # seats wrap past 4
		_check(SkinCatalog.default_character(i).id == SkinCatalog.SEAT_IDS[i % 4], "default skin of seat %d" % i)
	_check(SkinCatalog.resolve_character(&"", 2).id == &"seat_yellow", "nothing equipped = the seat colour")
	_check(SkinCatalog.resolve_character(&"no_such", 1).id == &"seat_blue", "an unknown id = the seat colour")
	_check(SkinCatalog.resolve_character(SkinCatalog.BARTENDER, 0).id == &"seat_red", "the bartender id is refused for a player")
	_check(SkinCatalog.resolve_bar(&"no_such").id == SkinCatalog.DEFAULT_BAR, "an unknown bar id = classic")


func _profile() -> void:
	_check(SkinCatalog.equipped_character_id() == &"" and SkinCatalog.equipped_bar_id() == SkinCatalog.DEFAULT_BAR, "no profile = defaults")
	var pick_c := SkinCatalog.characters()[1].id
	var pick_b := SkinCatalog.bars()[2].id
	SaveManager.save_persistent([&"lens_t3"] as Array[StringName])
	SkinCatalog.equip_character(pick_c)
	SkinCatalog.equip_bar(pick_b)
	_check(SkinCatalog.equipped_character_id() == pick_c and SkinCatalog.equipped_bar_id() == pick_b, "equip round-trips through profile.json")
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_DIR.path_join("profile.json")))
	_check(d.get("char_skin") == String(pick_c) and d.get("bar_skin") == String(pick_b), "profile.json carries char_skin and bar_skin")
	_check(SaveManager.load_persistent() == ([&"lens_t3"] as Array[StringName]), "saving skins keeps the persistent unlocks")
	SaveManager.save_persistent([&"lens_t2"] as Array[StringName])
	_check(SkinCatalog.equipped_character_id() == pick_c and SkinCatalog.equipped_bar_id() == pick_b, "saving unlocks keeps the skins")
	SkinCatalog.equip_character(&"no_such")
	SkinCatalog.equip_bar(&"no_such")
	_check(SkinCatalog.equipped_character_id() == pick_c and SkinCatalog.equipped_bar_id() == pick_b, "equipping an unknown id changes nothing")
	_write_raw('{"save_version": 2, "char_skin": "nope", "bar_skin": "nope"}')
	_check(SkinCatalog.equipped_character_id() == &"" and SkinCatalog.equipped_bar_id() == SkinCatalog.DEFAULT_BAR, "unknown ids in the file fall back")
	_write_raw('{"save_version": 2, "char_skin": "bartender"}')
	_check(SkinCatalog.equipped_character_id() == &"", "the bartender in the file falls back")
	_write_raw('{"save_version": 2, "persistent_unlocks": []}')
	_check(SkinCatalog.local_pick() == {char_skin = &"", bar_skin = SkinCatalog.DEFAULT_BAR}, "missing keys = defaults")
	_write_raw("not json")
	_check(SkinCatalog.local_pick() == {char_skin = &"", bar_skin = SkinCatalog.DEFAULT_BAR}, "a corrupt file = defaults")


## The host's pick: always a roster entry, a pure function of the key, every entry reachable, a new key per Round.
func _pick() -> void:
	var roster: Array = [
		{peer_id = 1, name = "A", bar_skin = &"classic"},
		{peer_id = 7, name = "B", bar_skin = &"tiki"},
		{peer_id = 9, name = "C", bar_skin = &"vaporwave"},
	]
	var hits := {}
	for r in 60:
		var key := BarSkinDirector.round_key(12345, 1, r)
		var e := BarSkinDirector.pick_entry(roster, key)
		_check(roster.has(e), "the pick is a roster entry")
		_check(BarSkinDirector.pick_entry(roster, key) == e, "the same key picks the same entry")
		hits[e.peer_id] = true
	_check(hits.size() == 3, "every crew member's bar comes up over 60 Rounds (%s)" % [hits.keys()])
	_check(BarSkinDirector.round_key(1, 2, 3) != BarSkinDirector.round_key(1, 2, 4) and BarSkinDirector.round_key(1, 2, 3) != BarSkinDirector.round_key(2, 2, 3), "the key follows the campaign and the Round")
	_check(BarSkinDirector.pick_entry([roster[1]], 99) == roster[1], "solo: your own bar")


func _screen() -> void:
	SkinCatalog.equip_character(&"seat_blue")
	SkinCatalog.equip_bar(SkinCatalog.DEFAULT_BAR)
	var screen: SkinsScreen = load("res://src/ui/SkinsScreen.tscn").instantiate()
	root.add_child(screen)
	await process_frame
	_check(screen.is_in_group(&"ui_modal") and not screen.is_open(), "the Skins screen is a closed ui_modal")
	var closed := [0]
	screen.closed.connect(func() -> void: closed[0] += 1)
	screen.open()
	await process_frame
	_check(screen.is_open(), "open() shows it")
	_check(screen.get("_sel_char") == &"seat_blue" and screen.get("_sel_bar") == SkinCatalog.DEFAULT_BAR, "it opens on the equipped skins")
	var cards: Dictionary = screen.get("_char_cards")
	var bar_cards: Dictionary = screen.get("_bar_cards")
	_check(cards.size() == SkinCatalog.characters().size() and bar_cards.size() == SkinCatalog.bars().size(), "one card per skin")
	_check(not cards.has(SkinCatalog.BARTENDER), "no bartender card")
	_check(cards[&"seat_blue"].badge.text == "Equipped" and cards[&"night_owl"].badge.text == "", "the equipped badge sits on the equipped card")
	# a tap previews (the Humanoid wears it) but does not equip; Equip persists at once
	cards[&"night_owl"].button.pressed.emit()
	var hum: Humanoid = screen.get("_hum")
	_check(hum.skin().id == &"night_owl", "the preview Humanoid wears the tapped skin")
	_check(SkinCatalog.equipped_character_id() == &"seat_blue", "previewing does not equip")
	screen.get_node("%EquipChar").pressed.emit()
	_check(SkinCatalog.equipped_character_id() == &"night_owl", "Equip writes the profile")
	_check(cards[&"night_owl"].badge.text == "Equipped" and cards[&"seat_blue"].badge.text == "", "the badge follows")
	_check(screen.get_node("%EquipChar").disabled, "an equipped skin's button is disabled")
	bar_cards[&"tiki"].button.pressed.emit()
	_check(SkinCatalog.equipped_bar_id() == SkinCatalog.DEFAULT_BAR, "a bar preview does not equip")
	screen.get_node("%EquipBar").pressed.emit()
	_check(SkinCatalog.equipped_bar_id() == &"tiki" and bar_cards[&"tiki"].badge.text == "Equipped", "Equip writes the bar skin")
	_check(screen.get_node("%Palette").get_child_count() == 6, "the palette lists wall, floor, wood, seats, felt, neon")
	screen.close()
	_check(not screen.is_open() and closed[0] == 1, "close() hides it and emits closed once")
	screen.close()
	_check(closed[0] == 1, "closing a closed screen emits nothing")
	screen.queue_free()
