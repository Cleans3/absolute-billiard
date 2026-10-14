extends SceneTree
## UI layer (docs/plan/06 P11-P12): UIRouter isolation and priority, Esc, Settings + key bindings persisted through
## settings.cfg, and the fixed region map: no HUD / touch widget rects intersect at 1280x720 and 2400x1080 (canvas
## 1600x720) in WALK, CARRY and CUE, both thumb layouts. `godot --path . --headless -s tests/ui/ui_probe.gd`

var fails := 0
var _strip: CanvasLayer  # the debug strip (src/debug), loaded at run time: its script reaches autoloads a `-s` compile cannot see


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	Settings.path = "user://test_settings_%d.cfg" % OS.get_process_id()
	Settings.load_all()
	await _router()
	_settings()
	await _controls_screen()
	await _quality()
	await _vote()
	await _phase_and_pause()
	await _layout()
	DirAccess.remove_absolute(Settings.path)
	Settings.reset_bindings()
	Settings.reset_values()
	if fails == 0:
		print("UI OK")
	quit(fails)


# --- UIRouter -------------------------------------------------------------------------------------------

func _modal(prio: int, keep: bool, dismissable := true) -> UIModal:
	var m := UIModal.new()
	m.priority = prio
	m.keep_on_phase = keep
	m.dismissable = dismissable
	root.add_child(m)
	return m


func _esc() -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.physical_keycode = KEY_ESCAPE
	e.pressed = true
	root.push_input(e)


func _router() -> void:
	var loop := GameLoop.new()
	root.add_child(loop)
	var router := UIRouter.new()
	router.game_loop = loop
	router.capture_mouse = true
	root.add_child(router)
	var a := _modal(0, false)
	var b := _modal(0, false)
	var pause := _modal(50, true)
	pause.add_to_group(&"ui_pause")
	var vote := _modal(20, true, false)
	await process_frame
	var changes: Array[bool] = []
	router.modal_changed.connect(func(open: bool) -> void: changes.append(open))
	_check(not router.is_modal_open() and not UIRouter.blocking(), "router starts with nothing open")

	a.open()
	_check(a.visible and router.is_modal_open() and UIRouter.blocking() and changes == [true], "opening a modal blocks input")
	b.open()
	_check(b.visible and not a.visible and changes == [true], "opening a modal closes the others (no modal_changed in between)")
	_check(not router.wants_capture() and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "router frees the mouse while a modal is open")
	b.close()
	_check(not router.is_modal_open() and changes == [true, false], "closing the last modal unblocks")
	_check(router.wants_capture() == not DisplayServer.is_touchscreen_available(), "router recaptures the mouse in-game (desktop only)")

	a.open()
	loop.phase_changed.emit(GameLoop.Phase.ROUND_LIVE)
	_check(not a.visible and not router.is_modal_open(), "a phase change closes a non-keep modal")
	pause.open()
	loop.phase_changed.emit(GameLoop.Phase.INTERMISSION)
	_check(pause.visible, "a keep_on_phase modal survives a phase change")
	pause.close()

	_esc()
	_check(pause.visible, "Esc with nothing open opens Pause")
	_esc()
	_check(not pause.visible and not router.is_modal_open(), "Esc closes the open dismissable modal")

	vote.open()
	_esc()
	_check(pause.visible and not vote.visible, "Esc over an undismissable modal opens Pause over it")
	_esc()
	_check(vote.visible and not pause.visible, "closing Pause brings the displaced modal back")
	pause.open()
	vote.close()
	vote.open()
	_check(pause.visible and not vote.visible, "a lower-priority modal is held back by the open one")
	pause.close()
	_check(vote.visible, "and returns when the higher one closes")
	vote.close()
	a.open()
	pause.open()
	loop.phase_changed.emit(GameLoop.Phase.ROUND_END)
	pause.close()
	_check(not router.is_modal_open() and not a.visible, "a displaced non-keep modal is dropped by the phase change, not resurrected")

	router.toast("Scratch! -$25", &"bad")
	var toast: Label = router.get_child(0)
	_check(toast.visible and toast.text == "Scratch! -$25" and toast.theme_type_variation == &"ToastBad", "one toast channel, kinds map to theme variations")
	router.toast("Voted", &"good")
	_check(toast.text == "Voted" and toast.theme_type_variation == &"ToastGood", "newest toast replaces the old")

	a.open()
	_check(not toast.visible, "a toast hides when a modal opens")
	router.toast("under the dim", &"info")
	_check(not toast.visible, "and none shows while one is open")
	a.close()
	for n in [a, b, pause, vote, router, loop]:
		n.free()
	await process_frame
	_check(UIRouter.instance == null and not UIRouter.blocking(), "no router, nothing blocks")


