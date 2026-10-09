extends SceneTree
## Waits are explained (REQ#adhoc-1010a:flow A5, spec C6): every refusal the host can send has a sentence, a
## cooldown names its seconds, "not your turn" names the shooter, "balls moving" counts them, and the host-away banner
## and a client's "Waiting for the host" count seconds.
## `godot --path . --headless -s tests/ui/wait_text_probe.gd`

const INTERACTION_REASONS := [&"unknown_kind", &"bad_payload", &"intermission_only", &"not_intermission", &"hostile_off",
		&"hostile_friends_only", &"shooter_cant_grief", &"not_live", &"once_per_round", &"no_prop", &"no_position", &"too_far",
		&"hostile_cap", &"cant_afford", &"sold_out", &"not_stocked", &"unknown_item"]
const SHOT_REASONS := [&"no_cue_ball", &"no_round", &"bad_power", &"bad_aim", &"call_pocket"]

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	_check(WaitText.shot(&"balls_moving", "", 3) == "Balls still moving (3)", "balls moving counts them")
	_check(WaitText.shot(&"not_your_turn", "Player 2") == "Not your turn: Player 2 is shooting", "not your turn names the shooter")
	_check(WaitText.interaction(&"kick_stool", &"cooldown", 4.2) == "Kick stool is cooling down: 5 s left", "cooldown: " + WaitText.interaction(&"kick_stool", &"cooldown", 4.2))
	for r: StringName in INTERACTION_REASONS:
		_check(WaitText.INTERACTION.has(r) and not WaitText.INTERACTION[r].contains("_"), "interaction reason %s has its sentence" % r)
	for r: StringName in SHOT_REASONS:
		_check(WaitText.SHOT.has(r), "shot reason %s has its sentence" % r)
	# every reason the host's validators can return is covered (grep the source, not a list that can rot)
	var src := FileAccess.get_file_as_string("res://src/gameplay/bar/world_interactions.gd")
	var re := RegEx.create_from_string('return &"(\\w+)"')
	for m in re.search_all(src):
		var id: String = m.get_string(1)
		_check(id == "cooldown" or WaitText.INTERACTION.has(StringName(id)), "world_interactions.gd returns %s: worded in WaitText" % id)

	# the host-away banner counts up and counts down to ENet's drop
	var nm := root.get_node("NetManager")
	nm.host_away_since_msec = Time.get_ticks_msec() - 12000
	var banner: String = nm.host_away_text()
	_check(banner.begins_with("Host away 12 s") and "drops in ~33 s" in banner, "host away banner: " + banner)

	# a client's phase screen counts the wait on the host
	var loop := GameLoop.new()
	var nights: Array[NightConfig] = [load("res://src/resources/nights/night_1.tres")]
	loop.nights = nights
	root.add_child(loop)
	var phase: PhaseScreen = load("res://src/ui/PhaseScreen.tscn").instantiate()
	phase.game_loop = loop
	root.add_child(phase)
	await process_frame
	phase._present("Night 1 reckoning", "Paid $600.", "Next Night", false, false)  # host = false: this peer is a client
	_check(phase.visible and not phase._next.visible and phase._text.text.ends_with("Waiting for the host · 0 s"), "client Reckoning waits on the host: " + phase._text.text)
	phase._wait_since_msec -= 3000
	phase._process(0.0)
	_check(phase._text.text.ends_with("Waiting for the host · 3 s"), "and counts the seconds: " + phase._text.text)
	phase.free()
	loop.free()
	if fails == 0:
		print("WAIT TEXT OK")
	quit(fails)
