extends SceneTree
## The first-time coach (docs/plan/08 §2.8, 06 P44, adhoc-1014a V2) and the HUD's turn line and n/N shots, one peer (Solo):
## no story cards on spawn; the GO LIVE hint until ready; WALK / AIM / SPIN / POWER on real signals and CueController state, never a timer;
## WAIT when someone else shoots; the seen flag set on the first shot or on Skip, not on first show; Replay tutorial.
##   godot --path . --headless -s tests/ui/coach_probe.gd     prints COACH OK

var fails := 0
var finished := false
var level: Node
var loop: GameLoop
var rd: RoundDirector
var hud: Control
var coach: Coach
var player: Player
var cue: CueController
var done_with: Array[bool] = []


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("COACH FAIL (script error or hang)")
			quit(1))
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _until(cond: Callable, sec: float) -> bool:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame
	return cond.call()


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


func _stand_by_cue_ball() -> void:
	var b := _cue_ball()
	player.global_position = Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_coach"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, false, false, false, true)
	level = current_scene
	loop = level.get_node("GameLoop")
	rd = level.get_node("RoundDirector")
	hud = level.get_node("UILayer/HUD")
	coach = hud.coach
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	cue = player.cue
	coach.finished.connect(func(skipped: bool) -> void: done_with.append(skipped))
	await _frames(2)
	await _no_cards()
	await _go_live()
	await _first_shot()
	await _after_the_shot()
	await _wait_card_and_skip()
	await _replay_and_limits()
	await _shots_label()
	finished = true
	print("COACH OK" if fails == 0 else "COACH FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


# --- V2: the backstory does not show on spawn -----------------------------------------------------------------------------------

func _no_cards() -> void:
	var cards: StoryCards = level.get_node("UILayer/StoryCards")
	_check(not StoryDirector.auto_intro_cards, "the intro cards are off by default (one flag brings them back)")
	_check(cards.cards.is_empty() and SaveManager.story_seen(loop.campaign_seed).is_empty(), "Night 1 opened no story cards and recorded none as seen")
	_check(loop.phase == GameLoop.Phase.INTERMISSION and loop.round_index == 0, "the first Intermission is up")


# --- (1) GO LIVE: the hint over the button, until I am ready ---------------------------------------------------------------------

func _go_live() -> void:
	var pedestal := get_first_node_in_group(&"go_live_pedestal") as GoLivePedestal
	_check(pedestal != null, "the pedestal exists")
	_check(Coach.enabled and not SaveManager.coach_seen(), "a fresh profile has not seen the coach")
	_check(coach.step == Coach.Step.GO_LIVE and coach._card.visible, "step GO LIVE: the card is up")
	_check(coach._body.text.contains("GO LIVE") and coach._title.text == "Getting started", "it names the button: %s" % coach._body.text)
	_check(pedestal._hint != null and pedestal._hint.visible and pedestal._hint.text.contains("ready to play"), "the floating hint is over the GO LIVE button")
	_check(not hud._turn.visible, "no turn line between Rounds")
	var cfg := loop.current_night()
	var secs := ceili(cfg.round_time_limit_sec)
	_check(hud._shots.text == "Shots %d/%d" % [cfg.shots_per_round, cfg.shots_per_round] and hud._time.text == "%d:%02d" % [secs / 60, secs % 60], "before Round 1 the HUD shows the full count and time, not 0: '%s' '%s'" % [hud._shots.text, hud._time.text])
	await create_timer(1.0).timeout
	_check(coach.step == Coach.Step.GO_LIVE, "the step never advances on a timer")
	loop.ready_peers.append(1)
	loop.ready_changed.emit()
	_check(coach.step == Coach.Step.OFF and not pedestal._hint.visible and not coach._card.visible, "ready: the hint and the card go")
	loop.ready_peers.clear()
	loop.ready_changed.emit()
	_check(coach.step == Coach.Step.GO_LIVE and pedestal._hint.visible, "no longer ready: they come back")
	var cards: StoryCards = level.get_node("UILayer/StoryCards")
	cards.show_cards(["a modal"] as Array[String])
	_check(not coach._card.visible, "the card hides under a modal")
	cards.close()
	await process_frame
	_check(coach._card.visible, "and returns with it gone")
	_check(not SaveManager.coach_seen() and done_with.is_empty(), "nothing is marked seen by showing")
	loop.advance()  # GO LIVE pressed: the Round starts
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.ROUND_LIVE, 5.0)
	await _frames(2)
	_check(not pedestal._hint.visible, "the hint is gone once the Round is live")
	_check(hud._turn.visible and hud._turn.text == "Your turn", "the turn line says Your turn: '%s'" % hud._turn.text)


