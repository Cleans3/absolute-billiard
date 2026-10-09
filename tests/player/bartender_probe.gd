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
