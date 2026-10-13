class_name DebugPanel
extends UIModal

## The debug mode panel (adhoc-1012a): a drawer on the right edge so the table stays in view while a number moves. One
## UIModal like every other screen (UIRouter keeps it the only one open, Esc closes it). Pages: Feel (every TableSpec
## live number as a slider, applied at once, no re-rack), Shots (recorded shots: rewind, replay, a test shot), Table,
## Game, View. Everything that changes the game is the host's (DebugSession); a client sees its own numbers and the View page.

const WIDTH := 540.0
const TOP := 64.0  ## below the strip (top bar), which stays reachable while the drawer is open
const PAGES := ["Feel", "Shots", "Table", "Game", "View"]
const GROUPS := {
	"Ball to ball": [&"ball_cascade_enabled", &"ball_restitution", &"ball_friction"],
	"Cloth and rolling": [&"cloth_friction", &"rolling_resistance", &"spin_decay", &"ball_linear_damp", &"ball_angular_damp"],
	"Settling (creep tail)": [&"settle_speed_mps", &"settle_boost", &"spin_stop_rad_s2", &"tilt_max_vs_roll"],
	"Cushion": [&"cushion_restitution", &"cushion_restitution_min", &"cushion_soft_speed_mps", &"cushion_hard_speed_mps", &"cushion_friction"],
	"Rest, pockets, CCD": [&"rest_speed_mps", &"rest_ang_rad_s", &"cup_friction", &"cup_bounce", &"ccd_step_radii"],
}
const STAT_RANGES := {
	&"cloth_friction_mult": Vector3(0.1, 3.0, 0.01), &"cushion_restitution_mult": Vector3(0.0, 1.5, 0.01),
	&"cue_ball_mass_mult": Vector3(0.2, 5.0, 0.05), &"table_tilt_deg": Vector3(0.0, 8.0, 0.1),
}
const CUE_RANGES := {
	&"power_cap_speed_mps": Vector3(2.0, 40.0, 0.5), &"power_top_boost": Vector3(0.0, 1.0, 0.01), &"spin_offset_radius": Vector3(0.0, 0.6, 0.01), &"miscue_threshold": Vector3(0.5, 1.0, 0.01),
}
const TIMESCALES := [1.0, 0.5, 0.25, 0.1, 2.0]

var session: DebugSession
var debug_root: DebugRoot

var _body: VBoxContainer
var _pages := {}
var _tabs := {}
var _status: Label
var _fields := {}  # StringName -> HSlider | CheckButton
var _stats := {}
var _cues := {}
var _tilt_dir: HSlider
var _tuning_label: Label
var _shots_box: VBoxContainer
var _shots_sig := ""
var _game_label: Label
var _test_aim: HSlider
var _test_power: HSlider
var _test_spin_x: HSlider
var _test_spin_y: HSlider
var _test_elev: HSlider
var _refresh_queued := false
var _view_toggles := {}
var _staging_toggle: CheckButton


func _init() -> void:
	super()
	dim = false
	priority = 70
	keep_on_phase = true
	add_to_group(&"ui_debug")