# --- (2) my shot: walk, aim, spin, power -----------------------------------------------------------------------------------------

func _first_shot() -> void:
	_check(rd.current_shooter_id == 1 and coach.step == Coach.Step.WALK, "my turn, standing: step WALK (got %d)" % coach.step)
	_check(coach._title.text == "Your first shot 1/4" and coach._body.text.contains("cue ball"), "it says to walk to the cue ball: %s" % coach._body.text)
	await _until(func() -> bool: return level.get_node("Table").sim.awake == 0, 10.0)
	_stand_by_cue_ball()
	await _frames(2)
	_check(player.enter_cue(), "the player lines up")
	await _frames(2)
	_check(coach.step == Coach.Step.AIM and coach._title.text == "Your first shot 2/4", "CUE: step AIM (got %d)" % coach.step)
	await create_timer(0.6).timeout
	_check(coach.step == Coach.Step.AIM, "AIM waits for the player, not a clock")
	cue.turn(0.04)
	await _frames(3)
	_check(coach.step == Coach.Step.AIM, "a nudge below ~6 degrees is not aiming")
	cue.turn(0.2)
	await _frames(3)
	_check(coach.step == Coach.Step.SPIN and coach._title.text == "Your first shot 3/4", "aimed: step SPIN (got %d)" % coach.step)
	_check(coach._body.text.begins_with("Optional"), "the spin step says optional")
	cue.set_spin(Vector2(0.3, 0.0))
	await _frames(3)
	_check(coach.step == Coach.Step.POWER and coach._title.text == "Your first shot 4/4", "spin set: step POWER (got %d)" % coach.step)
	player.exit_cue()  # Back
	await _frames(2)
	_check(coach.step == Coach.Step.WALK, "Back out of CUE: step WALK again (got %d)" % coach.step)
	_stand_by_cue_ball()
	await _frames(2)
	_check(player.enter_cue(), "lines up again")
	await _frames(2)
	_check(coach.step == Coach.Step.AIM, "the CUE steps start over (got %d)" % coach.step)
	cue.power = 0.5  # the bar pulled without aiming or spinning: straight to POWER
	await _frames(3)
	_check(coach.step == Coach.Step.POWER, "pulling the power bar jumps to POWER (got %d)" % coach.step)
	cue.power = 0.0
	_check(not SaveManager.coach_seen(), "still not seen before the shot is away")
	cue.fire(0.4)
	await _frames(2)
	_check(done_with == [false] and SaveManager.coach_seen() and coach.done, "the first shot away: finished, not skipped, flag saved")
	_check(coach.step == Coach.Step.OFF and not coach._card.visible, "the card is gone")


# --- done stays done; the turn line ----------------------------------------------------------------------------------------------

func _after_the_shot() -> void:
	await _until(func() -> bool: return level.get_node("Table").sim.awake == 0 and not rd.shot_in_progress, 15.0)
	var total := loop.current_night().shots_per_round
	_check(loop.shots_left == total - 1 and hud._shots.text == "Shots %d/%d" % [total - 1, total], "the settled shot ticks the label on the host: %d left, '%s'" % [loop.shots_left, hud._shots.text])
	var again := Coach.new()
	hud.add_child(again)
	again.bind(loop)
	_check(again.step == Coach.Step.OFF, "a player who finished it never sees it again (a coach built after the flag)")
	again.free()
	rd.current_shooter_id = 2
	rd.shooter_changed.emit(2)
	_check(hud._turn.visible and hud._turn.text == "Someone else is shooting", "the turn line follows the shooter: '%s'" % hud._turn.text)
	rd.current_shooter_id = 1
	rd.shooter_changed.emit(1)
	_check(hud._turn.text == "Your turn", "and comes back: '%s'" % hud._turn.text)


