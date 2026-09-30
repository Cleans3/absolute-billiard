extends SceneTree
## Headless Shop probe (docs/plan/02 §3.6; M5): catalog rows, gating (cost, min_night, once, phase), cue/ball/
## camera/table/stream upgrades folded from owned items, the bar route, persistence across a wipe.
##   godot --path . --headless -s tests/economy/shop_probe.gd
## Boots the real MainLevel through Lobby → Solo. Prints SHOP OK, or the failing checks and SHOP FAIL (exit 1).

const ROWS := {
	&"polish_the_set": [&"ball", 250], &"tier2_rack": [&"ball", 400], &"tier3_rack": [&"ball", 900],
	&"bomb_ball": [&"ball", 300], &"split_ball": [&"ball", 450], &"joker_ball": [&"ball", 600],
	&"heavy_shaft": [&"cue", 300], &"chalk_tin": [&"cue", 350], &"jump_cue": [&"cue", 500], &"custom_tip": [&"cue", 250],
	&"lens_t2": [&"camera", 400], &"lens_t3": [&"camera", 800], &"spare_tripod": [&"camera", 500],
	&"magnetic_pockets": [&"table", 600], &"stream_overlay": [&"table", 500], &"fresh_cloth": [&"table", 350],
}
var TEST_DIR := "user://test_shop_%d" % OS.get_process_id()  # per process: probes run concurrently across worktrees and share user://

var fails := 0
var finished := false
var eco: EconomyManager
var loop: GameLoop
var fx: EffectManager
var stream: StreamManager


