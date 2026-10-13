extends SceneTree
## 09 S5 + S6 through the real MainLevel (solo): every hazard's story line on its vote card (wrapped, inside the card), the
## cards above the vote above the phase screen, the Reckoning / Game over lines, the three ending cards before the Campaign
## won buttons, and an Endless Night's own card.
##   godot --path . --headless -s tests/story/story_ui_probe.gd      prints STORY UI OK

var fails := 0
var finished := false


func _init() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		if not finished:
			print("STORY UI FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for c in node.get_children():
		out += _all_text(c)
	return out


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_story_ui"
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, true)
	var level := current_scene
	var loop: GameLoop = level.get_node("GameLoop")
	var cards: StoryCards = level.get_node("UILayer/StoryCards")
	var vote: EventVote = level.get_node("UILayer/EventVote")
	var phase: PhaseScreen = level.get_node("UILayer/PhaseScreen")
	var router := UIRouter.instance
	var end := Time.get_ticks_msec() + 20000
	while not cards.is_open() and Time.get_ticks_msec() < end:
		await process_frame
	cards.close()  # Night 1's intro, not under test here
	await _frames(2)

	# --- C4: the vote card ---
	var ids: Array[StringName] = []
	for e: Event in FxCatalog.EVENTS:
		ids.append(e.id)
	_check(ids.size() == 8, "eight hazards")
	for start in range(0, ids.size(), 3):
		var offer: Array[StringName] = ids.slice(start, start + 3)
		vote._on_offer(1, 1, offer)
		await _frames(3)
		for i in offer.size():
			var e := FxCatalog.event(offer[i])
			var card: Button = vote._cards.get_child(i)
			var text := _all_text(card)
			_check(e.story_line != "" and text.contains(e.story_line), "%s: its story line is on the card" % e.id)
			_check(text.find(e.display_name) < text.find(e.story_line) and text.find(e.story_line) < text.find("reward"), "%s: the story line sits under the name, above the numbers" % e.id)
			var box: Control = card.get_child(0)
			var need := box.get_combined_minimum_size()
			_check(need.x <= card.custom_minimum_size.x and need.y <= card.custom_minimum_size.y, "%s: the card holds its content, needs %s of %s" % [e.id, need, card.custom_minimum_size])
			for l in box.find_children("*", "Label", true, false):
				if (l as Label).text == e.story_line:
					_check((l as Label).autowrap_mode != TextServer.AUTOWRAP_OFF, "%s: the story line wraps" % e.id)
		if start == 0:  # C1 + E10: the intro reads before the hazard vote, which waits stacked underneath
			cards.show_cards(["one", "two"] as Array[String])
			await _frames(2)
			_check(cards.is_open() and not vote.visible and router.current == cards, "the cards sit over the vote")
			cards.advance()
			cards.advance()
			await _frames(2)
			_check(not cards.is_open() and vote.visible and router.current == vote, "the vote returns when the cards close")
		vote.close()
	await _frames(2)

	# --- C7: the Reckoning and Game over lines ---
	for i in 3:
		var story: StoryNight = loop.nights[i].story
		loop.night_index = i
		loop._set_phase(GameLoop.Phase.RECKONING)
		_check(phase.visible and phase._text.text.begins_with(story.paid_line + "\n"), "Night %d reckoning opens with Moe's paid line: %s" % [i + 1, phase._text.text])
		loop._set_phase(GameLoop.Phase.GAME_OVER)
		_check(phase.visible and phase._title.text == "Game over" and phase._text.text.begins_with(story.short_line + "\n"), "Night %d game over opens with the short line: %s" % [i + 1, phase._text.text])
	loop.night_index = 3  # Endless has no Moe line: the plain numbers
	loop.mode = GameLoop.MODE_ENDLESS
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	_check(not phase._text.text.contains("\n\n") and not phase._text.text.begins_with("\n") and phase._text.text == phase._reckoning, "an Endless Night's Game over is just the numbers: %s" % phase._text.text)

	# --- the Buyout paid (Night 3, Campaign): the Campaign won buttons; the finale's ending cards come with the F3 rewrite ---
	loop.mode = GameLoop.MODE_CAMPAIGN
	loop.night_index = 2
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _frames(2)
	_check(loop.nights[2].story.ending_cards.is_empty() and not cards.is_open(), "Night 3's story has no ending cards yet, so nothing opens over the Campaign won screen")
	_check(phase.visible and phase._title.text == "Campaign won" and phase._next.text == "Endless" and phase._next.visible, "the Campaign won screen with its Endless button")

	# --- C1: an Endless Night opens with the Endless card, every Night ---
	loop.mode = GameLoop.MODE_ENDLESS
	for night_index in [3, 4]:
		loop.night_index = night_index
		loop._begin_night()
		await _frames(3)
		var endless: StoryNight = loop.current_night().story
		_check(cards.is_open() and cards.cards == endless.intro_cards and endless.night == 0, "Endless Night %d opens with the Endless card" % (night_index + 1))
		cards.advance()
		await _frames(2)
	_check(SaveManager.story_seen(loop.campaign_seed).has(4) and SaveManager.story_seen(loop.campaign_seed).has(5), "each Endless Night is seen on its own")

	finished = true
	print("STORY UI OK" if fails == 0 else "STORY UI FAIL (%d)" % fails)
	quit(fails)
