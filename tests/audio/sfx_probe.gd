extends SceneTree
## The sound service and the bar's music (docs/plan/07 §8, 06 P54-P55), solo. Part 1 is the unit side: the buses and the three volume rows,
## every sound the code names exists and the byte budgets hold, every asset is credited, the hooks (a fx event, a button, a debug button, a
## stray player) and the Music duck. Part 2 plays a real Round on the host: the staging cues, one sound per ImpactFx event of a real shot,
## cash and interaction sounds, and the jukebox (starts with the first Round-time phase, a press skips and a 3 s gate holds, reach is
## checked, a bad frame changes nothing, a late state lands on the right second, a track chains into the next, it falls silent between Nights).
##   godot --path . --headless -s tests/audio/sfx_probe.gd        prints SFX OK
## The client side is tests/audio/sfx_pair_probe.gd.

const SFX_BUDGET := 1_500_000
const MUSIC_BUDGET := 6_000_000

var _fails := 0
var sfx: Node
var level: Node
var loop: GameLoop
var box: JukeboxPlayer


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		push_error("FAIL: " + what)
		print("FAIL: ", what)


func _until(cond: Callable, what: String, sec := 30.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_check(false, "timeout waiting for " + what)
			return


func _count(prefix: String) -> int:
	var n := 0
	for k: StringName in sfx.stats:
		if String(k).begins_with(prefix):
			n += int(sfx.stats[k])
	return n


func _run() -> void:
	SaveManager.root = "user://probe_sfx/"
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	sfx = root.get_node("Sfx")
	await _buses()
	_files()
	await _hooks()
	await _level()
	print("SFX %s" % ("OK" if _fails == 0 else "FAILED (%d)" % _fails))
	quit(0 if _fails == 0 else 1)


# --- buses and the three rows --------------------------------------------------------------------------------------------

func _buses() -> void:
	var music := AudioServer.get_bus_index(&"Music")
	var fx := AudioServer.get_bus_index(&"SFX")
	_check(music > 0 and fx > 0 and AudioServer.get_bus_send(music) == &"Master" and AudioServer.get_bus_send(fx) == &"Master", "Master > Music, SFX")
	Settings.reset_values()
	_check(is_equal_approx(Settings.value(&"music_volume"), 0.5) and is_equal_approx(Settings.value(&"sfx_volume"), 1.0), "Music defaults to 0.5, Effects to 1.0")
	_check(is_equal_approx(AudioServer.get_bus_volume_db(music), linear_to_db(0.5)) and is_equal_approx(AudioServer.get_bus_volume_db(fx), 0.0), "the defaults are on the buses")
	Settings.set_value(&"music_volume", 0.25)
	Settings.set_value(&"sfx_volume", 0.0)
	_check(is_equal_approx(AudioServer.get_bus_volume_db(music), linear_to_db(0.25)) and not AudioServer.is_bus_mute(music), "the Music row sets the Music bus")
	_check(AudioServer.is_bus_mute(fx) and not AudioServer.is_bus_mute(0), "an Effects row at 0 mutes only the SFX bus")
	Settings.set_value(&"music_volume", 7.0)
	_check(Settings.value(&"music_volume") == 1.0, "the rows clamp to 0..1")
	Settings.reset_values()
	var settings: SettingsScreen = load("res://src/ui/SettingsScreen.tscn").instantiate()
	root.add_child(settings)
	await process_frame
	var widgets: Dictionary = settings.get(&"_widgets")
	_check(widgets.has(&"music_volume") and widgets[&"music_volume"][0] is HSlider and widgets.has(&"sfx_volume") and widgets[&"sfx_volume"][0] is HSlider, "the Settings screen has a slider for Music and for Effects")
	(widgets[&"music_volume"][0] as HSlider).value = 0.3
	(widgets[&"sfx_volume"][0] as HSlider).value = 0.6
	_check(is_equal_approx(AudioServer.get_bus_volume_db(music), linear_to_db(0.3)) and is_equal_approx(AudioServer.get_bus_volume_db(fx), linear_to_db(0.6)), "dragging the sliders moves the buses")
	settings.free()
	Settings.reset_values()


# --- assets ---------------------------------------------------------------------------------------------------------------

func _files() -> void:
	var src := ""
	for f in ["res://src/core/sfx.gd", "res://src/gameplay/slot/slot_machine.gd", "res://src/gameplay/bar/jukebox_player.gd"]:
		src += FileAccess.get_file_as_string(f)
	var names := {}
	for m in RegEx.create_from_string('(?:play|play_at|_sound_at|stream)\\(\\s*&"(\\w+)"').search_all(src):
		names[m.get_string(1)] = true
	for m in RegEx.create_from_string('&"(\\w+)" if [^\\n]*? else &"(\\w+)"').search_all(src):
		names[m.get_string(1)] = true
		names[m.get_string(2)] = true
	for m in RegEx.create_from_string('\\[&"(\\w+)", -?[\\d.]+, [\\d.]+\\]').search_all(src):
		names[m.get_string(1)] = true  # Sfx.PROP_SOUND rows
	for m in RegEx.create_from_string('&"(\\w+)" (?:if|else)').search_all(src):
		names[m.get_string(1)] = true
	var files := DirAccess.get_files_at("res://assets/audio/sfx")
	var stems := {}
	var sfx_bytes := 0
	for f in files:
		if f.ends_with(".ogg"):
			stems[f.get_basename()] = true
			sfx_bytes += FileAccess.open("res://assets/audio/sfx/" + f, FileAccess.READ).get_length()
	var shown := 0
	for n: String in names:
		if not stems.has(n) and not n.begins_with("clack_") and shown < 5:
			shown += 1
			_check(false, "the code names sound '%s' but assets/audio/sfx has no such file" % n)
	for layer in ["soft", "med", "hard"]:
		for v in ["a", "b"]:
			_check(stems.has("clack_%s_%s" % [layer, v]), "clack_%s_%s exists" % [layer, v])
	for s: String in stems:
		var used := names.has(s) or s.begins_with("clack_") or src.contains(s)
		_check(used, "sound '%s' is shipped but nothing plays it" % s)
		_check(sfx.call(&"stream", StringName(s)) is AudioStreamOggVorbis, "'%s' loads as Ogg Vorbis" % s)
	var music_bytes := 0
	var tracks := 0
	for f in DirAccess.get_files_at("res://assets/audio/music"):
		if f.ends_with(".ogg"):
			tracks += 1
			music_bytes += FileAccess.open("res://assets/audio/music/" + f, FileAccess.READ).get_length()
	_check(sfx_bytes <= SFX_BUDGET, "SFX %d bytes <= %d" % [sfx_bytes, SFX_BUDGET])
	_check(music_bytes <= MUSIC_BUDGET, "music %d bytes <= %d" % [music_bytes, MUSIC_BUDGET])
	_check(tracks >= 3 and tracks <= 5 and tracks == JukeboxPlayer.TRACKS.size(), "3-5 tracks, all in the jukebox: %d" % tracks)
	for t in JukeboxPlayer.TRACKS:
		_check(load(t.path) is AudioStreamOggVorbis and not (load(t.path) as AudioStreamOggVorbis).loop and (load(t.path) as AudioStreamOggVorbis).get_length() > 60.0, "track '%s' loads, plays once, is over a minute" % t.title)
	var credits := FileAccess.get_file_as_string("res://assets/CREDITS.md")
	_check(credits != "", "assets/CREDITS.md exists")
	var uncredited := PackedStringArray()
	for dir in ["res://assets/audio/sfx", "res://assets/audio/music"]:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".ogg") and not credits.contains(f.get_basename()):
				uncredited.append(f)
	_check(uncredited.is_empty(), "every audio file is credited in assets/CREDITS.md: missing %s" % [uncredited])
	for t in JukeboxPlayer.TRACKS:
		_check(credits.contains(t.title) and credits.contains(t.by) and credits.contains("CC0"), "the credits name track '%s' by %s and its licence" % [t.title, t.by])