func _init() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		if not finished:
			print("SHOP FAIL (script error or hang)")
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
	_catalog()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	SaveManager.root = TEST_DIR
	SaveManager.save_persistent([] as Array[StringName])
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _frames(8)
	var level := current_scene
	eco = level.get_node("EconomyManager")
	loop = level.get_node("GameLoop")
	fx = level.get_node("EffectManager")
	stream = level.get_node("StreamManager")
	_check(loop.phase == GameLoop.Phase.INTERMISSION, "starts in Intermission")
	_gating()
	_upgrades()
	await _round_effects()
	_bar_and_drinks()
	_persistence()
	_cleanup()
	finished = true
	print("SHOP OK" if fails == 0 else "SHOP FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _catalog() -> void:
	_check(ShopCatalog.all().size() == ROWS.size() + FxCatalog.DRINKS.size(), "16 rows + %d drinks" % FxCatalog.DRINKS.size())
	for id: StringName in ROWS:
		var it := ShopCatalog.item(id)
		_check(it != null and it.category == ROWS[id][0] and it.cost_cash == ROWS[id][1], "row %s category/cost" % id)
	_check(ShopCatalog.item(&"beer").cost_cash == 50 and ShopCatalog.item(&"beer").category == &"drink", "drinks come from the 03 catalog")
	_check(ShopCatalog.item(&"bomb_ball").min_night == 2 and ShopCatalog.item(&"split_ball").min_night == 3
		and ShopCatalog.item(&"joker_ball").min_night == 4, "gimmick balls gate on min_night 2/3/4")
	_check(ShopCatalog.item(&"lens_t2").persistent and not ShopCatalog.item(&"heavy_shaft").persistent, "persistent flags")


func _gating() -> void:
	_check(eco.can_buy(&"polish_the_set") == &"cant_afford", "no Cash → cant_afford")
	eco.add_cash(5000, &"test")
	_check(eco.can_buy(&"bomb_ball") == &"locked", "bomb_ball locked on Night 1")
	_check(eco.try_purchase(&"polish_the_set", 1) and eco.cash == 4750, "buy charges the cost")
	_check(not eco.try_purchase(&"polish_the_set", 1) and eco.last_refusal == &"owned", "second copy refused")
	_check(eco.cash == 4750, "a refusal costs nothing")
	_check(eco.can_buy(&"nope") == &"unknown_item", "unknown item")
	var seen: Array[StringName] = []
	eco.item_purchased.connect(func(id: StringName, _b: int) -> void: seen.append(id))
	eco.try_purchase(&"tier2_rack", 1)
	_check(seen == [&"tier2_rack"], "item_purchased fires once")


func _upgrades() -> void:
	for id in [&"heavy_shaft", &"chalk_tin", &"jump_cue", &"custom_tip"]:
		_check(eco.try_purchase(id, 1), "buy %s" % id)
	var spec := eco.build_cue_spec()
	_check(is_equal_approx(spec.power_cap_speed_mps, 11.5), "heavy_shaft: power cap ×1.15 (got %s)" % spec.power_cap_speed_mps)
	_check(is_equal_approx(spec.spin_offset_radius, 0.42), "chalk_tin: spin radius ×1.20 (got %s)" % spec.spin_offset_radius)
	_check(spec.jump_unlocked and spec.masse_unlocked and is_equal_approx(spec.wobble_reduction, 2.0), "jump/masse/wobble")
	var base: Array[StringName] = [&"red_basic", &"black_penalty"]
	var pool := eco.unlocked_ball_types(base)
	_check(pool.has(&"blue_mid") and not pool.has(&"gold_prize"), "tier2_rack adds blue_mid only")
	eco.try_purchase(&"tier3_rack", 1)
	eco.owned[&"bomb_ball"] = 1  # bought on a later Night; RULES has not shipped the BallType yet
	pool = eco.unlocked_ball_types(base)
	_check(pool.has(&"gold_prize") and not pool.has(&"bomb_ball"), "tier3_rack adds gold; a type with no resource is skipped")
	eco.owned.erase(&"bomb_ball")
	var ov := eco.ball_overrides()
	_check(ov.size() == 1 and ov[0].id == &"red_basic" and ov[0].base_value == 130, "polish_the_set: red_basic 100 → 130")
	_check(eco.round_config(loop.current_night()).unlocked_ball_types.has(&"blue_mid"), "round_config carries the pool")
	_check(eco.camera_tier() == 1 and eco.rig_count() == 2, "2 tier-1 rigs to start")
	eco.try_purchase(&"lens_t2", 1)
	_check(eco.camera_tier() == 2, "lens_t2")
	eco.try_purchase(&"lens_t3", 1)
	_check(eco.camera_tier() == 3, "lens_t3")
	eco.add_cash(3000, &"test")
	_check(eco.try_purchase(&"spare_tripod", 1) and eco.try_purchase(&"spare_tripod", 1) and eco.rig_count() == 4, "2 spare tripods → 4 rigs")
	_check(not eco.try_purchase(&"spare_tripod", 1) and eco.last_refusal == &"owned", "rig cap 4")
	eco.add_cash(3000, &"test")
	eco.try_purchase(&"stream_overlay", 1)
	_check(stream.base_viewers_bonus == 150 and is_equal_approx(stream.tip_rate_mult, 1.5), "stream_overlay reaches StreamManager")
	eco.try_purchase(&"magnetic_pockets", 1)
	eco.try_purchase(&"fresh_cloth", 1)


func _round_effects() -> void:
	loop.advance()
	await _frames(10)
	_check(loop.phase == GameLoop.Phase.ROUND_LIVE, "Round live")
	_check(is_equal_approx(fx.get_stat(&"pocket_radius_mult", -1, 1.0), 1.1), "magnetic_pockets applied as a Round Effect")
	_check(is_equal_approx(fx.get_stat(&"cloth_friction_mult", -1, 1.0), 0.98), "fresh_cloth applied as a Round Effect")
	_check(eco.can_buy(&"lens_t2") == &"closed" or eco.can_buy(&"lens_t2") == &"owned", "non-drinks closed mid-Round")
	eco.add_cash(500, &"test")
	_check(eco.try_purchase(&"beer", 1), "beer (mid_round) is sold during a Round")
	loop.call(&"_end_round", &"timer")
	await _frames(3)
	_check(not fx.is_live(&"shop_magnetic_pockets"), "Round Effects expire with the Round")
	loop.advance()
	await _frames(10)
	_check(fx.is_live(&"shop_magnetic_pockets"), "re-applied next Round")
	_check(is_equal_approx(stream.base_viewers_bonus, 150), "bonus survives the Round")
	loop.call(&"_end_round", &"timer")
	await _frames(3)


func _bar_and_drinks() -> void:
	var world: WorldInteractions = current_scene.get_node("WorldInteractions")
	var before := eco.cash
	world.bar_purchase_requested.emit(&"bar_buy", 1, &"ice_water", 1)
	_check(eco.cash == before - ShopCatalog.item(&"ice_water").cost_cash, "bar_buy routes through try_purchase")
	eco.cash = 0
	_check(not eco.try_purchase(&"moonshine", 1) and eco.last_refusal == &"cant_afford", "broke: drink refused")


func _persistence() -> void:
	var saved := SaveManager.load_persistent()
	_check(saved.has(&"tier2_rack") and saved.has(&"lens_t3") and not saved.has(&"heavy_shaft"), "persistent file: %s" % [saved])
	eco.wipe()
	_check(eco.cash == 0 and eco.count_of(&"tier2_rack") == 1 and eco.count_of(&"heavy_shaft") == 0, "wipe keeps persistent items only")
	_check(not eco.build_cue_spec().jump_unlocked, "cue mods reset with the wipe")


func _cleanup() -> void:
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR.path_join(f))
	for d in DirAccess.get_directories_at(TEST_DIR):
		for f in DirAccess.get_files_at(TEST_DIR.path_join(d)):
			DirAccess.remove_absolute(TEST_DIR.path_join(d).path_join(f))
		DirAccess.remove_absolute(TEST_DIR.path_join(d))
	DirAccess.remove_absolute(TEST_DIR)
