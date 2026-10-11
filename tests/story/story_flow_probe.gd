extends SceneTree
## 09 S2 + S3 + S6 (velvet) through the real MainLevel (solo): the intro cards open once per Night, skip, never reopen on a
## resume; the phone rings in the first Intermission, is answered once (Moe's call plays, Gus holds his tongue), a second
## answer is refused, an ignored phone stops when the Round goes live and Gus covers; velvet's line shows once per Night.
##   godot --path . --headless -s tests/story/story_flow_probe.gd      prints STORY FLOW OK

var fails := 0
var finished := false
var said: Array = []  ## [text, pool] from Gus


func _init() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		if not finished:
			print("STORY FLOW FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _until(cond: Callable, sec: float) -> bool:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_story"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, true)
	var level := current_scene
	var loop: GameLoop = level.get_node("GameLoop")
	var director: StoryDirector = level.get_node("StoryDirector")
	var cards: StoryCards = level.get_node("UILayer/StoryCards")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	var gus: Bartender = level.get_node("Bar/Bartender")
	var router := UIRouter.instance
	gus.chat.said.connect(func(text: String, pool: StringName) -> void: said.append([text, pool]))
	var phone := get_first_node_in_group(&"story_phone") as Phone
	_check(phone != null, "the wall phone exists")
	_check(await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION and cards.is_open(), 20.0), "Night 1's cards open at the Night start")

	# --- C1: cards ---
	var night1: StoryNight = loop.current_night().story
	_check(cards.cards == night1.intro_cards and router.current == cards, "the Night's own cards are up, as the one open modal")
	_check("*" not in cards._body.text and cards._body.text == night1.intro_cards[0], "card 1 text shown (emphasis marks dropped)")
	var tap := InputEventMouseButton.new()
	tap.button_index = MOUSE_BUTTON_LEFT
	tap.pressed = true
	cards._on_gui_input(tap)
	_check(cards.index == 1, "one tap, next card")
	var finished_with: Array = []
	cards.finished.connect(func(skipped: bool) -> void: finished_with.append(skipped))
	cards._skip.pressed.emit()
	await process_frame
	_check(not cards.is_open() and finished_with == [true], "Skip closes them all")
	_check(SaveManager.story_seen(loop.campaign_seed) == [1], "Night 1 is recorded as seen for this campaign")

	# --- C2: the phone ---
	_check(director.ringing and phone.is_ringing(), "the phone rings in the first Intermission")
	_check(phone.prop.collision_layer == Interactable.LAYER and phone.prop.prompt == "Answer the phone", "a ringing phone is a use target with its prompt")
	await create_timer(0.3).timeout
	_check(phone.rings >= 1 and phone.bubble.text() == "RING RING", "a RING RING bubble pulses")
	var refused: Array = []
	world.interaction_rejected.connect(func(_k: StringName, why: StringName) -> void: refused.append(why))
	world.player_position_source = func(_id: int) -> Vector3: return phone.prop.global_position + Vector3(1.0, 0.0, 0.0)
	world.request(&"answer_phone", 0)
	_check(director.answered and not director.ringing and not phone.is_ringing(), "answering stops the ring")
	_check(phone.prop.collision_layer == 0, "a quiet phone is no use target")
	_check(director.calling and phone.bubble.text() == "Moe: " + night1.call[0], "Moe's first line shows as a subtitle at the phone: %s" % phone.bubble.text())
	_check(gus.chat.is_holding(), "Gus holds his tongue while the call plays")
	await create_timer(0.6).timeout
	_check(phone.voice.blips_played > 0, "Moe's blips played (%d)" % phone.voice.blips_played)
	_check(is_equal_approx(phone.voice.pitch_mult, 0.6) and is_equal_approx(phone.voice.length_mult, 1.4), "Moe's voice is x0.6 pitch, x1.4 length")
	world.request(&"answer_phone", 0)
	_check(refused == [&"already_answered"], "a second answer is refused: %s" % [refused])
	for i in range(1, night1.call.size()):
		director._call_left = 0.0  # skip the wait, not the line
		await _frames(2)
		_check(phone.bubble.text() == "Moe: " + night1.call[i], "call line %d shows: %s" % [i + 1, phone.bubble.text()])
	director._call_left = 0.0
	await _frames(2)
	_check(not director.calling and not gus.chat.is_holding(), "the call ends and Gus may talk again")
	_check(not director.ringing, "an answered phone stays quiet")
	_check(SaveManager.story_called(loop.campaign_seed) == [1], "Night 1's call is recorded as heard for this campaign")
	for i in 2:  # Resume of Night 1's start checkpoint, twice: the heard call does not ring again (gamma F3)
		loop.round_index = 0
		loop.night_index = 0
		loop._begin_night()
		await _frames(3)
		_check(director.answered and not director.ringing and not phone.is_ringing(), "resume %d of an answered Night's start: the phone stays quiet" % (i + 1))

	# --- C2: the ignored phone, C1: Night 2's cards, C8: velvet ---
	loop.night_index = 1
	loop._begin_night()  # Night 2 start, as the next Night does
	_check(await _until(func() -> bool: return cards.is_open(), 3.0) and cards.cards == loop.current_night().story.intro_cards, "Night 2's cards open")
	cards.advance()
	cards.advance()
	_check(not cards.is_open() and SaveManager.story_seen(loop.campaign_seed) == [1, 2], "reading the last card closes them; Night 2 is seen")
	_check(director.ringing and not director.answered, "Night 2's phone rings again")
	said.clear()
	loop.advance()  # nobody answers: the Round goes live
	await process_frame
	_check(not director.ringing and not phone.is_ringing(), "the ring stops when the Round goes live")
	await _until(func() -> bool: return said.any(func(s: Array) -> bool: return s[1] == &"phone_ignored"), 6.0)
	_check(said.any(func(s: Array) -> bool: return s[1] == &"phone_ignored" and BartenderLines.PHONE_IGNORED.has(s[0])), "Gus covers with a phone_ignored line")
	_check(director.velvet_shown == 0, "velvet has not spoken yet")
	director._chat_in = 0.1  # the 15 s wait, shortened
	await _until(func() -> bool: return director.velvet_shown == 1, 3.0)
	_check(director.velvet_shown == 1 and router._toast_label.text == "velvet: " + loop.current_night().story.chat_line, "velvet's line is a toast: '%s'" % router._toast_label.text)

	# --- C1: a resume never reopens a seen Night, nor a Night mid-way ---
	loop.round_index = 0
	loop.night_index = 1
	loop._begin_night()
	await _frames(3)
	_check(not cards.is_open(), "a Night this player has seen opens no cards on a resume")
	loop.night_index = 2  # Night 3 is unseen, but the resume lands on a Round boundary
	loop.round_index = 1
	loop.night_started.emit(3, 1350)
	await _frames(3)
	_check(not cards.is_open(), "a mid-Night resume never opens the cards")
	_check(not SaveManager.story_seen(loop.campaign_seed).has(3), "...and does not mark the Night seen")

	finished = true
	print("STORY FLOW OK" if fails == 0 else "STORY FLOW FAIL (%d)" % fails)
	quit(fails)
