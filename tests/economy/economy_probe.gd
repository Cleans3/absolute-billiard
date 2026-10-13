extends SceneTree

## Headless economy probe (M1 C6/C7; docs/plan/02 §3.2–3.5, §3.11): the Shot_Cash arithmetic against the
## income sheet, viewer/hype/tip rules, a full Night driven through GameLoop with a fake RoundDirector, the Campaign /
## Endless gating of the final Night, and the run tally the loop's signals feed.
##   godot --path . --headless -s tests/economy/economy_probe.gd
## Prints ECONOMY OK, or the failing checks and ECONOMY FAIL (exit 1).

const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")
const NIGHT_2 := preload("res://src/resources/nights/night_2.tres")
const RED := preload("res://src/resources/ball_types/red_basic.tres")
const HUD_SCENE := preload("res://src/ui/HUD.tscn")
const PHASE_SCENE := preload("res://src/ui/PhaseScreen.tscn")
const COMBO: Array[StringName] = [&"Combo"]

var fails := 0
var finished := false
var _balls: Array[Ball] = []  # bare Balls own a physics body: freed before quit


## Stands in for RoundDirector: same signal names/args (plan.md amendments), no table.
class FakeDirector:
	extends Node
	signal ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)
	signal shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)
	signal table_cleared(round_id: String)
	signal cue_respawned(reason: StringName)
	var shot_in_progress := false
	var started: Array = []  # [config, round_index, seed] per start_round
	var ended := 0

	func start_round(config: NightConfig, round_index: int, round_seed: int) -> void:
		started.append([config, round_index, round_seed])

	func end_round() -> void:
		ended += 1

	func shot(points: int, tricks: Array[StringName] = [], foul := false) -> void:
		shot_ended.emit("s", 1, points, tricks, foul)


func _init() -> void:
	# a script error inside the coroutine ends it silently, so a watchdog turns that into a FAIL
	create_timer(20.0).timeout.connect(func() -> void:
		if not finished:
			print("ECONOMY FAIL (script error or hang)")
			quit(1))
	_run()


