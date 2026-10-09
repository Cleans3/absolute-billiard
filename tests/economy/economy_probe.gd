extends SceneTree

## Headless economy probe (M1 C6/C7; docs/plan/02 §3.2–3.5): the Shot_Cash arithmetic against the
## income sheet, viewer/hype/tip rules, and a full Night driven through GameLoop with a fake RoundDirector.
##   godot --path . --headless -s tests/economy/economy_probe.gd
## Prints ECONOMY OK, or the failing checks and ECONOMY FAIL (exit 1).

const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")
const NIGHT_2 := preload("res://src/resources/nights/night_2.tres")
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
	_check(economy.evaluate_quota(NIGHT_1) and economy.cash == 100, "quota 600 paid from 700, $100 banks")
	_check(economy.demand_for(NIGHT_1, true) == 900, "final-night demand == 1.5 x 600")
	_check(not economy.evaluate_quota(NIGHT_2) and economy.cash == 100, "short of quota: nothing paid, run ends")


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
	_check(phase_screen.visible and phase_screen.get_node("%Next").visible, "PhaseScreen: Intermission screen + host Next button")
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
