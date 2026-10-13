extends SceneTree
## Run structure and tally (docs/plan/02 §3.4, §3.8, §3.11; 06 P37, P39): the three Campaign Nights and their knobs
## (quota, Round timer, fine rate), the Endless generator, RunStats counting + the D..S+ grade floors, and the end card.
## GameLoop wiring (mode gating, hooks, mirror) is in economy_probe; the save migration in save_probe.
##   godot --path . --headless -s tests/economy/run_probe.gd     prints RUN OK

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	_nights()
	_tally()
	_grade()
	_dict()
	await _card()
	if fails == 0:
		print("RUN OK")
	else:
		printerr("RUN FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


func _nights() -> void:
	var nights: Array[NightConfig] = load("res://src/levels/main_level.gd").NIGHTS
	_check(nights.size() == 3, "the Campaign is three Nights (%d)" % nights.size())
	for i in nights.size():
		_check(nights[i].night_number == i + 1, "Night %d is numbered %d" % [i + 1, nights[i].night_number])
		_check(nights[i].round_time_limit_sec >= NightConfig.ROUND_TIME_MIN_SEC, "Night %d: a Round is never under %d s" % [i + 1, NightConfig.ROUND_TIME_MIN_SEC])
	# 06 P37 / U14: an easy start that tightens: lower first quota, much longer Rounds early, fines that rise
	_check(nights[0].quota < 600 and nights[0].quota < nights[1].quota and nights[1].quota < nights[2].quota, "quotas rise from a Night 1 under the old $600")
	_check(nights[0].round_time_limit_sec >= 240.0 and nights[0].round_time_limit_sec >= nights[1].round_time_limit_sec and nights[1].round_time_limit_sec >= nights[2].round_time_limit_sec, "Round timers start long and taper (%s)" % [nights.map(func(n: NightConfig) -> float: return n.round_time_limit_sec)])
	_check(nights[0].fine_rate < nights[1].fine_rate and nights[1].fine_rate < nights[2].fine_rate and nights[2].fine_rate <= NightConfig.ENDLESS_FINE_RATE, "fine rates rise by Night")
	_check(nights[0].authored_racks.size() == 3 and nights[1].authored_racks.is_empty() and nights[2].authored_racks.is_empty(), "only Night 1 has authored racks")
	_check(nights[2].finale_racks.size() == 3 and nights[0].finale_racks.is_empty() and nights[1].finale_racks.is_empty(), "only Night 3 carries finale racks")
	_check(ShopCatalog.all().all(func(it: ShopItem) -> bool: return it.min_night <= nights.size()), "no Shop row is locked behind a Night the Campaign does not have")
	for e: Event in FxCatalog.EVENTS:
		_check(e.min_night <= nights.size(), "%s: min_night inside the Campaign" % e.id)
	# Endless: from the last Night's plain numbers, Rounds shorten to the floor, no authored or finale racks
	var prev := nights[2].round_time_limit_sec
	for n in range(4, 16):
		var c := NightConfig.endless(nights[2], n)
		_check(c.night_number == n and c.finale_racks.is_empty() and c.authored_racks.is_empty() and c.fine_rate == NightConfig.ENDLESS_FINE_RATE, "Endless Night %d: plain" % n)
		_check(c.round_time_limit_sec <= prev and c.round_time_limit_sec >= NightConfig.ROUND_TIME_MIN_SEC, "Endless Night %d: %.0f s, never longer than the Night before, never under the floor" % [n, c.round_time_limit_sec])
		_check(c.quota == roundi(nights[2].quota * pow(NightConfig.ENDLESS_QUOTA_MULT, n - 3)), "Endless Night %d: quota x1.6 per Night" % n)
		prev = c.round_time_limit_sec


func _tally() -> void:
	var s := RunStats.new()
	_check(s.score() == 0 and s.grade() == "D" and s.to_dict()["pots"] == 0, "a new run is empty and a D")
	# the chain: pots in a Shot + Shots in a row that potted; a foul breaks it; the best is kept
	s.on_pot()
	s.on_shot(30, &"", false)
	s.on_pot()
	s.on_pot()
	s.on_shot(80, &"Combo", false)  # 2 pots + 1 earlier Shot = 3
	_check(s.pots == 3 and s.best_combo == 3 and s.trick_shots == 1 and s.shots == 2 and s.best_shot == 80 and s.cash_earned == 110, "counters: %s" % [s.to_dict()])
	s.on_shot(0, &"", true)  # a foul: breaks the chain and earns nothing
	s.on_pot()
	s.on_shot(10, &"", false)
	_check(s.best_combo == 3 and s.fouls == 1 and s.cash_earned == 120, "the foul broke the chain; the best stays 3")
	s.on_shot(-50, &"", false)  # a penalty ball's negative payout earns nothing and is not a best
	_check(s.cash_earned == 120 and s.best_shot == 80, "a negative payout is not earnings")
	s.on_scratch()
	s.on_fine(15)
	s.on_tip(25)
	s.on_night_cleared()
	_check(s.scratches == 1 and s.fines_paid == 15 and s.cash_earned == 145 and s.nights_cleared == 1, "scratch, fine, tip and Night counted")
	# scoring: 100/Night, 4/pot, 10/combo link, 15/trick, -8/foul, 1 per $50
	var want := 1 * 100 + 4 * 4 + 3 * 10 + 1 * 15 - 8 + floori(145 * 0.02)
	_check(s.score() == want, "score %d == %d" % [s.score(), want])


## The grade floors, exactly: one point under is the grade below.
func _grade() -> void:
	_check(RunStats.GRADES == (["D", "C", "B", "A", "S", "S+"] as Array[String]) and RunStats.GRADE_FLOORS.size() == RunStats.GRADES.size(), "six grades, one floor each")
	for i in RunStats.GRADES.size():
		var floor_pts: int = RunStats.GRADE_FLOORS[i]
		_check(_with_score(floor_pts).grade() == RunStats.GRADES[i], "%d points is a %s (got %s)" % [floor_pts, RunStats.GRADES[i], _with_score(floor_pts).grade()])
		if i > 0:
			_check(_with_score(floor_pts - 1).grade() == RunStats.GRADES[i - 1], "%d points is a %s" % [floor_pts - 1, RunStats.GRADES[i - 1]])
	_check(_with_score(-400).grade() == "D" and _with_score(99999).grade() == "S+", "below zero is D, off the chart is S+")
	_check(RunStats.GRADE_FLOORS[0] == 0, "D starts at 0")
	for i in range(1, RunStats.GRADE_FLOORS.size()):
		_check(RunStats.GRADE_FLOORS[i] > RunStats.GRADE_FLOORS[i - 1], "floors ascend")


## A RunStats whose score() is exactly `target`: 4 per pot, 1 per $50 for the remainder (negative: fouls at -8).
func _with_score(target: int) -> RunStats:
	var s := RunStats.new()
	if target < 0:
		s.fouls = ceili(-target / 8.0)
		return s
	s.pots = target / 4
	s.cash_earned = 50 * (target % 4)
	assert(s.score() == target)
	return s


func _dict() -> void:
	var s := RunStats.new()
	s.on_pot()
	s.on_shot(500, &"BankShot", false)
	s.play_time = 61.27
	var d := s.to_dict()
	_check(is_equal_approx(d["play_time"], 61.3) and d["pots"] == 1, "play time rounds to a tenth")
	var through_json: Dictionary = JSON.parse_string(JSON.stringify(d))  # ints come back as floats
	var back := RunStats.from_dict(through_json)
	_check(back.to_dict() == d and back.grade() == s.grade() and RunStats.grade_of(through_json) == s.grade(), "to_dict -> JSON -> from_dict is lossless")
	var holder := RunStats.new()
	holder.apply(d)
	_check(holder.pots == 1 and holder.cash_earned == 500, "apply() adopts a snapshot")
	holder.apply({})
	_check(holder.pots == 0 and holder.play_time == 0.0 and holder.score() == 0, "a missing key reads as 0")


func _card() -> void:
	var s := RunStats.new()
	s.nights_cleared = 3
	s.pots = 58
	s.best_combo = 6
	s.trick_shots = 9
	s.best_shot = 1240
	s.cash_earned = 8420
	s.scratches = 2
	s.fines_paid = 70
	s.play_time = 3725.0
	var d := s.to_dict()
	var rows := RunStatsCard.rows(d)
	_check(rows.size() <= RunStatsCard.MAX_ROWS and rows.size() == 8, "the card lists %d rows, never more than %d" % [rows.size(), RunStatsCard.MAX_ROWS])
	var text := {}
	for r in rows:
		text[r[0]] = r[1]
	_check(text["Nights cleared"] == "3" and text["Balls potted"] == "58" and text["Best combo"] == "x6" and text["Trick shots"] == "9", "counts read plain")
	_check(text["Biggest shot"] == "$1,240" and text["Cash earned"] == "$8,420" and text["Scratches"] == "2  (fines $70)", "money groups thousands: %s" % [text])
	_check(text["Time played"] == "1:02:05" and RunStatsCard.format_time(59.0) == "0:59" and RunStatsCard.format_time(605.0) == "10:05", "time reads m:ss, h:mm:ss over an hour")
	# shown before and after it is in the tree, scrollable, grade at the bottom, inside a phone-height screen
	var early := RunStatsCard.make()
	early.show_stats(d, "You made it", true)
	root.add_child(early)
	var late := RunStatsCard.make()
	root.add_child(late)
	late.show_stats(d)
	await process_frame
	await process_frame
	for card: RunStatsCard in [early, late]:
		var rows_box: VBoxContainer = card.get_node("%Rows")
		var scroll: ScrollContainer = card.get_node("%Scroll")
		var column: Control = card.get_node("Center/Panel/Column")
		_check(rows_box.get_child_count() == 8 and scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "eight rows in a vertical scroll list")
		_check(scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page, "the list overflows its box, so it scrolls (%.0f > %.0f)" % [scroll.get_v_scroll_bar().max_value, scroll.get_v_scroll_bar().page])
		_check((card.get_node("%Grade") as Label).text == s.grade() and column.get_child(column.get_child_count() - 2) == card.get_node("%Grade"), "the grade %s sits at the bottom" % s.grade())
		_check(card.get_node("Center/Panel").get_combined_minimum_size().y <= 700.0 and card.get_node("Center/Panel").get_combined_minimum_size().x <= 640.0, "the card fits a 1280x720 screen: %s" % card.get_node("Center/Panel").get_combined_minimum_size())
	_check((early.get_node("%Title") as Label).text == "You made it" and (early.get_node("%Close") as Button).visible and not (late.get_node("%Close") as Button).visible, "title and the optional Close button")
	var closed := [false]
	early.closed.connect(func() -> void: closed[0] = true)
	(early.get_node("%Close") as Button).pressed.emit()
	_check(closed[0], "Close raises closed")
	early.free()
	late.free()