func _ready() -> void:
	super()
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # the table behind the drawer stays visible; the drawer itself stops touches
	var drawer := PanelContainer.new()
	drawer.anchor_left = 1.0
	drawer.anchor_right = 1.0
	drawer.anchor_bottom = 1.0
	drawer.offset_left = -WIDTH
	drawer.offset_top = TOP
	add_child(drawer)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 6)
	drawer.add_child(column)
	var head := DebugWidgets.row(column)
	var title := DebugWidgets.label(head, "DEBUG  (host edits, clients read)")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var close_button := DebugWidgets.button(head, "Close", close)
	close_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	close_button.custom_minimum_size = Vector2(140.0, DebugWidgets.ROW_H)
	var tab_row := DebugWidgets.row(column)
	var group := ButtonGroup.new()
	for p: String in PAGES:
		var b := Button.new()
		b.text = p
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0.0, DebugWidgets.ROW_H)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.add_theme_font_size_override(&"font_size", 18)  # five tabs in a 540 px drawer
		b.pressed.connect(_show_page.bind(p))
		tab_row.add_child(b)
		_tabs[p] = b
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override(&"separation", 8)
	scroll.add_child(_body)
	_status = DebugWidgets.label(column, "", true)
	_status.custom_minimum_size = Vector2(0.0, 52.0)
	for p: String in PAGES:
		var page := VBoxContainer.new()
		page.add_theme_constant_override(&"separation", 6)
		page.visible = false
		_body.add_child(page)
		_pages[p] = page
	_build_physics(_pages["Feel"])
	_build_shots(_pages["Shots"])
	_build_table(_pages["Table"])
	_build_game(_pages["Game"])
	_build_view(_pages["View"])
	if not session.is_host():
		for p in ["Feel", "Shots", "Table", "Game"]:
			_lock(_pages[p])
		_status.text = "Client: the physics, shot, table and game controls are the host's."
	session.changed.connect(_queue_refresh)
	session.said.connect(func(t: String) -> void: _status.text = t)
	(_tabs["Feel"] as Button).button_pressed = true
	_show_page("Feel")


func _on_open() -> void:
	_refresh()


func _show_page(name: String) -> void:
	for p: String in _pages:
		(_pages[p] as Control).visible = p == name
	_refresh()


func _lock(n: Node) -> void:
	for c in n.get_children():
		if c is BaseButton:
			(c as BaseButton).disabled = true
		elif c is Slider:
			(c as Slider).editable = false
		_lock(c)


func _queue_refresh() -> void:
	if visible and not _refresh_queued:
		_refresh_queued = true
		_refresh.call_deferred()


# ---------------------------------------------------------------- Physics

func _build_physics(page: VBoxContainer) -> void:
	var top := DebugWidgets.row(page)
	DebugWidgets.button(top, "Defaults", session.set_defaults)
	DebugWidgets.button(top, "Save", session.save_tuning)
	DebugWidgets.button(top, "Copy", func() -> void:
		DisplayServer.clipboard_set(session.tuning_text())
		print("debug tuning:\n", session.tuning_text())
		_status.text = "copied: the changed numbers, to paste into TableSpec")
	_tuning_label = DebugWidgets.label(page, "", true)
	for g: String in GROUPS:
		var body := DebugWidgets.section(page, g)
		for f: StringName in GROUPS[g]:
			_add_field(body, f)
	var stats := DebugWidgets.section(page, "Stats (an Effect writes these too)", false)
	for s: StringName in DebugSession.STATS:
		var r: Vector3 = STAT_RANGES[s]
		_stats[s] = DebugWidgets.slider(stats, String(s), r.x, r.y, r.z, session.stat_value(s), func(v: float) -> void: session.set_stat(s, v))
	_tilt_dir = DebugWidgets.slider(stats, "tilt direction (deg)", 0.0, 360.0, 5.0, session.tilt_direction_deg(), session.set_tilt_direction_deg)
	var cue := DebugWidgets.section(page, "Cue", false)
	for f: StringName in DebugSession.CUE_FIELDS:
		var r: Vector3 = CUE_RANGES[f]
		_cues[f] = DebugWidgets.slider(cue, String(f), r.x, r.y, r.z, session.cue_value(f), func(v: float) -> void: session.set_cue(f, v))


func _add_field(parent: Control, f: StringName) -> void:
	if session.is_flag(f):
		var c := DebugWidgets.toggle(parent, String(f), session.field_value(f) > 0.5, func(on: bool) -> void: session.set_field(f, 1.0 if on else 0.0))
		_fields[f] = c
		return
	var r := session.field_range(f)
	_fields[f] = DebugWidgets.slider(parent, String(f), r.x, r.y, r.z, session.field_value(f), func(v: float) -> void: session.set_field(f, v))


# ---------------------------------------------------------------- Shots