# --- Settings + bindings --------------------------------------------------------------------------------

func _settings() -> void:
	Settings.set_value(&"fov", 100.0)
	Settings.set_value(&"mouse_sens", 9.0)  # clamps to the slider range
	Settings.set_value(&"quality", &"low")
	Settings.set_value(&"invert_y", true)
	Settings.set_value(&"touch_mirror", true)
	Settings.set_value(&"show_fps", true)
	Settings.set_value(&"master_volume", 0.5)
	_check(Settings.value(&"mouse_sens") == 3.0, "sensitivity clamps to its range")
	_check(Settings.quality_tier() == 2, "low = tier 2")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(0), linear_to_db(0.5)), "master volume applies to the Master bus")
	Settings.save()
	Settings.set_value(&"fov", 90.0)  # not saved: reload must bring back the file's value
	Settings.set_value(&"quality", &"high")
	Settings.load_all()
	_check(Settings.value(&"fov") == 100.0 and Settings.value(&"quality") == &"low" and Settings.value(&"invert_y") == true \
			and Settings.value(&"touch_mirror") == true and Settings.value(&"show_fps") == true and Settings.value(&"master_volume") == 0.5,
			"settings round-trip through settings.cfg")
	Settings.reset_values()
	_check(Settings.value(&"fov") == 75.0 and Settings.value(&"quality") == &"auto" and Settings.quality_tier() == -1, "reset_values restores the defaults, Auto = ladder")
	Settings.save()

	for a in InputMap.get_actions():
		var n := String(a)
		if n.begins_with("ui_") or n.begins_with("debug_") or n.begins_with("spatial_editor") or n == "reset":
			continue
		if not n.begins_with("godot") and not Settings.action_names().has(a):
			_check(false, "gameplay action %s is missing from Settings.ACTIONS" % n)
	_check(Settings.action_names().size() == 23, "Controls lists every gameplay action (21 + swing_cue, throw_cue: 08 §2.9)")

	var key_b := InputEventKey.new()
	key_b.physical_keycode = KEY_B
	_check(Settings.rebind(&"jump", key_b) == &"" and Settings.binding_text(&"jump") == "B", "rebind jump -> B")
	Settings.save()
	Settings.reset_bindings()  # InputMap back to the shipped keys...
	_check(Settings.binding_text(&"jump") == "Space", "reset restores Space")
	Settings.rebind(&"jump", key_b)
	Settings.save()
	Settings.load_all()  # ...and a fresh boot reads the file and applies it
	_check(Settings.binding_text(&"jump") == "B" and InputMap.action_get_events(&"jump").size() == 1, "a rebinding persists and is applied after reload")
	var key_b2 := InputEventKey.new()
	key_b2.physical_keycode = KEY_B
	var old_interact := Settings.binding_text(&"interact")
	_check(Settings.rebind(&"interact", key_b2) == &"jump", "duplicate binding reports who held it")
	_check(Settings.binding_text(&"interact") == "B" and Settings.binding_text(&"jump") == old_interact, "duplicate swaps the two bindings, never two actions on one key")
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_XBUTTON1
	Settings.rebind(&"cue_mode", mouse)
	Settings.save()
	Settings.load_all()
	_check(Settings.binding_text(&"cue_mode") == "Mouse 4", "mouse buttons bind and persist")
	Settings.rebind(&"cue_mode", key_b)  # take B from interact: swap leaves cue_mode with... interact gets cue_mode's mouse
	_check(Settings.binding_text(&"interact") == "Mouse 4", "swap works across keys and mouse buttons")
	Settings.reset_bindings()
	Settings.save()
	Settings.load_all()
	_check(Settings.binding_text(&"jump") == "Space" and Settings.binding_text(&"cue_mode") == "Tab" and Settings.binding_text(&"shoot") == "Mouse right", "reset to defaults persists")