# --- hooks ----------------------------------------------------------------------------------------------------------------

func _hooks() -> void:
	var fx := ImpactFx.new()  # no table, no director: `_ready` leaves it idle; only its signal matters
	root.add_child(fx)
	var before := _count("clack_")
	fx.fx_fired.emit(&"ball", 1.0)
	fx.fx_fired.emit(&"ball", 3.0)
	fx.fx_fired.emit(&"ball", 7.5)
	_check(_count("clack_") == before + 3 and int(sfx.stats.get(&"clack_soft_a", 0)) + int(sfx.stats.get(&"clack_soft_b", 0)) >= 1, "three ball hits make three clacks, soft for a gentle one")
	_check(_count("clack_hard_") >= 1 and _count("clack_med_") >= 1, "hardness layers follow the speed")
	var players: Array = sfx.get(&"_room")
	var next: int = sfx.get(&"_next_room")
	var loudest: AudioStreamPlayer3D = players[(next - 1 + players.size()) % players.size()]
	var quietest: AudioStreamPlayer3D = players[(next - 3 + players.size()) % players.size()]
	_check(loudest.volume_db > quietest.volume_db + 10.0 and loudest.volume_db <= 0.0, "a hard hit is louder than a soft one (%.1f vs %.1f dB)" % [loudest.volume_db, quietest.volume_db])
	_check(loudest.bus == &"SFX" and loudest.playing, "table sounds are 3D on the SFX bus and playing")
	for pair in [[&"kick", "cue_tip"], [&"rail", "rail_"], [&"pot", "pocket_drop"], [&"scratch", "pocket_drop"], [&"trick", "trick"], [&"hazard", "hazard"], [&"go", "go"], [&"time", "time_up"], [&"drink", "drink"], [&"cleared", "fanfare"], [&"jackpot", "jackpot"]]:
		var c := _count(pair[1])
		fx.fx_fired.emit(pair[0], 3.0)
		_check(_count(pair[1]) == c + 1, "fx '%s' plays %s" % [pair[0], pair[1]])
	var ding := int(sfx.stats.get(&"ding", 0))
	fx.fx_fired.emit(&"pot", 5.0)
	_check(int(sfx.stats.get(&"ding", 0)) == ding + 1, "a pot dings (pitched by the combo)")
	var unknown := _count("")
	fx.fx_fired.emit(&"flames", 4.0)
	fx.fx_fired.emit(&"nothing_we_know", 1.0)
	_check(_count("") == unknown, "kinds with no sound stay silent")
	fx.queue_free()

	var b := Button.new()
	root.add_child(b)
	var taps := _count("ui_")
	b.pressed.emit()
	_check(_count("ui_") == taps + 1, "a button press taps")
	var primary := Button.new()
	primary.theme_type_variation = &"PrimaryButton"
	root.add_child(primary)
	var confirms := int(sfx.stats.get(&"ui_confirm", 0))
	primary.pressed.emit()
	_check(int(sfx.stats.get(&"ui_confirm", 0)) == confirms + 1, "a primary button confirms")
	var strip: CanvasLayer = load("res://src/debug/debug_strip.gd").new()  # by path: DebugStrip names NetManager, which a `-s` script cannot compile
	root.add_child(strip)
	await process_frame
	var strip_buttons := strip.find_children("*", "Button", true, false)
	_check(strip_buttons.size() >= 3 and strip_buttons.all(func(n: Node) -> bool: return not n.has_meta(&"sfx")) and b.has_meta(&"sfx"), "the debug strip's buttons are not hooked; a normal one is")
	b.queue_free()
	primary.queue_free()
	strip.queue_free()

	var stray := AudioStreamPlayer.new()
	root.add_child(stray)
	var music := AudioStreamPlayer.new()
	music.bus = &"Music"
	root.add_child(music)
	_check(stray.bus == &"SFX" and music.bus == &"Music", "a player left on Master moves to SFX; a Music one stays")
	stray.queue_free()
	music.queue_free()

	var bus := AudioServer.get_bus_index(&"Music")
	var base := linear_to_db(Settings.value(&"music_volume"))  # (the bus may still be mid-duck from the jackpot / cleared events above)
	sfx.call(&"duck", 0.2)
	await create_timer(0.35).timeout
	_check(AudioServer.get_bus_volume_db(bus) < base - 6.0, "a jackpot ducks the Music bus (%.1f -> %.1f dB)" % [base, AudioServer.get_bus_volume_db(bus)])
	await create_timer(1.3).timeout
	_check(is_equal_approx(AudioServer.get_bus_volume_db(bus), base), "and it comes back (%.1f dB)" % AudioServer.get_bus_volume_db(bus))