func _run() -> void:
	await process_frame  # autoloads (NetManager) exist from here on
	_arithmetic()
	_stream()
	await _loop()
	await _modes()
	await _run_stats()
	for ball in _balls:
		ball.free()
	finished = true
	if fails == 0:
		print("ECONOMY OK")
	else:
		print("ECONOMY FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _rig(viewers: int, hype: float) -> EconomyManager:
	var stream := StreamManager.new()
	stream.viewers = viewers
	stream.hype = hype
	var economy := EconomyManager.new()
	economy.stream = stream
	root.add_child(stream)  # in the tree, so quit() frees them
	root.add_child(economy)
	return economy


func _arithmetic() -> void:
	# 02 §3.5 Night 1: mean viewers 400, hype 0.6 -> scalar 1.64
	var economy := _rig(400, 0.6)
	_check(is_equal_approx(economy.stream.viewer_scalar(), 1.64), "viewer_scalar 400/0.6 == 1.64")
	_check(is_equal_approx(_rig(0, 0.0).stream.viewer_scalar(), 1.0), "viewer_scalar of an empty stream == 1")
	_check(is_equal_approx(_rig(1000, 1.0).stream.viewer_scalar(), 3.0), "viewer_scalar 1000/1.0 == 3")
	# 18 pots x 100 x 1.15 x 1.64 x 0.3 = 1018.44, as one shot and as six 3-pot shots (rounding drift)
	_check(economy.award_shot_reward(1800, COMBO, &"") == 1018, "Night 1 row, one shot == $1018")
	economy = _rig(400, 0.6)
	for i in 6:
		economy.award_shot_reward(300, COMBO, &"")
	_check(absi(economy.cash - 1018) <= 5, "Night 1 row, six shots within $5 of $1018 (got %d)" % economy.cash)
	# a -250 black on Night 1 costs $141 (02 §3.5)
	_check(_rig(400, 0.6).award_shot_reward(-250, COMBO, &"") == -141, "black penalty == -$141")
	# only trick_ids[0] pays
	var both: Array[StringName] = [&"RailRunner", &"Combo"]
	_check(_rig(0, 0.0).award_shot_reward(100, both, &"") == roundi(100 * 1.60 * 0.3), "payout uses trick_ids[0] only")
	# reckoning: pay, bank the overpay; final Night demand = 1.5 x quota
	economy = _rig(0, 0.0)
	economy.add_cash(700, &"shot")
	_check(economy.evaluate_quota(NIGHT_1) and economy.cash == 700 - NIGHT_1.quota, "Night 1's quota paid from 700, the rest banks")
	_check(economy.demand_for(NIGHT_1, true) == roundi(NIGHT_1.quota * 1.5), "final-night demand == 1.5 x quota")
	var banked_after := economy.cash
	_check(not economy.evaluate_quota(NIGHT_2) and economy.cash == banked_after, "short of quota: nothing paid, run ends")


func _stream() -> void:
	var config := NightConfig.new()
	config.base_viewers = 400
	var stream := StreamManager.new()
	root.add_child(stream)
	var tips: Array[int] = []
	stream.tip_received.connect(func(amount: int) -> void: tips.append(amount))
	stream.reset_for_night(config, 7)
	var no_tricks: Array[StringName] = []
	for i in 4:
		stream.on_ball_potted(_ball(), "s", &"")
	stream.on_ball_potted(_ball(true), "s", &"")  # a scratched cue ball is not a pot
	stream.on_shot_ended(400, COMBO, false)
	_check(stream.viewers == 400 + 4 * 25 + 100, "4 pots + trick pot = +200 viewers (got %d)" % stream.viewers)
	_check(is_equal_approx(stream.hype, 0.4), "hype +0.1 per pot")
	_check(tips.size() == 1 and tips[0] >= 25 and tips[0] <= 150, "500 milestone rolls one $25-150 tip")
	stream.on_shot_ended(0, no_tricks, true)
	_check(stream.viewers == 550 and is_equal_approx(stream.hype, 0.1), "foul: -50 viewers, -0.3 hype")
	stream.on_shot_ended(0, no_tricks, true)
	_check(is_equal_approx(stream.hype, 0.0), "hype floors at 0")
	_check(tips.size() == 1, "no second tip for the same milestone")
	var again: Array[int] = []
	var twin := StreamManager.new()
	root.add_child(twin)
	twin.tip_received.connect(func(amount: int) -> void: again.append(amount))
	twin.reset_for_night(config, 7)
	for i in 4:
		twin.on_ball_potted(_ball(), "s", &"")
	twin.on_shot_ended(400, COMBO, false)
	_check(again == tips, "same seed, same tip")


func _ball(cue := false) -> Ball:
	var ball := Ball.new()
	ball.is_cue_ball = cue
	_balls.append(ball)
	return ball


## A Night through GameLoop: a foul costs exactly one shot, every Round-end reason, Reckoning both ways.
func _loop() -> void:
	var director := FakeDirector.new()
	var economy := EconomyManager.new()
	var stream := StreamManager.new()
	var loop := GameLoop.new()
	economy.stream = stream
	loop.round_director = director
	loop.economy = economy
	loop.stream = stream
	var nights: Array[NightConfig] = [NIGHT_1, NIGHT_2]
	loop.nights = nights
	for node in [director, stream, economy, loop]:
		root.add_child(node)
	var hud := HUD_SCENE.instantiate()
	hud.game_loop = loop
	hud.economy = economy
	root.add_child(hud)
	var phase_screen: PhaseScreen = PHASE_SCENE.instantiate()
	phase_screen.game_loop = loop
	phase_screen.economy = economy
	root.add_child(phase_screen)
	var reasons: Array[StringName] = []
	loop.round_ended.connect(func(reason: StringName, _points: int) -> void: reasons.append(reason))
	var over: Array[bool] = []
	loop.night_ended.connect(func(success: bool, _demand: int) -> void: over.append(success))

	loop.start_campaign()
	_check(loop.phase == GameLoop.Phase.INTERMISSION and stream.viewers == 100, "Night 1 opens in Intermission, viewers = base")
	_check(not phase_screen.visible, "PhaseScreen: the Intermission has no screen (players press GO LIVE in the bar)")
	loop.advance()
	_check(loop.phase == GameLoop.Phase.ROUND_LIVE and loop.shots_left == 10, "advance() starts Round 1 with 10 shots")
	_check(not phase_screen.visible, "PhaseScreen: closes while a Round is live")
	_check(director.started.size() == 1 and director.started[0][1] == 1, "start_round(config, 1, seed) called")
	_check(director.started[0][2] == loop.round_seed, "HUD seed == seed handed to RoundDirector")
	director.shot(0, [], true)
	_check(loop.shots_left == 9 and economy.cash == 0, "foul costs exactly one shot and pays nothing")
	_check(hud.get_node("%Payout").text == "FOUL", "HUD: foul line")
	director.shot(500, COMBO)
	_check(loop.shots_left == 8 and economy.cash > 0, "clean shot pays and costs one shot")
	_check(hud.get_node("%Payout").text.begins_with("Combo x1.15  +$"), "HUD: trick payout line (%s)" % hud.get_node("%Payout").text)
	for i in 8:
		director.shot(0)
	_check(loop.phase == GameLoop.Phase.INTERMISSION and reasons == [&"shots"], "shots_left 0 ends the Round (shots)")
	# Round 2: timer expiry waits out a live shot
	loop.advance()
	director.shot_in_progress = true
	loop._process(1000.0)
	_check(loop.phase == GameLoop.Phase.ROUND_LIVE, "timer expiry mid-shot waits for shot_ended")
	director.shot(0)
	_check(loop.phase == GameLoop.Phase.INTERMISSION and reasons[-1] == &"timer", "then the Round ends (timer)")
	# Round 3: table_cleared, with plenty of cash so the quota passes
	director.shot_in_progress = false
	loop.advance()
	economy.add_cash(700, &"shot")
	director.shot(0)
	director.table_cleared.emit("n1-r3")
	_check(reasons[-1] == &"cleared" and loop.phase == GameLoop.Phase.RECKONING, "table_cleared ends Round 3 -> Reckoning")
	await process_frame  # end_round is deferred out of RoundDirector's own signal emit
	_check(over == [true] and director.ended == 3, "Night 1 passed; end_round ran for each Round")
	_check(phase_screen.visible and phase_screen.get_node("%Next").visible and phase_screen.get_node("%Next").text == "Next Night", "PhaseScreen: the Reckoning still offers the host Next Night")
	var banked := economy.cash
	loop.advance()
	_check(loop.phase == GameLoop.Phase.INTERMISSION and stream.viewers == 250, "Night 2 opens, viewers reset to its base")
	# Night 2 is the last: demand = 1.5 x 900 = 1350, unreachable with dead shots
	for r in 3:
		loop.advance()
		for i in 10:
			director.shot(0)
	_check(loop.phase == GameLoop.Phase.GAME_OVER and over == [true, false], "final-night miss -> GAME_OVER")
	_check(economy.cash == banked, "a missed demand deducts nothing")
	_check(phase_screen.get_node("%Title").text == "Game over" and not phase_screen.get_node("%Next").visible, "PhaseScreen: game over, no Next")
	_check(phase_screen.get_node("%Menu").visible, "PhaseScreen: game over offers Back to menu")
	for node in [hud, phase_screen, loop, economy, stream, director]:
		node.free()


## Loop + fake director + economy + stream for one run, `nights` as the Campaign.
func _rig_loop(nights: Array[NightConfig]) -> Dictionary:
	var director := FakeDirector.new()
	var economy := EconomyManager.new()
	var stream := StreamManager.new()
	var loop := GameLoop.new()
	economy.stream = stream
	loop.round_director = director
	loop.economy = economy
	loop.stream = stream
	loop.nights = nights
	for node in [director, stream, economy, loop]:
		root.add_child(node)
	return {loop = loop, director = director, economy = economy, stream = stream}


func _free_rig(rig: Dictionary) -> void:
	for k in ["loop", "economy", "stream", "director"]:
		(rig[k] as Node).free()


## One Round ended by a cleared table (the cheapest way through): GO LIVE, a dead shot, table_cleared.
func _clear_round(rig: Dictionary) -> void:
	rig.loop.advance()
	rig.director.shot(0)
	rig.director.table_cleared.emit("r")
	await process_frame  # end_round is deferred out of the director's own emit


## 02 §3.11: only the Campaign has a Buyout and a win; Endless plays the same Nights, then generated ones, forever.
func _modes() -> void:
	var nights: Array[NightConfig] = [NIGHT_1, NIGHT_2]
	for endless in [false, true]:
		var rig := _rig_loop(nights)
		var loop: GameLoop = rig.loop
		var economy: EconomyManager = rig.economy
		var tag := "Endless" if endless else "Campaign"
		loop.start_campaign(GameLoop.MODE_ENDLESS if endless else GameLoop.MODE_CAMPAIGN)
		_check(loop.mode == (GameLoop.MODE_ENDLESS if endless else GameLoop.MODE_CAMPAIGN), "%s: start_campaign sets the mode" % tag)
		economy.add_cash(100000, &"test")
		for r in 3:
			await _clear_round(rig)
		_check(loop.phase == GameLoop.Phase.RECKONING and loop.run_stats.nights_cleared == 1, "%s: Night 1 passes, one Night cleared" % tag)
		loop.advance()
		_check(loop.is_final_night() == (not endless), "%s: Night 2 %s the Buyout" % [tag, "is not" if endless else "is"])
		_check(loop.ask_for(1) == (NIGHT_2.quota if endless else roundi(NIGHT_2.quota * 1.5)), "%s: Night 2's ask (%d)" % [tag, loop.ask_for(1)])
		for r in 3:
			await _clear_round(rig)
		if endless:
			_check(loop.phase == GameLoop.Phase.RECKONING, "Endless: the last authored Night passed is only a Reckoning, never a win")
			loop.advance()
			var n3 := loop.current_night()
			_check(loop.night_index == 2 and n3.night_number == 3 and n3.quota == roundi(NIGHT_2.quota * NightConfig.ENDLESS_QUOTA_MULT)
				and not loop.is_final_night(), "Endless: Night 3 is generated from the last Night's plain numbers, no Buyout")
			_check(n3.finale_racks.is_empty() and n3.authored_racks.is_empty() and n3.fine_rate == NightConfig.ENDLESS_FINE_RATE, "Endless: no finale racks, the full fine rate")
		else:
			_check(loop.phase == GameLoop.Phase.CAMPAIGN_WON and loop.run_stats.nights_cleared == 2, "Campaign: the Buyout paid is the win")
			loop.advance()  # the won-screen's Endless button
			_check(loop.mode == GameLoop.MODE_ENDLESS and loop.night_index == 2 and not loop.is_final_night(), "Campaign: Endless carries on from the win and flips the mode")
		_free_rig(rig)
	# a missed Buyout ends the Campaign, and a missed Night ends Endless the same way
	var miss := _rig_loop(nights)
	miss.loop.start_campaign(GameLoop.MODE_ENDLESS)
	for r in 3:
		await _clear_round(miss)
	_check(miss.loop.phase == GameLoop.Phase.GAME_OVER and miss.loop.run_stats.nights_cleared == 0, "Endless: a missed quota is Game over")
	_free_rig(miss)
	# the finale plays the finale racks; Endless (same Night, same index) plays the plain ones
	var finale := NightConfig.new()
	var finale_racks: Array[RackLayout] = [RackLayout.new()]
	finale.finale_racks = finale_racks
	var pair: Array[NightConfig] = [NIGHT_1, finale]
	for endless in [false, true]:
		var rig := _rig_loop(pair)
		rig.loop.start_campaign(GameLoop.MODE_ENDLESS if endless else GameLoop.MODE_CAMPAIGN)
		rig.economy.add_cash(100000, &"test")
		for r in 3:
			await _clear_round(rig)
		rig.loop.advance()
		rig.loop.advance()
		var played: NightConfig = rig.director.started[-1][0]
		_check(played.authored_racks.size() == (0 if endless else 1), "%s: the Night after Night 1 plays %s racks" % ["Endless" if endless else "Campaign", "its plain" if endless else "the finale"])
		_free_rig(rig)


## 02 §3.11: the tally the loop's signals feed, the mirror, and the shot-by-shot combo.
func _run_stats() -> void:
	var nights: Array[NightConfig] = [NIGHT_1, NIGHT_2]
	var rig := _rig_loop(nights)
	var loop: GameLoop = rig.loop
	var director: FakeDirector = rig.director
	var economy: EconomyManager = rig.economy
	loop.start_campaign()
	loop.advance()
	var stats := loop.run_stats
	_check(stats.pots == 0 and stats.shots == 0 and stats.grade() == "D", "a new run starts empty")
	# shot 1: two pots and a Combo trick pay; the chain is 2
	director.ball_potted.emit(_typed_ball(), "s1", &"corner")
	director.ball_potted.emit(_typed_ball(), "s1", &"corner")
	director.ball_potted.emit(_ball(true), "s1", &"corner")  # a scratched cue ball is not a pot
	director.shot(200, COMBO)
	_check(stats.pots == 2 and stats.best_combo == 2 and stats.trick_shots == 1 and stats.shots == 1, "pots, chain and trick counted (%s)" % [stats.to_dict()])
	_check(stats.cash_earned > 0 and stats.best_shot == stats.cash_earned, "the payout is cash earned and the best shot")
	# shot 2: one pot continues the streak (1 + 1 earlier Shot = 2 -> no new best); shot 3: two pots chain to 2 + 2 = 4
	director.ball_potted.emit(_typed_ball(), "s2", &"corner")
	director.shot(100)
	_check(stats.best_combo == 2 and stats.trick_shots == 1, "a lone pot after a pot shot stays at 2")
	director.ball_potted.emit(_typed_ball(), "s3", &"corner")
	director.ball_potted.emit(_typed_ball(), "s3", &"corner")
	director.shot(200)
	_check(stats.best_combo == 4 and stats.pots == 5, "two pots after two potting Shots chain to 4 (%d)" % stats.best_combo)
	# a scratch: the cue ball respawns (counted), the foul breaks the chain, the fine is paid (economy signal)
	var earned := stats.cash_earned
	director.cue_respawned.emit(&"scratch")
	director.cue_respawned.emit(&"wedged")  # freed for nothing: not a scratch
	economy.fined.emit(&"scratch", 15)
	director.shot(0, [], true)
	_check(stats.scratches == 1 and stats.fouls == 1 and stats.fines_paid == 15 and stats.cash_earned == earned, "scratch, foul and fine counted; a foul earns nothing")
	director.ball_potted.emit(_typed_ball(), "s5", &"corner")
	director.shot(100)
	_check(stats.best_combo == 4, "the foul broke the streak: the next pot starts a chain of 1")
	var before_tip := stats.cash_earned
	loop._on_tip_received(40)
	_check(stats.cash_earned == before_tip + 40, "a tip counts as cash earned")
	loop._process(2.5)
	_check(is_equal_approx(stats.play_time, 2.5), "play time runs while the run does")
	# the mirror: a client adopts the host's mode and tally
	var snap := stats.to_dict()
	var echo := RunStats.from_dict(snap)
	_check(echo.to_dict() == snap and echo.grade() == stats.grade() and echo.score() == stats.score(), "to_dict/from_dict round-trip")
	loop.mode = GameLoop.MODE_CAMPAIGN
	stats.apply({})
	loop.run_state(GameLoop.MODE_ENDLESS, snap)
	_check(loop.mode == GameLoop.MODE_ENDLESS and loop.run_stats.to_dict() == snap, "run_state carries mode + tally to a client")
	loop.run_state(&"bogus", snap)
	_check(loop.mode == GameLoop.MODE_CAMPAIGN, "an unknown mode on the wire falls back to Campaign")
	# the profile carries both, and a resume restores them
	loop.mode = GameLoop.MODE_ENDLESS
	var profile := loop.build_profile()
	_check(profile.mode == GameLoop.MODE_ENDLESS and profile.run_stats == snap, "the checkpoint holds the mode + tally")
	var back := SaveManager.decode(SaveManager.encode(profile))
	loop.mode = GameLoop.MODE_CAMPAIGN
	loop.run_stats.apply({})
	loop.resume_from(back)
	_check(loop.mode == GameLoop.MODE_ENDLESS and loop.run_stats.to_dict() == snap, "resume restores the mode + tally")
	_free_rig(rig)


func _typed_ball() -> Ball:
	var ball := _ball()
	ball.ball_type = RED
	return ball