func _controls_screen() -> void:
	var router := UIRouter.new()
	root.add_child(router)
	var screen: ControlsScreen = load("res://src/ui/ControlsScreen.tscn").instantiate()
	root.add_child(screen)
	await process_frame
	screen.open()
	_check(router.is_modal_open(), "Controls opens as a modal")
	screen._listen(&"jump")
	var e := InputEventKey.new()
	e.physical_keycode = KEY_G
	e.keycode = KEY_G
	e.pressed = true
	root.push_input(e)
	_check(Settings.binding_text(&"jump") == "G", "click-to-rebind: the next key binds")
	_check((screen._buttons[&"jump"] as Button).text == "G", "the row shows the new binding")
	screen._listen(&"interact")
	var clash := InputEventKey.new()
	clash.physical_keycode = KEY_G
	clash.keycode = KEY_G
	clash.pressed = true
	root.push_input(clash)
	_check(Settings.binding_text(&"interact") == "G" and Settings.binding_text(&"jump") == "F", "clash in the UI swaps and says so (%s)" % screen._status.text)
	screen._listen(&"jump")
	_esc()
	_check(screen._listening == &"" and screen.visible, "Esc cancels a rebind without closing the screen")
	_esc()
	_check(not screen.visible, "a second Esc closes Controls")
	Settings.reset_bindings()
	screen.free()
	router.free()


# --- QualityManager -------------------------------------------------------------------------------------

func _quality() -> void:
	var q := QualityManager.new()
	root.add_child(q)
	await process_frame
	_check(q.ladder.tier == 0, "Auto starts on the ladder's tier 0")
	Settings.set_value(&"quality", &"low")
	_check(q.ladder.tier == 2 and QualityManager.current_tier == 2, "Low pins tier 2")
	Settings.set_value(&"quality", &"medium")
	_check(q.ladder.tier == 1, "Medium pins tier 1")
	q._win_us = int(QualityManager.WINDOW_S * 1e6) + 1  # a bad window must not move a pinned tier
	q._win_frames = 100
	q._process(0.016)
	_check(q.ladder.tier == 1, "a pinned tier ignores the ladder")
	Settings.set_value(&"quality", &"auto")
	q.free()
	QualityManager.current_tier = 0
	root.scaling_3d_scale = 1.0


# --- EventVote ------------------------------------------------------------------------------------------

func _vote() -> void:
	var router := UIRouter.new()
	root.add_child(router)
	var vote: EventVote = load("res://src/ui/EventVote.tscn").instantiate()
	root.add_child(vote)
	await process_frame
	var ids: Array[StringName] = [FxCatalog.EVENTS[0].id, FxCatalog.EVENTS[1].id, FxCatalog.EVENTS[2].id]
	vote._on_offer(1, 1, ids)
	_check(vote.visible and router.is_modal_open() and vote._cards.get_child_count() == 3, "an offer opens the vote modal with three cards")
	for i in 3:  # 09 §3.4: each card carries its hazard's story line (wrapped; fit is checked in tests/story/story_ui_probe.gd)
		var story_labels := vote._cards.get_child(i).find_children("*", "Label", true, false).filter(func(l: Label) -> bool: return l.text == FxCatalog.EVENTS[i].story_line)
		_check(FxCatalog.EVENTS[i].story_line != "" and story_labels.size() == 1, "vote card %d shows its story line" % i)
	vote._left = 0.01
	vote._process(0.05)
	_check(not vote.visible, "the vote hides when its clock runs out (the host resolves then)")
	var one: Array[StringName] = [ids[0]]
	vote._on_offer(1, 1, one)
	_check(vote.visible and vote._ok.visible and not vote.is_processing(), "a forced Event is an announcement with a button")
	vote._ok.pressed.emit()
	_check(not vote.visible, "the announcement closes")
	vote.free()
	router.free()


# --- phase screens vs the other modals --------------------------------------------------------------------