# --- a real Round on the host ---------------------------------------------------------------------------------------------

func _level() -> void:
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, false, true)  # keep_staging: the cues are what we are after
	level = current_scene
	loop = level.get_node("GameLoop")
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	var econ: EconomyManager = level.get_node("EconomyManager")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	var player: Player = level.get_node("PlayerSpawner").get_local_player()
	var table: Table = level.get_node("Table")
	var rd: RoundDirector = level.get_node("RoundDirector")
	box = level.get_node("Bar/Jukebox")
	await _music(player)

	# cash and interactions are heard
	var coins := int(sfx.stats.get(&"coin", 0))
	econ.add_cash(120, &"shot")
	_check(int(sfx.stats.get(&"coin", 0)) == coins + 1, "a payout clinks")
	var reg := int(sfx.stats.get(&"register", 0))
	econ.add_cash(-10, &"shop")
	_check(int(sfx.stats.get(&"register", 0)) == reg + 1, "a purchase rings the register")
	econ.add_cash(-10, &"slot")
	_check(int(sfx.stats.get(&"register", 0)) == reg + 1, "a slot stake does not (the machine has its own sounds)")
	player.global_position = Vector3(0.0, 0.05, -1.2)
	var bumps := int(sfx.stats.get(&"bump", 0))
	world.interaction_applied.emit(1, &"bump_table", 0, {})
	_check(int(sfx.stats.get(&"bump", 0)) == bumps + 1, "bumping the table thumps")
	var readys := int(sfx.stats.get(&"ready_on", 0))
	world.interaction_applied.emit(1, &"go_live", 0, {})
	_check(int(sfx.stats.get(&"ready_on", 0)) == readys + 1, "GO LIVE clicks")

	# GO LIVE: the set-up is heard, in order
	var fx: ImpactFx = level.get_node("ImpactFx")
	var heard := {}
	fx.fx_fired.connect(func(kind: StringName, _s: float) -> void: heard[kind] = int(heard.get(kind, 0)) + 1)
	loop.toggle_ready(1)
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.ROUND_LIVE, "Round 1 live", 40.0)
	await _until(func() -> bool: return not rd.staging, "the set-up to finish", 15.0)
	for k in [&"vent_open", &"ufo_whoosh", &"vent_close", &"beam_blip", &"ufo_farewell"]:
		_check(int(sfx.stats.get(k, 0)) >= 1, "the set-up plays %s" % k)
	_check(int(heard.get(&"go", 0)) == 1 and int(sfx.stats.get(&"go", 0)) >= 1, "GO! sounds once")
	var balls: int = rd.get_balls().size()
	_check(int(sfx.stats.get(&"beam_blip", 0)) == balls, "one beam blip per ball (%d of %d)" % [int(sfx.stats.get(&"beam_blip", 0)), balls])
	_check(int(sfx.stats.get(&"vent_open", 0)) == 1 and int(sfx.stats.get(&"vent_close", 0)) == 1, "the vent opens and shuts once each")

	# a real shot: one sound per ImpactFx event
	await create_timer(0.3).timeout
	var before: Dictionary = sfx.stats.duplicate()
	heard.clear()
	var cue: Ball = null
	var target: Ball = null
	for ball in rd.get_balls():
		if ball.is_cue_ball:
			cue = ball
	for ball in rd.get_balls():
		if not ball.is_cue_ball and (target == null or ball.global_position.distance_to(cue.global_position) < target.global_position.distance_to(cue.global_position)):
			target = ball
	var d := target.global_position - cue.global_position
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 0.9
	table.sim.request_shot(intent)
	await rd.shot_ended
	await create_timer(0.3).timeout
	var delta := func(prefix: String) -> int:
		var n := 0
		for k: StringName in sfx.stats:
			if String(k).begins_with(prefix):
				n += int(sfx.stats[k]) - int(before.get(k, 0))
		return n
	print("sfx: the shot fired %s" % str(heard))
	_check(int(heard.get(&"kick", 0)) == 1 and delta.call("cue_tip") == 1, "the strike makes one cue sound")
	_check(int(heard.get(&"ball", 0)) >= 1 and delta.call("clack_") == int(heard.get(&"ball", 0)), "every ball hit makes exactly one clack (%d)" % delta.call("clack_"))
	_check(delta.call("rail_") == int(heard.get(&"rail", 0)), "every cushion hit makes exactly one rail sound (%d)" % delta.call("rail_"))
	_check(delta.call("pocket_drop") == int(heard.get(&"pot", 0)) + int(heard.get(&"scratch", 0)) + int(heard.get(&"penalty", 0)), "every pocketed ball drops once")

	# the clean-up is heard too
	var flaps := int(sfx.stats.get(&"flap_open", 0))
	loop.call(&"_end_round", &"timer")
	await _until(func() -> bool: return int(sfx.stats.get(&"flap_shut", 0)) >= 1, "the table pit's flaps to shut", 12.0)
	_check(int(sfx.stats.get(&"flap_open", 0)) == flaps + 1 and int(sfx.stats.get(&"flap_shut", 0)) == 1, "the clean-up opens and shuts the flaps once each")