func _build_shots(page: VBoxContainer) -> void:
	var top := DebugWidgets.row(page)
	DebugWidgets.button(top, "Rewind last", func() -> void: _on_last(false))
	DebugWidgets.button(top, "Replay last", func() -> void: _on_last(true))
	DebugWidgets.button(top, "Clear", session.clear_shots)
	DebugWidgets.button(page, "Replay this Round from its first shot", session.replay_round)
	var test := DebugWidgets.section(page, "Test shot", false)
	_test_aim = DebugWidgets.slider(test, "aim (deg, 0 = down the table)", -180.0, 180.0, 1.0, 0.0, func(_v: float) -> void: pass)
	_test_power = DebugWidgets.slider(test, "power", 0.0, 1.0, 0.01, 0.5, func(_v: float) -> void: pass)
	_test_spin_x = DebugWidgets.slider(test, "side spin", -1.0, 1.0, 0.05, 0.0, func(_v: float) -> void: pass)
	_test_spin_y = DebugWidgets.slider(test, "follow (+) / draw (-)", -1.0, 1.0, 0.05, 0.0, func(_v: float) -> void: pass)
	_test_elev = DebugWidgets.slider(test, "cue elevation (deg)", 0.0, 80.0, 1.0, 0.0, func(_v: float) -> void: pass)
	var go := DebugWidgets.row(test)
	DebugWidgets.button(go, "Aim at nearest", func() -> void:
		var a := session.aim_at_nearest()
		if not is_nan(a):
			DebugWidgets.put(_test_aim, a))
	DebugWidgets.button(go, "Fire", func() -> void:
		session.fire(_test_aim.value, _test_power.value, Vector2(_test_spin_x.value, _test_spin_y.value), _test_elev.value))
	DebugWidgets.label(page, "Replay = rewind, then fire the recorded shot again (a re-simulation: balls end close, not always identical).", true)
	_shots_box = VBoxContainer.new()
	_shots_box.add_theme_constant_override(&"separation", 6)
	page.add_child(_shots_box)


func _on_last(play: bool) -> void:
	var rec := session.last()
	if rec == null:
		_status.text = "no shot recorded yet"
	elif play:
		session.replay(rec)
	else:
		session.rewind(rec)


func _rebuild_shots() -> void:
	var sig := ""
	for r in session.shots:
		sig += "%d:%s:%d:%d;" % [r.serial, r.done, r.replays, int(r.error_m * 1000.0)]
	if sig == _shots_sig:
		return
	_shots_sig = sig
	for c in _shots_box.get_children():
		c.queue_free()
	var host := session.is_host()
	for i in range(session.shots.size() - 1, -1, -1):
		var r: DebugSession.ShotRecord = session.shots[i]
		var card := VBoxContainer.new()
		card.add_theme_constant_override(&"separation", 4)
		_shots_box.add_child(card)
		DebugWidgets.label(card, r.label(), true)
		var line := DebugWidgets.row(card)
		DebugWidgets.button(line, "Rewind", session.rewind.bind(r)).disabled = not host
		DebugWidgets.button(line, "Replay", func() -> void: session.replay(r)).disabled = not host
		DebugWidgets.button(line, "From here", func() -> void: session.replay_from(r)).disabled = not host


# ---------------------------------------------------------------- Table

func _build_table(page: VBoxContainer) -> void:
	var a := DebugWidgets.row(page)
	DebugWidgets.button(a, "Stop balls", session.stop_balls)
	DebugWidgets.button(a, "Cue home", session.reset_cue_ball)
	DebugWidgets.button(a, "Clear table", session.clear_table)
	DebugWidgets.label(page, "Rack presets (the Round's own balls, dealt onto the foot spot):", true)
	var p := GridContainer.new()
	p.columns = 2
	p.add_theme_constant_override(&"h_separation", 8)
	p.add_theme_constant_override(&"v_separation", 6)
	page.add_child(p)
	for name: String in DebugSession.PRESETS:
		DebugWidgets.button(p, name.replace("_", " "), session.apply_preset.bind(name))
	DebugWidgets.label(page, "Re-rack the live Round (shots, points and clock reset):", true)
	var b := DebugWidgets.row(page)
	DebugWidgets.button(b, "Same seed", func() -> void: session.rerack(true))
	DebugWidgets.button(b, "New seed", func() -> void: session.rerack(false))


