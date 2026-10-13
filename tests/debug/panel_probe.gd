extends SceneTree

## Debug mode in the real level: Lobby > Solo > MainLevel. The Settings toggle shows the strip, the strip's DEBUG button opens
## the panel (one modal, it blocks input), a slider moves a physics number live, rewind and replay work from the strip, the
## Round re-racks to the same balls, and the strip sits clear of every HUD and touch widget.
##   godot --path . --headless -s tests/debug/panel_probe.gd      prints PANEL OK

var _fail := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("PANEL: " + msg)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Settings.path = "user://test_settings_%d.cfg" % OS.get_process_id()
	Settings.load_all()
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	print("panel: playable")
	var level := current_scene
	var dbg: Node = level.get_node("Debug")  # untyped: a `-s` probe compiles before the autoloads that debug_root.gd reaches exist
	var loop: GameLoop = level.get_node("GameLoop")
	var director: RoundDirector = level.get_node("RoundDirector")
	var economy: EconomyManager = level.get_node("EconomyManager")
	var router: UIRouter = level.get_node("UILayer/UIRouter")
	var table: Table = level.get_node("Table")
	var session: DebugSession = dbg.session
	var panel: Control = dbg.panel
	var strip: Node = dbg.strip
	_check(session != null and panel != null and strip != null, "debug mode builds a session, a panel and a strip")
	_check(not strip.visible and Settings.value(&"debug_mode") == false, "off until the Settings toggle is on")
	Settings.set_value(&"debug_mode", true)
	_check(strip.visible and strip.buttons().size() == 4, "the toggle shows the strip: DEBUG, Rewind, Replay, Re-rack")
	await _frames(2)
	var screen := Rect2(Vector2.ZERO, get_root().get_visible_rect().size)
	var rect := Rect2(strip.buttons()[0].global_position, Vector2.ZERO)
	for b in strip.buttons():
		var r := Rect2(b.global_position, b.size)
		_check(r.size.y >= 52.0 and screen.encloses(r), "strip button %s is finger sized and on screen %s" % [b.text, r])
		rect = rect.merge(r)
	_check(Rect2(380.0, 8.0, 500.0, 56.0).encloses(rect), "the strip stays inside its region %s" % [rect])

	strip.buttons()[0].pressed.emit()
	await _frames(2)
	_check(panel.visible and router.current == panel and UIRouter.blocking(), "DEBUG opens the panel as the one open modal, input is gated")
	# the View page's glare hypotheses (adhoc-1014a V3): one switch per flag, applied live to the level, persisted nowhere in a probe
	GlareFlags.persist = false
	_check(panel._glare_toggles.size() == GlareFlags.BOOLS.size() and panel._glare_choices.size() == GlareFlags.CHOICES.size(), "the panel has a switch per glare flag")
	var baked: Light3D = level.find_child("BakedNeonCyan", true, false)
	GlareFlags.set_all({})
	panel._refresh_glare()
	_check(baked != null and is_equal_approx(baked.light_specular, 0.5) and not (panel._glare_toggles[&"baked_spec_off"] as CheckButton).button_pressed, "baseline: the baked neon keeps its specular, the switch shows off")
	(panel._glare_toggles[&"baked_spec_off"] as CheckButton).button_pressed = true
	_check(GlareFlags.on(&"baked_spec_off") and is_zero_approx(baked.light_specular), "its switch zeroes the specular in the live level")
	GlareFlags.set_all(GlareFlags.DEFAULTS)
	var slider: HSlider = panel._fields[&"rolling_resistance"]
	slider.value = 0.031
	await _frames(2)
	_check(is_equal_approx(table.spec.rolling_resistance, 0.031), "a slider moves the number live (%.4f)" % table.spec.rolling_resistance)
	var ball: Ball = table.sim.get_balls()[0] if not table.sim.get_balls().is_empty() else null
	_check(ball == null or is_equal_approx(ball.motion.roll_mu, 0.031), "and the model the clients share")
	session.set_defaults()
	_check(panel._status.text.contains("defaults"), "the status line reports what the panel did")
	panel.close()
	await _frames(2)
	_check(not panel.visible and not UIRouter.blocking(), "closing hands the screen back")

	print("panel: strip and panel ok, advancing")
	loop.advance()
	await _frames(30)
	_check(loop.phase == GameLoop.Phase.ROUND_LIVE, "GO LIVE")
	var first_rack := _snapshot(director)
	var shots := loop.shots_left
	var cash := economy.cash
	var angle := session.aim_at_nearest()
	_check(session.fire(angle, 0.7), "a test shot goes through the Round")
	print("panel: fired")
	await director.shot_ended
	await _frames(10)
	_check(loop.shots_left == shots - 1 and session.shots.size() == 1, "it cost a shot and was recorded")
	session.add_cash(777)
	_check(economy.cash == cash + 777, "the cash cheat")
	var moved := _snapshot(director)

	print("panel: shot done, rewinding")
	strip.buttons()[1].pressed.emit()
	await _frames(40)
	_check(loop.shots_left == shots and economy.cash == cash, "Rewind brings the shot count and the Cash back (%d, %d)" % [loop.shots_left, economy.cash])
	_check(_distance(first_rack, _snapshot(director)) < 0.004, "and the table")
	print("panel: replaying")
	strip.buttons()[2].pressed.emit()
	await director.shot_ended
	await _frames(10)
	_check(loop.shots_left == shots - 1 and session.shots[0].replays == 1, "Replay fires the same shot again (ended %.2f mm from the first)" % (session.shots[0].error_m * 1000.0))
	_check(_distance(moved, _snapshot(director)) < 0.05, "to nearly the same end state")

	strip.buttons()[3].pressed.emit()
	await _frames(40)
	_check(loop.shots_left == loop.current_night().shots_per_round and loop.round_points == 0, "Re-rack resets the Round's shots and points")
	_check(_distance(first_rack, _snapshot(director)) < 0.004, "and deals the same rack (same seed)")

	_check(session.current_round_id() == "n1-r1" and session.shots[0].round_id() == "n1-r1", "shots know their Round (%s)" % session.shots[0].shot_id)
	var again := session.shots.size()
	session.fire(session.aim_at_nearest(), 0.4)
	await director.shot_ended
	await _frames(10)
	var live_shots := loop.shots_left
	session.replay_round()
	await director.shot_ended
	await director.shot_ended
	await _frames(10)
	_check(session.shots[0].replays >= 1 and session.shots[again].replays == 1 and loop.shots_left == live_shots, "Replay the Round runs its recorded shots in order (%d left)" % loop.shots_left)

	Settings.set_value(&"debug_mode", false)
	await _frames(2)
	_check(not strip.visible and not panel.visible, "switching it off hides the strip")
	DirAccess.remove_absolute(Settings.path)
	Settings.reset_values()
	print("PANEL OK" if _fail == 0 else "PANEL FAILED: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _snapshot(director: RoundDirector) -> Dictionary:
	var out := {}
	for b in director.get_balls():
		if not b.retired and not b.is_pocketed:
			out[b.net_id] = b.global_position
	return out


func _distance(a: Dictionary, b: Dictionary) -> float:
	var worst := 0.0
	for id in a:
		worst = maxf(worst, Vector2(a[id].x - b[id].x, a[id].z - b[id].z).length() if b.has(id) else 9.0)
	for id in b:
		if not a.has(id):
			worst = 9.0
	return worst