func _phase_and_pause() -> void:
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()  # we are the host: Start Round is ours to press
	var loop := GameLoop.new()
	var nights: Array[NightConfig] = [load("res://src/resources/nights/night_1.tres")]
	loop.nights = nights
	root.add_child(loop)
	var router := UIRouter.new()
	router.game_loop = loop
	root.add_child(router)
	var phase: PhaseScreen = load("res://src/ui/PhaseScreen.tscn").instantiate()
	phase.game_loop = loop
	var pause: PauseMenu = load("res://src/ui/PauseMenu.tscn").instantiate()
	var settings: SettingsScreen = load("res://src/ui/SettingsScreen.tscn").instantiate()
	var controls: ControlsScreen = load("res://src/ui/ControlsScreen.tscn").instantiate()
	var bartender: BartenderMenu = load("res://src/ui/BartenderMenu.tscn").instantiate()  # no economy: the shelf stays empty
	var vote: EventVote = load("res://src/ui/EventVote.tscn").instantiate()
	for n in [phase, pause, settings, controls, bartender, vote]:
		root.add_child(n)
	await process_frame
	await process_frame
	var screens := {"Bartender": bartender, "Pause": pause, "Settings": settings, "Controls": controls}
	loop.phase_changed.emit(GameLoop.Phase.RECKONING)
	_check(phase.visible and phase._next.visible and phase._next.text == "Next Night", "Reckoning screen with the host's Next Night")
	for name: String in screens:
		var m: UIModal = screens[name]
		m.open()
		_check(m.visible and not phase.visible and router.current == m, "%s open: the phase screen is hidden" % name)
		m.close()
		_check(phase.visible and phase._next.visible and not m.visible, "%s closed: the phase screen is back and the host can press Next Night" % name)
	var ids: Array[StringName] = [FxCatalog.EVENTS[0].id, FxCatalog.EVENTS[1].id, FxCatalog.EVENTS[2].id]
	vote._on_offer(1, 1, ids)
	_check(vote.visible and not phase.visible, "the vote displaces the phase screen")
	vote._left = 0.01
	vote._process(0.05)
	_check(phase.visible and not vote.visible, "and the phase screen returns when the vote is over")

	_esc()
	_check(pause.visible and not phase.visible, "Esc over the phase screen opens Pause (it cannot be dismissed)")
	settings.open()
	_check(settings.visible and not pause.visible, "Settings opens over Pause")
	settings.close()
	_check(pause.visible and not phase.visible, "closing Settings returns to Pause")
	pause.close()
	_check(phase.visible, "closing Pause returns to the phase screen")

	# the Intermission has no screen: the player stays in the bar, its news is two toasts, held while a modal is open
	loop.night_started.emit(1, 600)
	loop.round_ended.emit(&"cleared", 450)
	loop.phase_changed.emit(GameLoop.Phase.INTERMISSION)
	_check(not phase.visible and not router.is_modal_open(), "Intermission: no screen, nothing blocks the walk")
	var toast: Label = router._toast_label
	_check(toast.visible and toast.text.begins_with("Round over (cleared): 450 points"), "Intermission news, line 1: the last Round (%s)" % toast.text)
	phase._flush_news()
	_check(toast.text.begins_with("Round 1/") and "press GO LIVE at the table" in toast.text, "line 2: what is next and how to start it (%s)" % toast.text)
	pause.open()
	loop.phase_changed.emit(GameLoop.Phase.INTERMISSION)
	_check(not phase.visible and phase._news.size() == 2 and not toast.visible, "a modal is open: the news is held, not lost")
	pause.close()
	_check(toast.visible and toast.text.begins_with("Round over") and not phase.visible, "closing the modal shows the held news and no phase screen")

	loop.phase_changed.emit(GameLoop.Phase.ROUND_LIVE)
	_check(not phase.visible, "a Round starting closes the phase screen")
	bartender.open()
	bartender.close()
	_check(not phase.visible, "and no screen closing brings it back while the phase has none")
	loop.phase_changed.emit(GameLoop.Phase.GAME_OVER)
	_check(phase.visible and phase._menu.visible and not phase._next.visible and phase._again.visible, "Game over: Back to menu and the host's New campaign")
	for n in [phase, pause, settings, controls, bartender, vote, router, loop]:
		n.free()
	root.multiplayer.multiplayer_peer = null


# --- region map -----------------------------------------------------------------------------------------