# ---------------------------------------------------------------- Game

func _build_game(page: VBoxContainer) -> void:
	_game_label = DebugWidgets.label(page, "", true)
	DebugWidgets.button(page, "Advance (GO LIVE / next Night)", session.advance)
	var cash := DebugWidgets.row(page)
	DebugWidgets.button(cash, "Cash −1k", func() -> void: session.add_cash(-1000))
	DebugWidgets.button(cash, "Cash +1k", func() -> void: session.add_cash(1000))
	DebugWidgets.button(cash, "Cash +10k", func() -> void: session.add_cash(10000))
	var more := DebugWidgets.row(page)
	DebugWidgets.button(more, "Shots +1", func() -> void: session.add_shots(1))
	DebugWidgets.button(more, "Shots +5", func() -> void: session.add_shots(5))
	DebugWidgets.button(more, "Time +30 s", func() -> void: session.add_time(30.0))
	var drinks := DebugWidgets.section(page, "Drinks", false)
	for d in FxCatalog.DRINKS:
		DebugWidgets.button(drinks, d.display_name, session.apply_effects.bind(d.effects, d.display_name))
	var events := DebugWidgets.section(page, "Events", false)
	for e in FxCatalog.EVENTS:
		DebugWidgets.button(events, e.display_name, session.apply_effects.bind(e.effects, e.display_name))


# ---------------------------------------------------------------- View

func _build_view(page: VBoxContainer) -> void:
	for v in [["hud", "Stats HUD (fps, tick, balls)"], ["gizmos", "Gizmos (pockets, spots, velocities)"], ["netgraph", "Net graph"]]:
		_view_toggles[v[0]] = DebugWidgets.toggle(page, v[1], false, func(on: bool) -> void: debug_root.set_view(v[0], on))
	if not DisplayServer.is_touchscreen_available():
		_view_toggles["freecam"] = DebugWidgets.toggle(page, "Free camera (WASD, mouse, Q/E)", false, func(on: bool) -> void: debug_root.set_view("freecam", on))
	_staging_toggle = DebugWidgets.toggle(page, "Skip Round set-up / clean-up (this peer: no saucer, no wait)", RoundDirector.skip_staging, func(on: bool) -> void: RoundDirector.skip_staging = on)
	DebugWidgets.label(page, "Time scale")
	var row := DebugWidgets.row(page)
	for t: float in TIMESCALES:
		DebugWidgets.button(row, "%sx" % String.num(t, 2), func() -> void: debug_root.set_timescale(t))


# ---------------------------------------------------------------- refresh

func _refresh() -> void:
	_refresh_queued = false
	if not visible:
		return
	for f: StringName in _fields:
		var w: Control = _fields[f]
		if w is HSlider:
			DebugWidgets.put(w as HSlider, session.field_value(f))
		else:
			(w as CheckButton).set_pressed_no_signal(session.field_value(f) > 0.5)
	for s: StringName in _stats:
		DebugWidgets.put(_stats[s], session.stat_value(s))
	DebugWidgets.put(_tilt_dir, session.tilt_direction_deg())
	for f: StringName in _cues:
		DebugWidgets.put(_cues[f], session.cue_value(f))
	var changed_text := session.tuning_text()
	_tuning_label.text = "default numbers" if changed_text == "" else "changed:  " + changed_text.replace("\n", ",  ")
	_rebuild_shots()
	_game_label.text = _game_text()
	_staging_toggle.set_pressed_no_signal(RoundDirector.skip_staging)


func _game_text() -> String:
	var loop := session.game_loop
	if loop == null:
		return "no GameLoop in this scene"
	var money := session.economy.cash if session.economy != null else 0
	return "%s · Night %d Round %d · shots %d · %.0f s · points %d · Cash %d" % [
		GameLoop.Phase.keys()[loop.phase], loop.current_night().night_number, loop.round_index, loop.shots_left, loop.time_left, loop.round_points, money]
