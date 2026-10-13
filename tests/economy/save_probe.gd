extends SceneTree
## Headless save probe (docs/plan/04 §2.6; 02 §3.4, §3.7, §3.11; M5): SaveProfile round-trip, v1 → v2 → v3 migration,
## refusal of a newer save, checkpoint files, persistent unlocks, a Round-end checkpoint + resume, Endless, mode + run stats.
##   godot --path . --headless -s tests/economy/save_probe.gd
## Prints SAVE OK, or the failing checks and SAVE FAIL (exit 1).

var TEST_DIR := "user://test_save_%d" % OS.get_process_id()  # per process: probes run concurrently across worktrees and share user://

var fails := 0
var finished := false
var asked: Array[int] = []


func _init() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		if not finished:
			print("SAVE FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	SaveManager.root = TEST_DIR
	_roundtrip()
	_migrate()
	_migrate_v3()
	_files()
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	await _checkpoint_and_resume()
	_endless()
	_cleanup()
	finished = true
	print("SAVE OK" if fails == 0 else "SAVE FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _profile() -> SaveProfile:
	var p := SaveProfile.new()
	p.crew_cash = 1500
	p.current_night = 3
	p.round_index = 2
	p.quota_target = 1350
	p.viewers = 640
	p.hype = 0.4
	p.owned_items = {&"tier2_rack": 1, &"lens_t2": 1, &"heavy_shaft": 1, &"fresh_cloth": 1}
	p.persistent_unlocks = [&"tier2_rack", &"lens_t2"] as Array[StringName]
	p.campaign_seed = 884213
	p.mode = &"endless"
	p.run_stats = {"pots": 41, "best_combo": 6, "cash_earned": 5230, "nights_cleared": 2, "play_time": 1812.5}
	return p


func _roundtrip() -> void:
	var blob := SaveManager.encode(_profile())
	_check(blob.size() < 1024, "profile under 1 KB (%d B)" % blob.size())
	var q := SaveManager.decode(blob)
	_check(q != null and q.crew_cash == 1500 and q.current_night == 3 and q.round_index == 2 and q.quota_target == 1350, "scalars round-trip")
	_check(q.viewers == 640 and is_equal_approx(q.hype, 0.4) and q.campaign_seed == 884213 and q.save_version == SaveManager.SAVE_VERSION, "stream + seed + version")
	_check(q.owned_items == _profile().owned_items and q.persistent_unlocks == _profile().persistent_unlocks, "owned + persistent round-trip")
	_check(q.mode == &"endless" and RunStats.from_dict(q.run_stats).to_dict() == RunStats.from_dict(_profile().run_stats).to_dict(), "v3: mode + run stats round-trip")
	_check(q.run_stats.get("pots") == 41 and RunStats.from_dict(q.run_stats).play_time == 1812.5, "the tally survives JSON")
	var d: Dictionary = JSON.parse_string(blob.get_string_from_utf8())
	_check(d.unlocked.ball_types == ["tier2_rack"] and d.unlocked.cameras == ["lens_t2"] and d.unlocked.cue == ["heavy_shaft"], "04 §2.6 unlocked lists")


func _migrate() -> void:
	var v1 := {"save_version": 1, "crew_cash": 900, "current_night": 2, "round_index": 1, "quota_target": 900,
		"unlocked": {"ball_types": ["tier2_rack"], "cameras": ["lens_t2"], "cue": []}, "persistent_unlocks": ["tier2_rack"], "seed": 7}
	var p := SaveManager.decode(JSON.stringify(v1).to_utf8_buffer())
	_check(p != null and p.save_version == SaveManager.SAVE_VERSION, "v1 loads at the current version")
	_check(p.crew_cash == 900 and p.campaign_seed == 7 and p.owned_items.get(&"tier2_rack") == 1 and p.owned_items.get(&"lens_t2") == 1, "v1 fields carried into owned_items/seed")
	_check(p.viewers == -1, "v1 has no viewers: resume from the Night's base")
	_check(p.mode == &"campaign" and p.run_stats.is_empty(), "v1 (Night 2) migrates to a Campaign with no tally")
	var newer := {"save_version": SaveManager.SAVE_VERSION + 1, "crew_cash": 1}
	_check(SaveManager.decode(JSON.stringify(newer).to_utf8_buffer()) == null and SaveManager.last_error == &"newer_version", "a newer save is refused, not truncated")
	_check(SaveManager.decode("not json".to_utf8_buffer()) == null and SaveManager.last_error == &"corrupt", "garbage is refused")


## 04 §2.6 / 06 P39: a v2 checkpoint has no mode. Night 1-3 resume as the Campaign, Night 4-5 (the old 5-Night run) as Endless.
func _migrate_v3() -> void:
	for pair: Array in [[1, &"campaign"], [3, &"campaign"], [4, &"endless"], [5, &"endless"], [6, &"endless"]]:
		var v2 := {"save_version": 2, "crew_cash": 700, "current_night": pair[0], "round_index": 1, "quota_target": 900, "viewers": 300, "hype": 0.2,
			"owned_items": {"tier2_rack": 1}, "persistent_unlocks": [], "seed": 11, "crew_size": 1}
		var p := SaveManager.decode(JSON.stringify(v2).to_utf8_buffer())
		_check(p != null and p.save_version == 3 and p.mode == pair[1] and p.current_night == pair[0], "v2 at Night %d resumes as %s, same index" % [pair[0], pair[1]])
		_check(p.run_stats.is_empty() and p.crew_cash == 700 and p.owned_items.get(&"tier2_rack") == 1, "...with the rest carried and an empty tally")
	_check(SaveManager.SAVE_VERSION == 3, "SAVE_VERSION is 3")
	var lobby_ui: GDScript = load("res://src/ui/lobby_ui.gd")
	_check(lobby_ui.resume_label({modified = 0, crew = 1, night = 4, round_index = 1, cash = 5, mode = &"endless"}).begins_with("Endless · Night 4"), "the Resume list marks an Endless run")
	_check(not lobby_ui.resume_label({modified = 0, crew = 1, night = 2, round_index = 1, cash = 5, mode = &"campaign"}).contains("Endless"), "...and not a Campaign")


func _files() -> void:
	_check(SaveManager.checkpoint_key("", 1, 5) == "solo" and SaveManager.checkpoint_key("ABCD", 3, 5) == "ABCD"
		and SaveManager.checkpoint_key("", 2, 5) == "lan-5", "checkpoint key: solo / lobby code / LAN seed")
	_check(SaveManager.write_checkpoint("ABCD", SaveManager.encode(_profile())), "write checkpoint")
	var list := SaveManager.list_checkpoints()
	_check(list.size() == 1 and list[0].key == "ABCD" and list[0].night == 3 and list[0].cash == 1500 and list[0].mode == &"endless", "list_checkpoints")
	_check(SaveManager.load_checkpoint(list[0].path).crew_cash == 1500, "load_checkpoint")
	SaveManager.save_persistent([&"lens_t3"] as Array[StringName])
	_check(SaveManager.load_persistent() == ([&"lens_t3"] as Array[StringName]), "persistent file round-trip")
	SaveManager.receive_checkpoint("", 2, 9, SaveManager.SAVE_VERSION, SaveManager.encode(_profile()))
	_check(FileAccess.file_exists(SaveManager.checkpoint_path("lan-9")), "a client stores the pushed checkpoint")
	SaveManager.receive_checkpoint("", 2, 9, SaveManager.SAVE_VERSION, PackedByteArray())
	_check(not FileAccess.file_exists(SaveManager.checkpoint_path("lan-9")), "an empty blob (run over) deletes it")
	for i in SaveManager.KEEP_CHECKPOINTS + 3:
		SaveManager.write_checkpoint("bulk%d" % i, SaveManager.encode(_profile()))
	_check(DirAccess.get_files_at(SaveManager.checkpoint_dir()).size() <= SaveManager.KEEP_CHECKPOINTS, "only the newest %d checkpoints are kept" % SaveManager.KEEP_CHECKPOINTS)
	for i in 5:
		SaveManager.write_checkpoint("tie%d" % i, SaveManager.encode(_profile()))
		_check(FileAccess.file_exists(SaveManager.checkpoint_path("tie%d" % i)), "a same-second write survives its own prune")
	SaveManager.receive_checkpoint("", 2, 9, SaveManager.SAVE_VERSION + 1, PackedByteArray([1]))
	_check(not FileAccess.file_exists(SaveManager.checkpoint_path("lan-9")), "a newer-version checkpoint is not stored")


func _checkpoint_and_resume() -> void:
	var level := current_scene
	var loop: GameLoop = level.get_node("GameLoop")
	var eco: EconomyManager = level.get_node("EconomyManager")
	var stream: StreamManager = level.get_node("StreamManager")
	eco.add_cash(2000, &"test")
	eco.try_purchase(&"tier2_rack", 1)
	eco.try_purchase(&"heavy_shaft", 1)
	loop.advance()
	await _frames(10)
	stream.add_viewers(300)
	var cash := eco.cash
	var viewers := stream.viewers
	loop.call(&"_end_round", &"timer")
	await _frames(3)
	var path := SaveManager.checkpoint_path("solo")
	_check(FileAccess.file_exists(path), "checkpoint written at Round end")
	var p := SaveManager.load_checkpoint(path)
	_check(p != null and p.crew_cash == cash and p.current_night == 1 and p.round_index == 1 and p.viewers == viewers, "checkpoint holds Night/Round/Cash/viewers")
	_check(p.owned_items.get(&"tier2_rack") == 1 and p.owned_items.get(&"heavy_shaft") == 1 and p.campaign_seed == loop.campaign_seed, "…and the Shop + seed")
	eco.cash = 0
	eco.owned.clear()
	stream.viewers = 0
	loop.round_index = 0
	loop.resume_from(p)
	_check(eco.cash == cash and eco.count_of(&"tier2_rack") == 1 and eco.count_of(&"heavy_shaft") == 1, "resume restores Cash + Shop")
	_check(loop.phase == GameLoop.Phase.INTERMISSION and loop.round_index == 1 and stream.viewers == viewers, "resume lands in the Intermission before Round 2")
	_check(eco.build_cue_spec().power_cap_speed_mps > 11.0, "…with the cue upgrade live")
	# a passed Night 1 checkpoints as 'Night 2, not started'
	loop.round_index = 3
	eco.cash = 9999
	var after := loop.build_profile()
	_check(after.current_night == 2 and after.round_index == 0 and after.quota_target == 900, "after Round 3 the resume point is Night 2's start")


func _endless() -> void:
	var loop: GameLoop = current_scene.get_node("GameLoop")
	var n3 := loop.night_at(2)
	var n4 := loop.night_at(3)
	var n5 := loop.night_at(4)
	_check(n4.night_number == 4 and n4.quota == 2160 and n4.base_viewers == 750 and n4.hazard_tiers == ([1, 2, 3] as Array[int]), "Night 4: quota ×1.6, +300 viewers, tiers 1/2/3")
	_check(n5.night_number == 5 and n5.quota == 3456 and n5.base_viewers == 1050, "Night 5 compounds")
	_check(loop.night_at(3) == n4, "generated Nights are cached")
	_check(n4.authored_racks.is_empty() and n4.finale_racks.is_empty() and n3.finale_racks.size() == 3, "the Campaign's finale racks stay on Night 3 and never reach Endless")
	_check(n3.round_time_limit_sec > n4.round_time_limit_sec and n4.round_time_limit_sec > n5.round_time_limit_sec and n5.round_time_limit_sec >= NightConfig.ROUND_TIME_MIN_SEC, "Endless Rounds shorten, never under the floor")
	_check(loop.night_at(12).round_time_limit_sec == NightConfig.ROUND_TIME_MIN_SEC, "...and stop at it")
	loop.night_index = 2
	loop.phase = GameLoop.Phase.CAMPAIGN_WON
	loop.night_started.connect(func(n: int, q: int) -> void: asked.assign([n, q]))
	loop.advance()
	_check(asked == ([4, 2160] as Array[int]) and loop.phase == GameLoop.Phase.INTERMISSION and loop.mode == GameLoop.MODE_ENDLESS, "Endless follows the won campaign; no Buyout on Night 4")


func _cleanup() -> void:
	for d in DirAccess.get_directories_at(TEST_DIR):
		for f in DirAccess.get_files_at(TEST_DIR.path_join(d)):
			DirAccess.remove_absolute(TEST_DIR.path_join(d).path_join(f))
		DirAccess.remove_absolute(TEST_DIR.path_join(d))
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR.path_join(f))
	DirAccess.remove_absolute(TEST_DIR)