# --- the jukebox, host side ---------------------------------------------------------------------------------------------------

func _music(player: Player) -> void:
	var n := JukeboxPlayer.TRACKS.size()
	_check(box.track >= 0 and box.track < n, "the music started with the first Round-time phase on track %d" % box.track)
	await create_timer(0.6).timeout
	var near: AudioStreamPlayer3D = box.get(&"_near")
	var floor_: AudioStreamPlayer = box.get(&"_floor")
	_check(near.playing and floor_.playing and near.bus == &"Music" and floor_.bus == &"Music", "one 3D player at the jukebox and a room-wide floor, both on the Music bus")
	_check(near.global_position.is_equal_approx(Bar.JUKEBOX_AT) and floor_.volume_db < near.volume_db - 10.0, "the 3D player is at the jukebox and the floor sits well under it")
	var p0 := box.playhead()
	_check(int(p0.track) == box.track and float(p0.offset) < 5.0, "the playhead is near the start (%.1f s)" % float(p0.offset))

	# a press: free, skips for everyone, 3 s gate; reach is the host's
	var switch := int(sfx.stats.get(&"ui_switch", 0))
	var start: int = box.track
	player.global_position = Vector3(6.3, 0.05, 5.8)
	player.velocity = Vector3.ZERO
	await create_timer(0.2).timeout
	var prop: Interactable
	for node in get_nodes_in_group(&"interactable"):
		if (node as Interactable).effective_kind() == &"jukebox":
			prop = node
	_check(prop is JukeboxProp, "the jukebox prop is a JukeboxProp")
	prop.try_use()
	_check(box.track == (start + 1) % n and int(box.playhead().offset) == 0 and int(sfx.stats.get(&"ui_switch", 0)) == switch + 1, "a press skips to the next track and clicks (track %d -> %d)" % [start, box.track])
	prop.try_use()
	_check(box.track == (start + 1) % n, "a second press inside 3 s is ignored")
	box.set(&"_next_press_msec", 0)
	_check(not box.skip(1), "the host's own 3 s gate holds as well")
	box.set(&"_next_skip_msec", 0)
	player.global_position = Vector3(-3.0, 0.05, 1.0)
	_check(not box.skip(1) and box.track == (start + 1) % n, "out of reach: refused, the track stays")
	_check(not box.skip(77) and box.track == (start + 1) % n, "an unknown peer: refused")
	player.global_position = Vector3(6.3, 0.05, 5.8)
	await create_timer(0.1).timeout
	_check(box.skip(1) and box.track == (start + 2) % n, "in reach and past the gate: skips again")

	# frames from the host: bad ones change nothing, a late state lands on the right second, a track runs on into the next
	var t: int = box.track
	for bad in [[9, 1.0], [-2, 0.0], [1, NAN], [1, -3.0], [1, INF]]:
		box.jukebox_state(bad[0], bad[1])
	_check(box.track == t, "a bad frame changes nothing")
	box.jukebox_state(2, 30.0)
	var p := box.playhead()
	_check(int(p.track) == 2 and absf(float(p.offset) - 30.0) < 0.3, "a late state: track 2 at 30 s (%d at %.2f)" % [int(p.track), float(p.offset)])
	await create_timer(0.3).timeout
	_check(absf(near.get_playback_position() - float(box.playhead().offset)) < 0.6 and near.stream == (load(JukeboxPlayer.TRACKS[2].path) as AudioStream), "the players follow the playhead")
	var len0 := (load(JukeboxPlayer.TRACKS[0].path) as AudioStream).get_length()
	box.jukebox_state(0, len0 - 0.8)
	await create_timer(1.6).timeout
	p = box.playhead()
	_check(int(p.track) == 1 and float(p.offset) < 1.5, "the end of a track runs on into the next (track %d at %.2f s)" % [int(p.track), float(p.offset)])
	await _until(func() -> bool: return near.stream == (load(JukeboxPlayer.TRACKS[1].path) as AudioStream) and near.playing, "the player to chain to track 1", 5.0)

	# between the story beats and at the endings the room is quiet; the playhead keeps going
	loop.phase = GameLoop.Phase.NIGHT_START
	await create_timer(1.2).timeout
	_check(not near.playing and not floor_.playing, "NIGHT_START is quiet")
	loop.phase = GameLoop.Phase.INTERMISSION
	await create_timer(0.6).timeout
	_check(near.playing and absf(near.get_playback_position() - float(box.playhead().offset)) < 0.6, "and the music is back at the clock's second, not at the start")
