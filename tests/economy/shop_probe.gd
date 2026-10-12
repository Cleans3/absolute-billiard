extends SceneTree
## Headless Bartender probe (docs/plan/02 §3.6, 06 P16/P17): tiers and the random Drinks shelf (seeded, no duplicates,
## weights, sold out, mid-Round gating, checkpoint restore), the fixed Upgrades rows (gating, folded upgrades,
## persistence), the scratch fine and negative Cash.
##   godot --path . --headless -s tests/economy/shop_probe.gd
## Boots the real MainLevel through Lobby → Solo. Prints SHOP OK, or the failing checks and SHOP FAIL (exit 1).

const ROWS := {
	&"polish_the_set": [&"ball", 250], &"tier2_rack": [&"ball", 400], &"tier3_rack": [&"ball", 900],
	&"bomb_ball": [&"ball", 300], &"split_ball": [&"ball", 450], &"joker_ball": [&"ball", 600],
	&"heavy_shaft": [&"cue", 300], &"chalk_tin": [&"cue", 350], &"jump_cue": [&"cue", 500], &"custom_tip": [&"cue", 250],
	&"lens_t2": [&"camera", 400], &"lens_t3": [&"camera", 800], &"spare_tripod": [&"camera", 500],
	&"magnetic_pockets": [&"table", 600], &"stream_overlay": [&"table", 500], &"fresh_cloth": [&"table", 350],
}
const TIER_HEX := ["B8BEC6", "4CC46A", "3D8BFF", "A64DFF", "FFB020", "FF2A3C"]  # polish contract §3
var TEST_DIR := "user://test_shop_%d" % OS.get_process_id()  # per process: probes run concurrently across worktrees and share user://

var fails := 0
var finished := false
var eco: EconomyManager
var loop: GameLoop
var fx: EffectManager
var stream: StreamManager


