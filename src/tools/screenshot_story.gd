extends SceneTree
## One-shot (REQ#adhoc-1011a:story S7): the story on screen. Presses Solo, then drives the game state the way the story probes do
## (tests/story/*) and saves a PNG per scene: the Night 1 cards, the ringing phone, Moe's call, the vote card with its story line,
## the blackboard on Night 2 and Night 5, the Reckoning / Game over lines, the three ending cards, the Endless card, velvet's toast.
## Needs a display (it renders): DISPLAY=:0 godot --path . -s src/tools/screenshot_story.gd
## Output: ~/work/.herdr/adhoc-1011a/story-shots/

const OUT := "/home/cleanse/work/.herdr/adhoc-1011a/story-shots/"

var level: Node
var loop: GameLoop
var cards: StoryCards
var cam: Camera3D


func _init() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(shot_name: String) -> void:
	await _frames(6)
	DirAccess.make_dir_recursive_absolute(OUT)
	var err := root.get_texture().get_image().save_png(OUT + shot_name + ".png")
	print("shot ", shot_name, " ", error_string(err))


func _until(cond: Callable, sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame


func _look(from: Vector3, at: Vector3, fov: float) -> void:
	cam.fov = fov
	cam.current = true
	cam.look_at_from_position(from, at)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://shots_story"
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, true)
	level = current_scene
	loop = level.get_node("GameLoop")
	cards = level.get_node("UILayer/StoryCards")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	var fx: EffectManager = level.get_node("EffectManager")
	var econ: EconomyManager = level.get_node("EconomyManager")
	var vote: EventVote = level.get_node("UILayer/EventVote")
	var director: StoryDirector = level.get_node("StoryDirector")
	cam = Camera3D.new()
	level.add_child(cam)
	await _until(func() -> bool: return cards.is_open(), 20.0)
	await _shot("01_cards_night1_card1")
	cards.advance()
	cards.advance()
	cards.advance()
	await _shot("02_cards_night1_card4")
	cards.advance()
	await _frames(3)

	# the phone: ringing, then Moe on speaker
	var phone := get_first_node_in_group(&"story_phone") as Phone
	var gus: Bartender = level.get_node("Bar/Bartender")
	_look(Vector3(4.3, 1.55, 3.3), Vector3(6.8, 1.3, 3.5), 50.0)
	await _until(func() -> bool: return phone.bubble.is_showing(), 6.0)
	await _shot("03_phone_ringing")
	world.player_position_source = func(_id: int) -> Vector3: return phone.prop.global_position + Vector3(1.0, 0.0, 0.0)
	world.request(&"answer_phone", 0)
	await create_timer(0.5).timeout
	await _shot("04_phone_call_moe_subtitle")
	director._call_left = 0.0
	await create_timer(0.3).timeout
	await _shot("05_phone_call_second_line")
	for i in 3:
		director._call_left = 0.0
		await _frames(2)
	phone.bubble.hide_line()
	gus.bubble.hide_line()

	# the vote card: the longest story lines
	var offer: Array[StringName] = [&"crowd_roar", &"lights_out", &"moving_pockets"]
	vote._on_offer(1, 1, offer)
	await _shot("06_vote_card_story_lines")
	vote.close()

	# the blackboard, Night 2 then Night 5
	_look(Vector3(3.4, 1.95, -3.5), Vector3(6.95, 1.95, -3.5), 40.0)
	loop.night_index = 1
	loop._begin_night()
	await _until(func() -> bool: return cards.is_open(), 3.0)
	cards.close()
	await _shot("07_cards_night2_card1_skipped_away")
	loop.advance()
	await _frames(4)
	fx.begin_event(FxCatalog.event(&"crowd_roar"))
	fx.serve_drink(&"beer", 1)
	econ.add_cash(325, &"shot")
	level.get_node("UILayer/HUD").visible = false
	await _shot("08_blackboard_night2")
	loop._end_round(&"timer")
	loop.night_index = 4
	loop._begin_night()
	await _until(func() -> bool: return cards.is_open(), 3.0)
	await _shot("09_cards_night5_card1")
	cards.close()
	loop.advance()
	await _frames(4)
	fx.begin_event(FxCatalog.event(&"moving_pockets"))
	for id in [&"beer", &"flaming_shot", &"neighbours_round"]:
		fx.serve_drink(id, 1)
	econ.add_cash(-(econ.cash + 25), &"scratch")  # a negative purse, as a scratch fine leaves it
	await _shot("10_blackboard_night5_buyout")
	econ.add_cash(300, &"shot")
	loop._end_round(&"timer")
	level.get_node("UILayer/HUD").visible = true

	# the phase screens
	loop.night_index = 0
	loop._set_phase(GameLoop.Phase.RECKONING)
	await _shot("11_reckoning_night1_paid_line")
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	await _shot("12_game_over_night1_short_line")
	loop.night_index = 4
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _shot("13_ending_card1")
	cards.advance()
	await _shot("14_ending_card2")
	cards.advance()
	await _shot("15_ending_card3_velvet")
	cards.advance()
	await _shot("16_campaign_won_after_cards")
	loop.night_index = 5
	loop._begin_night()
	await _until(func() -> bool: return cards.is_open(), 3.0)
	await _shot("17_endless_card")
	cards.close()
	var router := UIRouter.instance
	for m in get_nodes_in_group(&"ui_modal"):
		if m.visible:
			m.visible = false
	await _frames(3)
	_look(Vector3(0.0, 1.7, -0.5), Vector3(0.0, 1.0, -3.5), 70.0)
	director._chat_text = "first rack's always the loudest. enjoy it"
	director._show_chat()
	await _shot("18_velvet_toast")
	print("toast visible: ", router._toast_label.visible, " '", router._toast_label.text, "'")
	quit(0)