func _layout() -> void:
	for size in [Vector2i(1280, 720), Vector2i(1600, 720)]:  # canvas units of a 1280x720 and a 2400x1080 window
		var vp := SubViewport.new()
		vp.size = size
		vp.disable_3d = true
		root.add_child(vp)
		var router := UIRouter.new()
		vp.add_child(router)
		var hud: Control = load("res://src/ui/HUD.tscn").instantiate()
		vp.add_child(hud)
		var tc: TouchControls = load("res://src/ui/TouchControls.tscn").instantiate()
		vp.add_child(tc)
		_strip = load("res://src/debug/debug_strip.gd").new()
		vp.add_child(_strip)
		await process_frame
		Settings.set_value(&"touch_mirror", true)
		_check(tc.mirror, "the touch mirror setting reaches TouchControls")
		Settings.set_value(&"touch_mirror", false)
		_check(not tc.mirror, "and back")
		var coach := Coach.new()  # unbound: force_step shows a card, the state machine is tests/ui/coach_probe.gd's
		vp.add_child(coach)
		var labels := hud.find_children("*", "Label", true, false)
		_check(labels.size() == 7, "%s the HUD is lean: cash, quota, clock, shots, fps, turn, payout (got %d labels)" % [size, labels.size()])
		hud._time.text = "12:34"  # sizes worse than the real ones
		hud._shots.text = "Shots 10/10"
		hud._turn.text = "Averyveryverylongplayername is shooting"
		hud._turn.show()
		hud._quota.text = "/ $125000"
		hud._fps.text = "120 fps"
		Settings.set_value(&"show_fps", true)
		hud._cash.text = "-$12500"
		hud._payout.text = "Combo x1.15  +$1250"
		router.toast("Can't buy Whiskey (no_cash) at all", &"bad")
		tc._away.show()
		tc.set_prompt("Place the camera")
		tc.set_clock("Call a pocket   Shot clock 30")
		coach.force_step(Coach.Step.SPIN)  # the longest text
		await process_frame
		await process_frame
		for step in [Coach.Step.GO_LIVE, Coach.Step.WAIT, Coach.Step.WALK, Coach.Step.AIM, Coach.Step.SPIN, Coach.Step.POWER]:
			coach.force_step(step)
			await process_frame
			await process_frame
			var card := coach._card.get_global_rect()
			_check(Rect2(Vector2.ZERO, Vector2(size)).encloses(card) and card.end.y <= 400.0 and card.end.x <= 390.0, "%s coach card for step %d stays in its corner (%s)" % [size, step, card])
		coach.force_step(Coach.Step.SPIN)
		await process_frame
		await process_frame
		for mirror in [false, true]:
			for touch in [true, false]:
				for mode in [TouchControls.MODE_WALK, TouchControls.MODE_CARRY, TouchControls.MODE_CUE]:
					tc.touch = touch
					tc.mirror = mirror
					coach.mirror = mirror
					tc.set_mode(mode)
					tc.set_can_shoot(true)
					tc.set_call_pockets(true)
					await process_frame
					await process_frame
					_check_layout(vp, hud, tc, router, coach, "%s mirror=%s touch=%s mode=%d" % [size, mirror, touch, mode])
		_check(tc.look.size.x >= size.x * 0.5 - 1.0 and tc.look.size.y >= size.y - 1.0, "%s look pad is no longer zero-size" % size)
		tc.touch = true
		tc.mirror = false
		tc.set_mode(TouchControls.MODE_WALK)
		await process_frame
		_check(tc.look.get_global_rect().position.x >= size.x * 0.5 - 1.0 and tc.stick.get_global_rect().end.x <= size.x * 0.5 + 1.0, "%s look pad is the right half, stick the left" % size)
		tc.set_mode(TouchControls.MODE_CUE)
		await process_frame
		_check(tc.look.get_global_rect().size.x >= size.x - 1.0, "%s look pad covers the screen in CUE" % size)
		vp.free()
	_strip = null
	Settings.reset_values()


func _check_layout(vp: SubViewport, hud: Control, tc: TouchControls, router: UIRouter, coach: Coach, tag: String) -> void:
	var items := {
		"money": hud.get_node("%Money"), "round": hud.get_node("%Clock"), "fps": hud._fps, "turn": hud._turn, "payout": hud._payout, "toast": router.get_child(0),
		"coach": coach._card,
		"clock": tc._status, "prompt": tc._prompt_label, "away": tc._away,
		"jump": tc._btn_jump, "interact": tc._btn_interact, "shoot": tc._btn_shoot, "back": tc._btn_back,
		"place": tc._btn_place, "drop": tc._btn_drop, "pause": tc._btn_pause,
		"spin": tc.spin_pad, "elev": tc.elevation, "power": tc.power,
	}
	items["debug strip"] = _strip._row  # docs 08 §2.8 / adhoc-1012a: debug mode's four buttons, top bar between money and clock
	for i in tc.pockets.size():
		items["pocket%d" % (i + 1)] = tc.pockets[i]
	var rects := {}
	var screen := Rect2(Vector2.ZERO, Vector2(vp.size))
	for k: String in items:
		var c: Control = items[k]
		if not c.is_visible_in_tree():
			continue
		var r := c.get_global_rect()
		rects[k] = r
		_check(screen.encloses(r), "%s: %s inside the screen %s" % [tag, k, r])
	var bar := Rect2(140.0, 8.0, vp.size.x - 280.0, 56.0)  # docs 08 §2.8: both HUD groups live in the top bar
	for k in ["money", "round"]:
		_check(bar.encloses(rects[k]), "%s: %s %s inside the top bar %s" % [tag, k, rects[k], bar])
	var keys := rects.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			if (rects[keys[i]] as Rect2).intersects(rects[keys[j]]):
				_check(false, "%s: %s %s overlaps %s %s" % [tag, keys[i], rects[keys[i]], keys[j], rects[keys[j]]])