func _init() -> void:
	create_timer(90.0).timeout.connect(func() -> void:
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
	_tiers()
	_stock_rolls()
	_fine_math()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	SaveManager.root = TEST_DIR
	SaveManager.save_persistent([] as Array[StringName])
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, true)  # keep_pour: the first check is the pour itself
	var level := current_scene
	eco = level.get_node("EconomyManager")
	loop = level.get_node("GameLoop")
	fx = level.get_node("EffectManager")
	var poured := fx.live_drinks()
	_check(poured.size() == 1 and EconomyManager.POUR_DRINKS.has(poured[0].drink.id) and eco.cash == 0, "the first Intermission of a Night pours one house drink, free (%s)" % [poured.map(func(d: Dictionary) -> StringName: return d.drink.id)])
	fx._on_round_ended(&"timer", 0)  # the house pour takes a Drink slot; these checks want all three free
	stream = level.get_node("StreamManager")
	_check(loop.phase == GameLoop.Phase.INTERMISSION, "starts in Intermission")
	_shelf()
	_gating()
	_upgrades()
	await _round_effects()
	_bar_and_drinks()
	await _resume_restores_shelf()
	await _scratch_fine()
	_persistence()
	_cleanup()
	finished = true
	print("SHOP OK" if fails == 0 else "SHOP FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


# --- catalog and tiers --------------------------------------------------------------------------

func _catalog() -> void:
	_check(ShopCatalog.all().size() == ROWS.size() + FxCatalog.DRINKS.size(), "16 rows + %d drinks" % FxCatalog.DRINKS.size())
	for id: StringName in ROWS:
		var it := ShopCatalog.item(id)
		_check(it != null and it.category == ROWS[id][0] and it.cost_cash == ROWS[id][1], "row %s category/cost" % id)
		_check(not it.display_name.is_empty() and not it.description.is_empty(), "row %s has a name and a description" % id)
	_check(ShopCatalog.item(&"beer").cost_cash == 50 and ShopCatalog.item(&"beer").category == &"drink", "drinks come from the 03 catalog")
	_check(ShopCatalog.item(&"bomb_ball").min_night == 2 and ShopCatalog.item(&"split_ball").min_night == 3
		and ShopCatalog.item(&"joker_ball").min_night == 4, "gimmick balls gate on min_night 2/3/4")
	_check(ShopCatalog.item(&"lens_t2").persistent and not ShopCatalog.item(&"heavy_shaft").persistent, "persistent flags")
	for d in FxCatalog.DRINKS:
		_check(not d.display_name.is_empty() and not d.description.is_empty() and d.cost_cash > 0, "drink %s has name, description, price" % d.id)
		_check(ShopCatalog.item(d.id).display_name == d.display_name, "drink %s name reaches its ShopItem" % d.id)
	_check(FxCatalog.drink(&"mystery_shot") == null, "the roll-on-use mystery_shot is retired (Mystery is a tier now)")


func _tiers() -> void:
	var total := 0.0
	for t in DrinkTier.NAMES.size():
		total += DrinkTier.WEIGHTS[t]
		_check(DrinkTier.colour(t) == Color(TIER_HEX[t]), "tier %s colour is the contract's" % DrinkTier.label(t))
		_check(FxCatalog.drinks_of(t).size() >= (4 if t == DrinkTier.Tier.MYSTERY else 3), "tier %s has enough drinks" % DrinkTier.label(t))
	_check(is_equal_approx(total, 100.0), "tier weights sum to 100")
	_check(DrinkTier.WEIGHTS == ([50.0, 26.0, 13.0, 6.0, 2.0, 3.0] as Array[float]) and DrinkTier.STOCK == ([3, 2, 1, 1, 1, 1] as Array[int]), "P17 weights and units per offer")
	for stat in Stats.ALL:
		_check(StatText.INFO.has(stat), "StatText knows %s" % stat)
	for d in FxCatalog.drinks_of(DrinkTier.Tier.MYSTERY):
		_check(StatText.count(d, StatText.Kind.BUFF) >= 1 and StatText.count(d, StatText.Kind.DEBUFF) >= 1, "mystery %s shows a buff and a debuff" % d.id)
		var stat_debuff := false
		for e in d.effects:
			for m in e.stat_modifiers:
				stat_debuff = stat_debuff or StatText.line(m).kind == StatText.Kind.DEBUFF
		_check(stat_debuff, "mystery %s: the debuff is a real Effect, not just a price" % d.id)
	var stumbles := FxCatalog.drinks_of(DrinkTier.Tier.MYSTERY).filter(func(d: Drink) -> bool:
		return d.effects.any(func(e: Effect) -> bool: return e.stat_modifiers.any(func(m: StatMod) -> bool: return m.stat == &"player_stumble_per_min")))
	_check(not stumbles.is_empty(), "a Mystery debuff uses player_stumble_per_min")
	var line := StatText.line(_mod(&"cue_power_mult", StatMod.Op.MUL, 1.1))
	_check(line.text == "Cue power +10%" and line.kind == StatText.Kind.BUFF, "formatter: +10%% cue power is a buff (%s)" % line.text)
	line = StatText.line(_mod(&"shot_clock_sec", StatMod.Op.ADD, 8.0))
	_check(line.text == "Shot clock: 8 s" and line.kind == StatText.Kind.DEBUFF, "formatter: a shot clock is a debuff (%s)" % line.text)
	line = StatText.line(_mod(&"cue_spin_radius_mult", StatMod.Op.MUL, 0.0))
	_check(line.text == "English: none" and line.kind == StatText.Kind.DEBUFF, "formatter: no english (%s)" % line.text)
	line = StatText.line(_mod(&"player_stumble_per_min", StatMod.Op.ADD, 2.0))
	_check(line.text == "Stumbles +2/min" and line.kind == StatText.Kind.DEBUFF, "formatter: stumbles (%s)" % line.text)


func _mod(stat: StringName, op: StatMod.Op, value: float) -> StatMod:
	var m := StatMod.new()
	m.stat = stat
	m.op = op
	m.value = value
	return m


func _stock_rolls() -> void:
	_check(DrinkStock.roll(4242) == DrinkStock.roll(4242), "the same key rolls the same shelf")
	var differs := 0
	for k in 50:
		differs += int(DrinkStock.roll(k) != DrinkStock.roll(k + 1))
	_check(differs >= 45, "different keys roll different shelves (%d / 50)" % differs)
	var counts := PackedInt32Array([0, 0, 0, 0, 0, 0])
	var rolls := 2400  # 12,000 offers
	for k in rolls:
		var ids := DrinkStock.roll(hash([777, k]))
		_check(ids.size() == DrinkStock.SIZE, "a shelf holds %d offers" % DrinkStock.SIZE)
		var seen := {}
		for id in ids:
			_check(not seen.has(id), "no drink twice in one stock (%s)" % id)
			seen[id] = true
			counts[FxCatalog.drink(id).tier] += 1
	for t in DrinkTier.NAMES.size():
		var pct := 100.0 * counts[t] / float(rolls * DrinkStock.SIZE)
		_check(absf(pct - DrinkTier.WEIGHTS[t]) <= 2.0, "%s drawn %.1f%%, weight %.0f%% (±2)" % [DrinkTier.label(t), pct, DrinkTier.WEIGHTS[t]])


func _fine_math() -> void:
	for pair: Array in [[600, 60], [900, 90], [1350, 135], [2000, 200], [3000, 300], [100, 25], [130, 25], [520, 50], [1000, 100]]:
		_check(EconomyManager.fine_for(pair[0]) == pair[1], "fine for Quota %d is $%d (got %d)" % [pair[0], pair[1], EconomyManager.fine_for(pair[0])])


# --- the live shelf -----------------------------------------------------------------------------

func _shelf() -> void:
	_check(eco.stock_size() == DrinkStock.SIZE and eco.stock_key == loop.stock_key(), "an Intermission rolled the shelf for its key")
	var want := DrinkStock.roll(loop.stock_key())
	for i in eco.stock_size():
		_check(eco.stock_id(i) == want[i], "shelf slot %d is the seeded roll" % i)
		_check(eco.stock_left(i) == DrinkTier.STOCK[FxCatalog.drink(want[i]).tier], "slot %d holds its tier's units" % i)
	eco.roll_stock(loop.stock_key())
	_check(eco.stock_size() == DrinkStock.SIZE, "the same key keeps the shelf")


func _gating() -> void:
	eco.set_stock(1, [&"beer", &"house_special", &"static_shot"] as Array[StringName], [3, 1, 1] as Array[int])
	_check(eco.can_buy(&"polish_the_set") == &"cant_afford", "no Cash → cant_afford")
	_check(eco.can_buy(&"bar_nuts") == &"not_stocked", "a drink off the shelf is not stocked")
	_check(eco.can_buy(&"beer") == &"cant_afford", "stocked but broke → cant_afford")
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
	# the shelf: units run out, the offer stays visible
	var cash := eco.cash
	_check(eco.try_purchase(&"house_special", 1) and eco.cash == cash - 200 and eco.stock_left(1) == 0, "the last unit sells")
	_check(eco.stock_size() == 3 and eco.stock_id(1) == &"house_special", "a sold-out offer stays on the shelf")
	_check(not eco.try_purchase(&"house_special", 1) and eco.last_refusal == &"sold_out" and eco.cash == cash - 200, "sold out refuses and costs nothing")
	_check(eco.try_purchase(&"beer", 1) and eco.stock_left(0) == 2, "a Common offer has 3 units")
	_check(not eco.try_purchase(&"bar_nuts", 1) and eco.last_refusal == &"not_stocked", "an off-shelf drink is refused")
	# a refusal from the drink rules (night_limit etc.) must not burn a unit: moonshine is 1 per Night per drinker
	eco.set_stock(1, [&"moonshine"] as Array[StringName], [3] as Array[int])
	_check(eco.try_purchase(&"moonshine", 1) and eco.stock_left(0) == 2, "moonshine sells")
	_check(not eco.try_purchase(&"moonshine", 1) and eco.last_refusal == &"night_limit" and eco.stock_left(0) == 2, "night_limit refuses without taking a unit")
	eco.set_stock(1, [&"beer", &"house_special", &"static_shot"] as Array[StringName], [3, 1, 1] as Array[int])


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
	eco.owned[&"bomb_ball"] = 1  # bought on a later Night; the BallType shipped with REQ#rules-1
	pool = eco.unlocked_ball_types(base)
	_check(pool.has(&"gold_prize") and pool.has(&"bomb_ball"), "tier3_rack adds gold; a bought gimmick with a BallType resource joins the pool")
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
	eco.set_stock(1, [&"beer", &"house_special", &"static_shot"] as Array[StringName], [3, 1, 1] as Array[int])
	_check(eco.can_buy(&"house_special") == &"intermission_only", "an Intermission-only drink is refused mid-Round (stock or not)")
	_check(eco.can_buy(&"beer") == &"", "a mid_round drink is sold during a Round")
	_check(eco.try_purchase(&"beer", 1), "beer (mid_round) is sold during a Round")
	loop.call(&"_end_round", &"timer")
	await _frames(3)
	_check(not fx.is_live(&"shop_magnetic_pockets"), "Round effects expire with the Round")
	_check(eco.stock_key == loop.stock_key() and eco.stock_size() == DrinkStock.SIZE, "the Round-end Intermission rolled a new shelf")
	loop.advance()
	await _frames(10)
	_check(fx.is_live(&"shop_magnetic_pockets"), "re-applied next Round")
	_check(is_equal_approx(stream.base_viewers_bonus, 150), "bonus survives the Round")
	loop.call(&"_end_round", &"timer")
	await _frames(3)


func _bar_and_drinks() -> void:
	var world: WorldInteractions = current_scene.get_node("WorldInteractions")
	eco.set_stock(1, [&"ice_water", &"moonshine"] as Array[StringName], [3, 1] as Array[int])
	var before := eco.cash
	world.bar_purchase_requested.emit(&"bar_buy", 1, &"ice_water", 1)
	_check(eco.cash == before - ShopCatalog.item(&"ice_water").cost_cash and eco.stock_left(0) == 2, "bar_buy routes through try_purchase and takes a unit")
	var rejected: Array[StringName] = []
	eco.purchase_rejected.connect(func(_id: StringName, r: StringName) -> void: rejected.append(r))
	eco.set_stock(1, [&"ice_water"] as Array[StringName], [0] as Array[int])
	world.bar_purchase_requested.emit(&"bar_buy", 1, &"ice_water", 1)
	_check(rejected == [&"sold_out"], "a sold-out bar_buy is rejected to the buyer: %s" % [rejected])
	eco.set_stock(1, [&"ice_water", &"moonshine"] as Array[StringName], [3, 1] as Array[int])
	eco.cash = 0
	_check(not eco.try_purchase(&"moonshine", 1) and eco.last_refusal == &"cant_afford", "broke: drink refused")


# --- checkpoint ---------------------------------------------------------------------------------

func _resume_restores_shelf() -> void:
	eco.set_stock(loop.stock_key(), [&"beer", &"moonshine", &"quantum_ale", &"soda_pop", &"vodka_tonic"] as Array[StringName], [2, 0, 1, 3, 1] as Array[int])
	var profile := SaveManager.decode(SaveManager.encode(loop.build_profile()))
	_check(profile.stock_key == loop.stock_key() and profile.stock_ids.size() == 5 and profile.stock_left == ([2, 0, 1, 3, 1] as Array[int]), "the checkpoint carries the shelf")
	eco.set_stock(-5, [&"bar_nuts"] as Array[StringName], [1] as Array[int])  # a different shelf is live; resume must put the saved one back
	eco.restore(profile)
	_check(eco.stock_key == profile.stock_key and eco.stock_size() == 5 and eco.stock_id(1) == &"moonshine" and eco.stock_left(1) == 0 and eco.stock_left(3) == 3, "restore() puts the shelf back, sold-out counts included")
	loop.intermission_started.emit()  # resume_from ends with this signal: it must not reroll a restored shelf
	_check(eco.stock_id(0) == &"beer" and eco.stock_left(1) == 0, "an Intermission with the same key keeps the restored shelf")
	var bad := SaveProfile.new()
	bad.stock_key = 9
	bad.stock_ids = [&"mystery_shot"] as Array[StringName]
	bad.stock_left = [1] as Array[int]
	eco.restore(bad)
	_check(eco.stock_size() == 0 and eco.stock_key == -1, "a shelf naming a drink the catalog no longer has is dropped, so the Intermission rerolls")
	# deterministic resume: the same campaign seed, Night and Round give the same shelf with no save at all
	var key := loop.stock_key()
	eco.roll_stock(key)
	var first: Array[StringName] = []
	for i in eco.stock_size():
		first.append(eco.stock_id(i))
	eco.stock_key = -1
	eco.roll_stock(key)
	var second: Array[StringName] = []
	for i in eco.stock_size():
		second.append(eco.stock_id(i))
	_check(first == second and first == DrinkStock.roll(key), "resume reproduces the shelf from seed + Night + Round")
	await process_frame


# --- scratch fine (P16) -------------------------------------------------------------------------

func _scratch_fine() -> void:
	var rd: Node = current_scene.get_node("RoundDirector")
	var fines: Array = []
	eco.fined.connect(func(reason: StringName, amount: int) -> void: fines.append([reason, amount]))
	loop.phase = GameLoop.Phase.ROUND_LIVE
	eco.cash = 500
	rd.cue_respawned.emit(&"scratch")
	_check(loop.current_night().quota == 600 and eco.cash == 440 and fines == [[&"scratch", 60]], "Night 1 scratch: Quota 600 → $60 fine (cash %d, %s)" % [eco.cash, fines])
	rd.cue_respawned.emit(&"off_table")
	_check(eco.cash == 380 and fines.size() == 2, "off the table costs the same fine")
	rd.cue_respawned.emit(&"wedged")
	_check(eco.cash == 380 and fines.size() == 2, "a wedged cue ball is freed for nothing")
	eco.cash = 20
	rd.cue_respawned.emit(&"scratch")
	_check(eco.cash == -40, "the fine may push Cash negative (%d)" % eco.cash)
	_check(eco.can_buy(&"ice_water") == &"cant_afford" or eco.can_buy(&"ice_water") == &"not_stocked", "in debt nothing is affordable")
	_check(not eco.try_spend_cash(1, &"test") and eco.try_spend_cash(0, &"test") and eco.cash == -40, "in debt: a positive spend is refused, a free action is not")
	var results: Array = []
	eco.quota_evaluated.connect(func(paid: int, demand: int, over: bool) -> void: results.append([paid, demand, over]))
	_check(not eco.evaluate_quota(loop.current_night()) and results == [[0, 600, true]], "a negative purse fails the Night's Quota")
	loop.phase = GameLoop.Phase.INTERMISSION
	eco.cash = 500
	rd.cue_respawned.emit(&"scratch")
	_check(eco.cash == 500, "no fine outside a live Round")
	eco.cash = 0


func _persistence() -> void:
	var saved := SaveManager.load_persistent()
	_check(saved.has(&"tier2_rack") and saved.has(&"lens_t3") and not saved.has(&"heavy_shaft"), "persistent file: %s" % [saved])
	eco.wipe()
	_check(eco.cash == 0 and eco.count_of(&"tier2_rack") == 1 and eco.count_of(&"heavy_shaft") == 0, "wipe keeps persistent items only")
	_check(eco.stock_size() == 0 and eco.stock_key == -1, "wipe empties the shelf (the next Intermission rolls)")
	_check(not eco.build_cue_spec().jump_unlocked, "cue mods reset with the wipe")


func _cleanup() -> void:
	for f in DirAccess.get_files_at(TEST_DIR):
		DirAccess.remove_absolute(TEST_DIR.path_join(f))
	for d in DirAccess.get_directories_at(TEST_DIR):
		for f in DirAccess.get_files_at(TEST_DIR.path_join(d)):
			DirAccess.remove_absolute(TEST_DIR.path_join(d).path_join(f))
		DirAccess.remove_absolute(TEST_DIR.path_join(d))
	DirAccess.remove_absolute(TEST_DIR)
