extends SceneTree
## Wall blackboard (docs/plan/08 §2.9, adhoc-1010a C9) inside the real MainLevel: placed on the east wall facing into the room,
## and each line follows its own signal (Night/Round, viewers + hype, Hazard, Drinks, last Round, the Night's ask).
##   godot --path . --headless -s tests/ui/blackboard_probe.gd     prints BLACKBOARD OK

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


## The one place that waits for the bar after Solo: MainLevel loads on a thread behind the loading screen.
func _until_playable() -> void:
	await SoloSupport.until_playable(self)


func _run() -> void:
	SaveManager.root = "user://test_blackboard"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	var level := current_scene
	var bb: Blackboard = level.get_node("Blackboard")
	var loop: GameLoop = level.get_node("GameLoop")
	var stream: StreamManager = level.get_node("StreamManager")
	var fx: EffectManager = level.get_node("EffectManager")
	var econ: EconomyManager = level.get_node("EconomyManager")

	var at := bb.global_transform
	_check(at.origin.distance_to(Vector3(6.95, 1.95, -3.5)) < 0.001, "the board hangs on the east wall at (6.95, 1.95, -3.5): %s" % at.origin)
	_check((at.basis * Vector3.BACK).distance_to(Vector3.LEFT) < 0.001, "and faces into the room (-x)")
	_check(bb.get_node("Frame").mesh.size.x > 3.1 and bb.get_node("Frame").mesh.size.y > 1.7, "about 3.2 x 1.75 m (alpha's A#2)")

	_check(bb._header.text == "NIGHT 1  ·  NEXT ROUND 1/3", "between Rounds the board names the next one: %s" % bb._header.text)
	for id in [&"beer", &"flaming_shot", &"neighbours_round"]:  # served between Rounds, like the Bartender does
		fx.serve_drink(id, 1)
	_check(fx.live_drinks().size() == 4, "three Drinks and a neighbour's gift are live (%d)" % fx.live_drinks().size())
	var lines := bb._drinks.text.split("\n")
	_check(lines[0] == "DRINKS" and lines.size() == 4 and lines[3] == "+2 more" and lines[1].contains(" · "), "Drinks: two named lines, the rest counted: %s" % bb._drinks.text)
	loop.advance()
	await process_frame
	_check(bb._header.text == "NIGHT 1  ·  ROUND 1/3", "a live Round: %s" % bb._header.text)

	stream.add_viewers(250)
	stream.add_hype(0.37)
	var pct := roundi(stream.hype * 20.0) * 5
	_check(bb._viewers_label.text == "VIEWERS %d" % stream.viewers, "viewers follow the stream: %s" % bb._viewers_label.text)
	_check(bb._hype_label.text == "HYPE %d%%" % pct and is_equal_approx(float(bb._slate.get_shader_parameter(&"hype")), pct / 100.0), "hype in 5%% steps, label and bar agree: %s" % bb._hype_label.text)
	var before := bb._viewers_label.text
	stream.add_hype(0.01)  # inside the same step: nothing to rewrite
	_check(bb._viewers_label.text == before, "a change inside a hype step leaves the board alone")

	# 09 §3.4: every hazard's story line sits under its name, wrapped inside the board
	_check(bb._hazard_story.autowrap_mode != TextServer.AUTOWRAP_OFF and bb._hazard_story.width > 0.0, "the story line wraps")
	for e: Event in FxCatalog.EVENTS:
		_check(e.story_line != "", "%s has a story line" % e.id)
		fx.begin_event(e)
		_check(bb._hazard.text == e.display_name and bb._hazard_story.text == e.story_line, "%s: name and story line on the board: '%s' / '%s'" % [e.id, bb._hazard.text, bb._hazard_story.text])
		loop.round_ended.emit(&"cleared", 0)
		_check(bb._hazard_story.text == "", "%s: the story line leaves with the Hazard" % e.id)
	fx.begin_event(FxCatalog.EVENTS[0])
	_check(bb._hazard.text == FxCatalog.EVENTS[0].display_name, "a Hazard shows by name: %s" % bb._hazard.text)
	_check(bb._hazard_icon.visible and bb._hazard_icon.texture == IconCatalog.hazard(FxCatalog.EVENTS[0]), "the Hazard shows its icon")
	loop.round_started.emit(1, 120.0, 0)  # start counting the Round's Cash
	econ.add_cash(320, &"shot")
	econ.add_cash(-50, &"scratch")
	econ.add_cash(-100, &"shop")  # a purchase is not play
	loop.round_ended.emit(&"cleared", 140)
	_check(bb._footer.text.begins_with("LAST ROUND  Table cleared · 140 pts · +$270\n"), "last Round's result: %s" % bb._footer.text)
	_check(bb._hazard.text == "none" and bb._drinks.text == "DRINKS  none", "the Round ending clears the Hazard and the Drinks: %s / %s" % [bb._hazard.text, bb._drinks.text])
	_check(not bb._hazard_icon.visible, "the Round ending hides the Hazard icon")
	# 09 §3.5: the debt line is Moe's ledger
	_check(bb._footer.text.ends_with("\nMOE WANTS $600 · PAID SO FAR %s" % Blackboard.money(econ.cash)), "Nights 1-4: Moe's ledger, with the purse: %s" % bb._footer.text)
	econ.add_cash(-(econ.cash + 25), &"scratch")  # a scratch fine can leave the purse negative
	_check(econ.cash == -25 and bb._footer.text.ends_with("\nMOE WANTS $600 · PAID SO FAR -$25"), "a negative purse shows as it is: %s" % bb._footer.text)
	loop.night_started.emit(2, 1350)
	_check(bb._footer.text.ends_with("\nMOE WANTS $1,350 · PAID SO FAR -$25") and bb._footer.text.contains("LAST ROUND  none yet"), "a new Night: its demand, and no Round played yet: %s" % bb._footer.text)
	econ.add_cash(1500, &"shot")
	_check(bb._footer.text.ends_with("PAID SO FAR $1,475"), "the ledger follows the purse: %s" % bb._footer.text)
	loop.night_index = loop.nights.size() - 1
	loop.night_started.emit(5, 4500)
	_check(bb._footer.text.ends_with("\nTHE BUYOUT · $4,500 · LAST CALL"), "Night 5 is the Buyout: %s" % bb._footer.text)
	loop.night_index = loop.nights.size()
	loop.night_started.emit(6, 7200)
	_check(bb._footer.text.ends_with("\nMOE RAISED THE RATE · $7,200"), "Endless: Moe raised the rate: %s" % bb._footer.text)
	_check(Blackboard.money(0) == "$0" and Blackboard.money(999) == "$999" and Blackboard.money(1000) == "$1,000" and Blackboard.money(-25) == "-$25" and Blackboard.money(1234567) == "$1,234,567", "money groups thousands and puts the sign first")

	for n in [lobby, level]:
		if is_instance_valid(n):
			n.free()
	print("BLACKBOARD OK" if fails == 0 else "BLACKBOARD FAIL (%d)" % fails)
	quit(fails)
