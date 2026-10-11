extends SceneTree
## The quirky talking Bartender (C4, 06 P24): line pools, no back-to-back repeats, the special names a Drink that is
## really on the shelf, ambient lines on a timer, reactions to a scratch / trick / pot / miss / foul, the bubble, the
## voice blips and the gesture. Runs through the real MainLevel (solo).
##   godot --path . --headless -s tests/player/bartender_probe.gd
## Prints BARTENDER OK, or the failing checks and BARTENDER FAIL (exit 1).

var fails := 0
var finished := false
var said: Array = []  ## [text, pool]


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("BARTENDER FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Waits for a line of `pool` (or any when empty); returns it or [].
func _await_line(pool: StringName, seconds: float) -> Array:
	var from := said.size()
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		for i in range(from, said.size()):
			if pool == &"" or said[i][1] == pool:
				return said[i]
		await process_frame
	return []


## The one place a probe waits for the level to be playable after pressing Solo: MainLevel loads on a thread
## behind the loading screen.
func _until_playable() -> void:
	await SoloSupport.until_playable(self)


func _run() -> void:
	_pools()
	await process_frame
	SaveManager.root = "user://test_bartender"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	var level := current_scene
	var rd: RoundDirector = level.get_node("RoundDirector")
	var economy: EconomyManager = level.get_node("EconomyManager")
	var bartender := level.get_node_or_null("Bar/Bartender") as Bartender
	_check(bartender != null, "Bar/Bartender exists")
	var chat := bartender.chat
	chat.said.connect(func(text: String, pool: StringName) -> void: said.append([text, pool]))
	_check(bartender._humanoid._quirk == Humanoid.QUIRK_BARKEEP, "the Bartender wears the barkeep look")
	level.get_node("GameLoop").advance()
	await _frames(10)

	# ambient: the first line comes by itself, with a bubble and blips (spec: within 30 s; the director's first is <= 8 s)
	var first := await _await_line(&"", 12.0)
	_check(not first.is_empty(), "an unprompted line within 12 s")
	if not first.is_empty():
		_check(bartender.bubble.is_showing() and bartender.bubble.text() == first[0], "the line shows in the speech bubble")
		await create_timer(1.2).timeout
		_check(bartender.voice.blips_played > 0, "gibberish blips played (%d)" % bartender.voice.blips_played)
		_check(bartender._gesture != &"" or bartender._talk_left <= 0.0, "a gesture accompanies the line")

	# specials name a Drink that is on the shelf
	economy.roll_stock(5)
	var shelf := chat.shelf_names()
	_check(shelf.size() > 0, "the shelf has Drinks (%d)" % shelf.size())
	for i in 40:
		var line := chat.pick(&"special")
		var named := false
		for d in shelf:
			named = named or line.contains(d)
		_check(named and not line.contains("{"), "special names a shelf Drink and fills every token: '%s'" % line)
	economy.set_stock(6, [], [])
	_check(chat.shelf_names().is_empty(), "an empty shelf has no special")
	var wiped: Array[StringName] = []
	var wiped_left: Array[int] = []
	economy.set_stock(7, wiped, wiped_left)

	# never the same line twice in a row, in any pool, over several laps
	for pool: StringName in BartenderLines.POOLS:
		var last := ""
		var distinct := {}
		for i in 80:
			var line := chat.pick(pool)
			if pool != &"special":
				_check(line != last, "%s: no back-to-back repeat at pick %d" % [pool, i])
			last = line
			distinct[line] = true
		_check(pool == &"special" or distinct.size() >= minf(15.0, BartenderLines.POOLS[pool].size()), "%s: a lap uses many lines (%d)" % [pool, distinct.size()])

	# reactions: a scratch gets a sarcastic remark within a few seconds
	chat._busy = 0.0
	chat._queued = &""
	economy.fined.emit(&"scratch", 50)
	var scratch := await _await_line(&"neg_scratch", 6.0)
	_check(not scratch.is_empty(), "a scratch draws a neg_scratch line within 6 s")
	chat._busy = 0.0
	var tricks: Array[StringName] = [&"bank_shot"]
	rd.shot_ended.emit("probe_trick", 1, 2, tricks, false)
	_check(not (await _await_line(&"pos_trick", 6.0)).is_empty(), "a trick shot draws a pos_trick line")
	var none: Array[StringName] = []
	for case: Array in [[&"pos_pot", 1, false], [&"neg_miss", 0, false], [&"neg_foul", 0, true]]:
		chat.rng.seed = 7
		var got := false
		for attempt in 30:
			chat._busy = 0.0
			chat._queued = &""
			chat._last_scratch_msec = -100000
			var n := said.size()
			rd.shot_ended.emit("probe_%s_%d" % [case[0], attempt], 1, case[1], none, case[2])
			var line := await _await_line(case[0], 3.0)
			if not line.is_empty():
				got = true
				break
		_check(got, "%s reaction fires" % case[0])
	# a foul right after a scratch is covered by the scratch line (one remark, not two)
	chat._busy = 0.0
	chat._queued = &""
	var before := said.size()
	economy.fined.emit(&"scratch", 50)
	rd.shot_ended.emit("probe_scratch_foul", 1, 0, none, true)
	await create_timer(4.0).timeout
	var pools_after: Array = []
	for i in range(before, said.size()):
		pools_after.append(said[i][1])
	_check(pools_after == [&"neg_scratch"], "scratch + foul together: one remark, the scratch (%s)" % [pools_after])

	await _story(level, chat)

	finished = true
	print("BARTENDER OK" if fails == 0 else "BARTENDER FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _pools() -> void:
	for pool: StringName in BartenderLines.POOLS:
		var lines: Array = BartenderLines.POOLS[pool]
		_check(lines.size() >= 15, "%s has >= 15 lines (%d)" % [pool, lines.size()])
		_check(BartenderLines.GESTURE.has(pool), "%s has a gesture" % pool)
		var seen := {}
		for line: String in lines:
			_check(not seen.has(line), "%s: duplicate line '%s'" % [pool, line])
			seen[line] = true
			_check(line.length() <= 100, "%s: line fits the bubble (%d chars): '%s'" % [pool, line.length(), line])
			if pool == &"special":
				_check(line.contains("{drink}"), "special line names the drink: '%s'" % line)
	for pool in [&"pep", &"special", &"pitch", &"pos_pot", &"pos_trick", &"neg_scratch", &"neg_foul", &"neg_miss", &"cash_low", &"cash_high"]:
		_check(BartenderLines.POOLS.has(pool), "pool %s exists" % pool)


## 09 §3.3: Gus's story lines. Cumulative from Night 1, said once per campaign (and that survives a resume: the said set lives in the
## profile), 0.35 of the ambient rolls while any remain, and on the Buyout Night no sarcasm: no `neg_*` reaction, no `pitch`.
func _story(level: Node, chat: BartenderChat) -> void:
	var loop: GameLoop = level.get_node("GameLoop")
	var director: StoryDirector = level.get_node("StoryDirector")
	var campaign := loop.campaign_seed
	_check(not BartenderLines.POOLS.has(&"phone_ignored") and not BartenderLines.POOLS.has(&"story"), "story pools stay outside POOLS")
	_check(BartenderLines.lines_of(&"phone_ignored").size() == 3 and BartenderLines.GESTURE.has(&"story") and BartenderLines.GESTURE.has(&"phone_ignored"), "phone_ignored has its three lines; both story pools have a gesture")
	var night1: Array[String] = loop.nights[0].story.gus_lines
	var home_night := loop.night_index
	chat.hold(0.0)

	SaveManager.save_story_said(campaign, [] as Array[String])
	director._feed_gus()
	_check(chat.story_left() == night1.size(), "Night 1 unlocks its %d lines (%d)" % [night1.size(), chat.story_left()])
	var first := chat.pick(&"story")
	_check(first == night1[0] and chat.story_left() == night1.size() - 1, "the story is told in order, one line at a time: %s" % first)
	_check(SaveManager.story_said(campaign) == [night1[0]], "the said line is in the profile, keyed by this campaign")
	director._feed_gus()  # a resume / a reloaded level: the said set comes back from the profile
	_check(chat.story_left() == night1.size() - 1 and chat.pick(&"story") == night1[1], "a heard line is not told again after a reload")
	for i in 2:
		chat.pick(&"story")
	_check(chat.story_left() == 0 and chat.pick(&"story") == "", "a told story is spent")
	var picked_story := false
	for i in 300:
		picked_story = picked_story or chat._ambient_pool() == &"story"
	_check(not picked_story, "nothing rolls the story pool once it is spent")
	_check(SaveManager.story_said(campaign + 1).is_empty(), "another campaign starts with nothing heard")

	loop.night_index = 2  # Night 3: Nights 1-3 are unlocked (4 lines each)
	SaveManager.save_story_said(campaign, [] as Array[String])
	director._feed_gus()
	_check(chat.story_left() == 12 and chat.pick(&"story") == night1[0], "Night 3 holds the lines of Nights 1-3 (%d)" % chat.story_left())
	loop.night_index = 1
	SaveManager.save_story_said(campaign, [] as Array[String])
	director._feed_gus()
	chat.rng.seed = 11
	var rolls := 3000
	var story_rolls := 0
	for i in rolls:
		story_rolls += 1 if chat._ambient_pool() == &"story" else 0
	var share := float(story_rolls) / rolls
	_check(share > 0.30 and share < 0.40, "about %.0f%% of the ambient rolls go to the story while lines remain (%.3f)" % [BartenderChat.STORY_SHARE * 100.0, share])

	loop.night_index = loop.nights.size() - 1  # the Buyout Night
	_check(chat.is_final_night(), "the last campaign Night is the Buyout Night")
	var said5 := {}
	for i in 600:
		said5[chat._ambient_pool()] = true
	said5.erase(&"pep")
	said5.erase(&"story")
	_check(said5.is_empty(), "the Buyout Night is pep and story only: no pitch, special or cash joke (%s)" % [said5.keys()])
	chat._queued = &""
	chat.react(&"neg_miss", 3)
	_check(chat._queued == &"", "no negative reaction on the Buyout Night")
	chat.react(&"pos_trick", 3)
	_check(chat._queued == &"pos_trick", "the positive ones stay")
	chat._queued = &""
	loop.night_index = 3
	var pitched4 := false
	for i in 600:
		pitched4 = pitched4 or chat._ambient_pool() == &"pitch"
	_check(pitched4, "Night 4 still pitches")
	loop.night_index = home_night

	chat.hold(5.0)  # Moe is on the phone
	chat.react(&"pos_trick", 3)
	_check(chat.is_holding() and chat._queued == &"", "no reaction while Moe is on the phone")
	chat.release_hold()
	chat.react(&"pos_trick", 3)
	_check(chat._queued == &"pos_trick", "he talks again once the call is over")