# --- not my turn, then Skip ------------------------------------------------------------------------------------------------------

func _wait_card_and_skip() -> void:
	done_with.clear()
	Coach.replay(self)  # Settings > Replay tutorial
	await process_frame
	_check(not SaveManager.coach_seen() and not coach.done and coach.step == Coach.Step.WALK, "replay: the flag is clear and the guide restarts at the step that applies (got %d)" % coach.step)
	rd.current_shooter_id = 2
	rd.shooter_changed.emit(2)
	_check(coach.step == Coach.Step.WAIT and coach._body.text.contains("shooting") and coach._body.text.contains("Wait for your turn"), "someone else shoots: step WAIT: %s" % coach._body.text)
	await create_timer(0.6).timeout
	_check(coach.step == Coach.Step.WAIT, "WAIT lasts until the turn is mine")
	rd.current_shooter_id = 1
	rd.shooter_changed.emit(1)
	_check(coach.step == Coach.Step.WALK, "my turn: the shot guide runs (got %d)" % coach.step)
	coach._skip.pressed.emit()
	_check(done_with == [true] and SaveManager.coach_seen() and coach.step == Coach.Step.OFF, "Skip: finished as skipped, flag saved")


# --- limits and the Settings row ------------------------------------------------------------------------------------------------

func _replay_and_limits() -> void:
	var settings: SettingsScreen = level.get_node("UILayer/SettingsScreen")
	settings._replay.pressed.emit()
	_check(not SaveManager.coach_seen(), "Settings > Replay tutorial clears the flag")
	await process_frame
	_check(coach.step == Coach.Step.WALK, "and restarts the guide in a live Round (got %d)" % coach.step)
	coach._forced = false  # a normal run: only Night 1's first Intermission and Round 1 qualify
	loop.round_index = 2
	coach._refresh()
	_check(coach.step == Coach.Step.OFF, "Round 2 of a player who never finished: no guide (the first Round only)")
	loop.round_index = 1
	Coach.enabled = false
	coach._refresh()
	_check(coach.step == Coach.Step.OFF, "Coach.enabled = false (headless default) keeps it off")
	Coach.enabled = true
	coach._refresh()
	_check(coach.step == Coach.Step.WALK, "and on again (got %d)" % coach.step)
	done_with.clear()
	var key := InputEventKey.new()  # desktop has a captured mouse: Skip is a key
	key.keycode = Coach.SKIP_KEY
	key.physical_keycode = Coach.SKIP_KEY
	key.pressed = true
	root.push_input(key)
	await process_frame
	_check(done_with == [true] and coach.step == Coach.Step.OFF and SaveManager.coach_seen(), "the Skip key ends the guide as skipped")


# --- V9: Shots n/N -----------------------------------------------------------------------------------------------------------------

func _shots_label() -> void:
	var total := loop.current_night().shots_per_round
	loop.shots_left = total
	loop.state_changed.emit()
	_check(hud._shots.text == "Shots %d/%d" % [total, total], "a fresh Round reads %d/%d: '%s'" % [total, total, hud._shots.text])
	loop.shots_left = total - 1
	loop.state_changed.emit()
	_check(hud._shots.text == "Shots %d/%d" % [total - 1, total], "one shot later it reads %d/%d: '%s'" % [total - 1, total, hud._shots.text])
	loop.shots_left = total + 2  # a debug top-up
	loop.state_changed.emit()
	_check(hud._shots.text == "Shots %d/%d" % [total + 2, total + 2], "a top-up never reads n/N with n > N: '%s'" % hud._shots.text)
	loop.shots_left = 3  # a Round just ended with shots and time to spare: the Intermission shows the next Round's full values
	loop.time_left = 7.0
	loop.phase = GameLoop.Phase.INTERMISSION
	loop.phase_changed.emit(GameLoop.Phase.INTERMISSION)
	await _frames(2)
	var secs := ceili(loop.current_night().round_time_limit_sec)
	_check(hud._shots.text == "Shots %d/%d" % [total, total] and hud._time.text == "%d:%02d" % [secs / 60, secs % 60], "an Intermission after a Round shows the full count and time: '%s' '%s'" % [hud._shots.text, hud._time.text])
