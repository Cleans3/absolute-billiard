extends SceneTree

## Headless FX probe (docs/plan/03; contract §6): catalog, stat resolution order and floors, stacking,
## exclusive groups, timers/expiry, drink caps + reward caps, the sim sink, the Event vote, the world
## interaction guard and the economy hook.
##   godot --path . --headless -s tests/effects/effects_probe.gd
## Prints EFFECTS OK, or the failing checks and EFFECTS FAIL (exit 1).

const NIGHT_2 := preload("res://src/resources/nights/night_2.tres")

var fails := 0
var finished := false
var _keep: Array[Node] = []


## Stands in for SYNC's PhysicsSim additions (not merged into this tree yet): same names, records calls.
class FakeSim:
	extends Node
	var stat_source := Callable()
	var stats := {}
	var rails := {}
	var tilt_dir := Vector2.ZERO

	func set_stat(stat: StringName, value: float) -> void:
		stats[stat] = value

	func set_rail_restitution_mult(rail_id: StringName, mult: float) -> void:
		rails[rail_id] = mult

	func set_tilt_direction(dir: Vector2) -> void:
		tilt_dir = dir


## Stands in for RoundDirector: signals + SYNC's `current_shooter_id`.
class FakeDirector:
	extends Node
	signal ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)
	signal shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)
	var current_shooter_id := 1

	func end_shot(points: int, foul := false) -> void:
		shot_ended.emit("s", current_shooter_id, points, [] as Array[StringName], foul)


func _init() -> void:
	create_timer(30.0).timeout.connect(func() -> void:
		if not finished:
			print("EFFECTS FAIL (script error or hang)")
			quit(1))
	_run()


func _run() -> void:
	await process_frame  # autoloads exist from here on
	_catalog()
	_resolution()
	_stacking_and_expiry()
	await _drinks()
	await _sim_sink()
	await _opportunities()
	_vote()
	await _world()
	await _economy_hook()
	_overlay()
	for n in _keep:
		if is_instance_valid(n):
			n.free()
	finished = true
	if fails == 0:
		print("EFFECTS OK")
	else:
		print("EFFECTS FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _add(n: Node) -> Node:
	root.add_child(n)
	_keep.append(n)
	return n


class Rig:
	var fx: EffectManager
	var sim: FakeSim
	var director: FakeDirector
	var loop: GameLoop


func _rig() -> Rig:
	var r := Rig.new()
	r.sim = _add(FakeSim.new())
	r.director = _add(FakeDirector.new())
	r.loop = _add(GameLoop.new())
	r.loop.set_process(false)  # phase is set by hand; no Round clock
	r.fx = EffectManager.new()
	r.fx.sim = r.sim
	r.fx.round_director = r.director
	r.fx.game_loop = r.loop
	_add(r.fx)
	r.fx.rng.seed = 7
	return r


func _mod(stat: StringName, op: StatMod.Op, v: float) -> StatMod:
	var m := StatMod.new()
	m.stat = stat
	m.op = op
	m.value = v
	return m


func _fx(id: StringName, target: Effect.Target, mods: Array[StatMod], dur := -1.0, group := &"") -> Effect:
	var e := Effect.new()
	e.id = id
	e.target = target
	e.stat_modifiers = mods
	e.duration_sec = dur
	e.exclusive_group = group
	return e


func _catalog() -> void:
	_check(FxCatalog.DRINKS.size() == 26, "26 drinks")
	_check(FxCatalog.EVENTS.size() == 8, "8 events")
	_check(FxCatalog.INTERACTIONS.size() == 9, "9 world interactions")
	for id in [&"beer", &"whiskey_shot", &"energy_drink", &"tequila_line", &"ice_water", &"house_special",
			&"flaming_shot", &"neighbours_round", &"bar_nuts", &"static_shot", &"moonshine"]:
		_check(FxCatalog.drink(id) != null, "drink %s present" % id)
	for id in [&"tilted_table", &"glass_cushions", &"bouncer", &"crowd_roar", &"moving_pockets",
			&"ball_swap_chaos", &"lights_out", &"pocket_jackpot"]:
		_check(FxCatalog.event(id) != null, "event %s present" % id)
	for id in [&"bump_table", &"throw_drink", &"move_camera", &"kick_stool", &"jukebox", &"flick_lights",
			&"lean_on_rail", &"heckle", &"chalk_the_cue"]:
		_check(FxCatalog.interaction(id) != null, "interaction %s present" % id)
	# 03 §3.5–3.7 spot values
	_check(is_equal_approx(FxCatalog.drink(&"moonshine").reward_mult, 1.6), "moonshine 1.6")
	_check(FxCatalog.drink(&"moonshine").night_limit == 1, "moonshine 1 per Night")
	_check(is_equal_approx(FxCatalog.event(&"lights_out").reward_mult, 1.8), "lights_out 1.8")
	_check(FxCatalog.event(&"lights_out").round_time_add_sec == 20.0, "lights_out +20 s")
	_check(FxCatalog.event(&"crowd_roar").round_time_add_sec == -15.0, "crowd_roar -15 s")
	_check(FxCatalog.interaction(&"heckle").payoffs.size() == 2, "heckle pays hype and viewers")
	# every modifier in every catalogued Effect names a real stat
	for d in FxCatalog.DRINKS:
		for e in d.effects:
			for m in e.stat_modifiers:
				_check(Stats.ALL.has(m.stat), "%s stat known" % e.id)
	# Mystery tier (06 P17): every drink shows at least one buff and one debuff, and the stumble stat is real
	_check(Stats.ALL.has(&"player_stumble_per_min") and Stats.BASE[&"player_stumble_per_min"] == 0.0, "stumble stat in Stats")
	for d in FxCatalog.drinks_of(DrinkTier.Tier.MYSTERY):
		_check(StatText.count(d, StatText.Kind.BUFF) >= 1 and StatText.count(d, StatText.Kind.DEBUFF) >= 1, "%s: buff and debuff" % d.id)
	# every hostile interaction is exclusive_group-tagged (03 §3.7)
	for w in FxCatalog.INTERACTIONS:
		if w.hostile:
			_check(w.effect.exclusive_group != &"", "%s exclusive_group" % w.id)


func _resolution() -> void:
	var r := _rig()
	var fx := r.fx
	# base 10, ADD 2, MUL 3 = 36 whichever lands first
	var order_a := [_mod(&"cue_power_mult", StatMod.Op.MUL, 3.0), _mod(&"cue_power_mult", StatMod.Op.ADD, 2.0)]
	fx.apply_local(_fx(&"t_mul", Effect.Target.CUE, [order_a[0]]), 1, 1, EffectManager.ROUND)
	fx.apply_local(_fx(&"t_add", Effect.Target.CUE, [order_a[1]]), 1, 1, EffectManager.ROUND)
	_check(is_equal_approx(fx.get_stat(&"cue_power_mult", 1, 10.0), 36.0), "base→ADD→MUL = 36")
	_check(is_equal_approx(fx.get_stat(&"cue_power_mult", 2, 10.0), 10.0), "other peer unaffected")
	# untouched stat returns base, floors only after a modifier touched it
	_check(fx.get_stat(&"shot_clock_sec", 1, 0.0) == 0.0, "untouched shot clock = base")
	fx.apply_local(_fx(&"t_wob", Effect.Target.CUE, [_mod(&"cue_aim_wobble_deg", StatMod.Op.ADD, -0.5),
			_mod(&"cue_aim_wobble_deg", StatMod.Op.ADD, -0.5)]), 1, 1, EffectManager.ROUND)
	_check(fx.get_stat(&"cue_aim_wobble_deg", 1, 0.2) == 0.0, "wobble floors at 0")
	fx.apply_local(_fx(&"t_clock", Effect.Target.CUE, [_mod(&"shot_clock_sec", StatMod.Op.ADD, -100.0)]), 1, 1, EffectManager.ROUND)
	_check(fx.get_stat(&"shot_clock_sec", 1, 30.0) == 4.0, "shot clock floors at 4.0")
	# crew-wide (target_id 0) counts for a player unless excluded
	fx.apply_local(_fx(&"t_crew", Effect.Target.VIEW, [_mod(&"player_view_light_level", StatMod.Op.MUL, 0.25)]), 0, 0, EffectManager.ROUND)
	_check(is_equal_approx(fx.get_stat(&"player_view_light_level", 1, 1.0), 0.25), "crew-wide view effect")
	_check(fx.get_stat(&"player_view_light_level", 1, 1.0, false) == 1.0, "include_crew=false skips it")


func _stacking_and_expiry() -> void:
	var r := _rig()
	var fx := r.fx
	var expired: Array[StringName] = []
	fx.effect_expired.connect(func(id: StringName, _t: int, _o: int) -> void: expired.append(id))
	# REFRESH restarts the timer, nothing accumulates
	var refresh := _fx(&"s_refresh", Effect.Target.CUE, [_mod(&"cue_power_mult", StatMod.Op.MUL, 2.0)], 1.0)
	var le := fx.apply_local(refresh, 1, 1, 1000)
	fx._process(0.6)
	fx.apply_local(refresh, 1, 1, 1000)
	_check(is_equal_approx(le.remaining, 1.0), "REFRESH restarts timer")
	_check(fx.live_count() == 1 and is_equal_approx(fx.get_stat(&"cue_power_mult", 1, 1.0), 2.0), "REFRESH does not stack")
	# IGNORE no-ops while live
	var ignore := _fx(&"s_ignore", Effect.Target.CUE, [_mod(&"cue_power_mult", StatMod.Op.MUL, 3.0)], 1.0)
	ignore.stacking_rule = Effect.Stacking.IGNORE
	le = fx.apply_local(ignore, 1, 1, 1000)
	fx._process(0.4)
	fx.apply_local(ignore, 1, 1, 1000)
	_check(is_equal_approx(le.remaining, 0.6), "IGNORE leaves timer alone")
	# timed expiry (sec durations)
	fx._process(0.7)
	_check(expired.has(&"s_ignore") and expired.has(&"s_refresh") and fx.live_count() == 0, "timers expire")
	# exclusive_group: a new one replaces the old, per subject
	fx.apply_local(_fx(&"g_a", Effect.Target.CUE, [_mod(&"shot_clock_sec", StatMod.Op.ADD, 8.0)], -2.0, &"heckle"), 2, 1, EffectManager.SHOT)
	fx.apply_local(_fx(&"g_b", Effect.Target.CUE, [_mod(&"shot_clock_sec", StatMod.Op.ADD, 8.0)], -2.0, &"heckle"), 3, 1, EffectManager.SHOT)
	_check(not fx.is_live(&"g_a", 1) and fx.is_live(&"g_b", 1), "exclusive_group replaces")
	_check(fx.get_stat(&"shot_clock_sec", 1, 0.0) == 8.0, "two heckles never stack")
	# -2 dies with the Shot, -1 with the Round
	fx.apply_local(_fx(&"r_round", Effect.Target.TABLE, [_mod(&"cloth_friction_mult", StatMod.Op.MUL, 2.0)], -1.0), 0, 0, EffectManager.ROUND)
	r.director.end_shot(1)
	_check(not fx.is_live(&"g_b", 1) and fx.is_live(&"r_round", 0), "-2 expires on shot_ended, -1 stays")
	r.loop.round_ended.emit(&"timer", 0)
	_check(fx.live_count() == 0, "-1 expires on round_ended")
	# visual hooks: <= 2 live, <= 1 fullscreen (03 §3.8)
	var hooks := [[&"h1", &"flames"], [&"h2", &"blackout"], [&"h3", &"shake"], [&"h4", &"smoke"]]
	for h in hooks:
		var e := _fx(h[0], Effect.Target.PLAYER, [], -1.0)
		e.visual_hook = h[1]
		fx.apply_local(e, 1, 1, EffectManager.ROUND)
		var live := fx.live_hooks()
		_check(live.size() <= EffectManager.MAX_HOOKS, "hooks <= 2 after %s" % h[1])
		_check(live.filter(func(t: StringName) -> bool: return Stats.FULLSCREEN_HOOKS.has(t)).size() <= 1, "<= 1 fullscreen after %s" % h[1])


func _drinks() -> void:
	var r := _rig()
	var fx := r.fx
	# beer × whiskey = 1.05 × 1.20; a 4th drink is refused with its reason
	_check(fx.serve_drink(&"beer", 1) == &"" and fx.serve_drink(&"whiskey_shot", 1) == &"", "serve beer + whiskey")
	_check(is_equal_approx(fx.get_reward_multiplier(), 1.05 * 1.20), "Drink_Mult product")
	_check(is_equal_approx(fx.get_stat(&"cue_power_mult", 1, 1.0), 1.10), "beer power")
	_check(fx.get_stat(&"cue_spin_radius_mult", 1, 1.0) == 0.0, "beer: no english")
	_check(fx.get_stat(&"rule_call_pocket", 1, 0.0) == 1.0, "whiskey: call pocket")
	_check(fx.serve_drink(&"energy_drink", 1) == &"", "3rd drink ok")
	var refused: Array = []
	fx.drink_refused.connect(func(id: StringName, peer: int, why: StringName) -> void: refused.append([id, peer, why]))
	_check(fx.serve_drink(&"bar_nuts", 1) == &"drink_cap", "4th drink refused: drink_cap")
	_check(refused.size() == 1 and refused[0][2] == &"drink_cap", "refusal names its reason")
	_check(fx.serve_drink(&"beer", 1) == &"", "repeat of a live drink refreshes, needs no slot")
	_check(is_equal_approx(fx.get_reward_multiplier(), 1.05 * 1.20), "repeat does not double the mult")
	_check(fx.serve_drink(&"bar_nuts", 2) == &"", "caps are per player")
	_check(is_equal_approx(fx.round_time_add(), 20.0), "energy_drink +20 s to the Round")
	# ice_water clears the booze group and takes its reward_mult with it
	fx.serve_drink(&"ice_water", 1)  # peer 1 is at the cap, but ice_water needs a slot only while it lives
	r.loop.round_ended.emit(&"timer", 0)
	_check(fx.get_reward_multiplier() == 1.0 and fx.live_count() == 0, "round end drops every drink")
	fx.serve_drink(&"beer", 1)
	fx.serve_drink(&"whiskey_shot", 1)
	_check(fx.serve_drink(&"ice_water", 1) == &"", "ice_water served")
	_check(fx.get_reward_multiplier() == 1.0 and fx.get_stat(&"rule_call_pocket", 1, 0.0) == 0.0, "ice_water clears booze + its mult")
	# caps 2.0 / 3.0 / 6.0
	r.loop.round_ended.emit(&"timer", 0)
	fx.serve_drink(&"moonshine", 1)
	fx.serve_drink(&"house_special", 1)
	fx.serve_drink(&"tequila_line", 1)
	_check(is_equal_approx(fx.get_reward_multiplier(), 2.0), "Drink_Mult capped 2.0")
	for i in 2:
		var ev := Event.new()
		ev.id = StringName("cap_%d" % i)
		ev.reward_mult = 2.0
		fx.begin_event(ev)
	_check(is_equal_approx(fx.get_reward_multiplier(), 6.0), "Drink 2.0 × Event 3.0 = 6.0")
	r.loop.round_ended.emit(&"timer", 0)
	_check(fx.get_reward_multiplier() == 1.0, "Events end with the Round")
	# moonshine: 1 per Night
	fx.serve_drink(&"moonshine", 1)
	r.loop.round_ended.emit(&"timer", 0)
	_check(fx.serve_drink(&"moonshine", 1) == &"night_limit", "moonshine 1 per Night")
	r.loop.night_started.emit(2, 900)
	_check(fx.serve_drink(&"moonshine", 1) == &"", "moonshine again next Night")
	r.loop.round_ended.emit(&"timer", 0)
	# neighbours_round buffs the seat-left player (seat order 1 → 2 → 3)
	fx.seat_order_source = func() -> PackedInt32Array: return PackedInt32Array([1, 2, 3])
	fx.serve_drink(&"neighbours_round", 3)  # seat-left of the last seat wraps to the first
	_check(is_equal_approx(fx.get_reward_multiplier(), 1.25), "neighbours_round: left player gets 1.25")
	_check(is_equal_approx(fx.get_stat(&"stream_hype_gain_mult", 3, 1.0), 1.2), "neighbours_round: hype ×1.2 for the drinker")
	_check(fx._drink_count(1) == 0, "the gift takes no drink slot")
	r.loop.round_ended.emit(&"timer", 0)
	# a Mystery drink is served as itself: its buff and its stumble debuff both land on the drinker
	_check(fx.serve_drink(&"static_shot", 1) == &"" and fx._drink_count(1) == 1, "static_shot served")
	_check(is_equal_approx(fx.get_stat(&"cue_power_mult", 1, 1.0), 1.1), "static_shot buff: cue power x1.1")
	_check(is_equal_approx(fx.get_stat(&"player_stumble_per_min", 1, 0.0), 2.0), "static_shot debuff: 2 stumbles a minute")
	_check(fx.get_stat(&"player_stumble_per_min", 2, 0.0) == 0.0, "the stumble lands on the drinker only")
	await process_frame


func _sim_sink() -> void:
	var r := _rig()
	var fx := r.fx
	await process_frame
	_check(r.sim.stat_source.is_valid(), "stat_source installed")
	r.sim.stat_source = Callable()  # reinstalled on ready only; re-read what the manager exposes
	fx.serve_drink(&"house_special", 1)
	_check(is_equal_approx(float(r.sim.stats.get(&"cue_ball_mass_mult", 1.0)), 1.6), "cue_ball_mass_mult pushed for the shooter")
	_check(is_equal_approx(fx.get_stat(&"cue_power_mult", 1, 1.0), 1.15), "cue_power_mult resolvable at strike")
	# a different shooter resolves without the drinker's mass, once the Shot has ended
	r.director.current_shooter_id = 2
	r.director.end_shot(0)
	await process_frame
	_check(is_equal_approx(float(r.sim.stats.get(&"cue_ball_mass_mult", 1.0)), 1.0), "mass follows the shooter")
	r.director.current_shooter_id = 1
	r.director.end_shot(0)
	await process_frame
	_check(is_equal_approx(float(r.sim.stats.get(&"cue_ball_mass_mult", 1.0)), 1.6), "mass returns for the drinker")
	# per-rail dead cushion, expires with the Shot
	fx.apply(&"lean_on_rail_dead", 2, 3)
	_check(is_equal_approx(float(r.sim.rails.get(&"rail_n_w", 1.0)), 0.85), "rail_n_w restitution pushed")
	_check(fx.get_stat(&"cushion_restitution_mult", 1, 1.0) == 1.0, "rail effect never leaks into the global stat")
	r.director.end_shot(0)
	await process_frame
	_check(is_equal_approx(float(r.sim.rails.get(&"rail_n_w", 0.0)), 1.0), "rail restored after the Shot")
	# the real PhysicsSim (SYNC's sink): stat_source, set_stat, rail and tilt calls all land
	var real := _rig()
	real.sim.free()
	var sim := PhysicsSim.new()
	real.fx.sim = sim
	_add(sim)
	real.fx.sim.set(&"stat_source", real.fx.get_stat)
	real.fx.serve_drink(&"house_special", 1)
	_check(is_equal_approx(sim.cue_ball_mass_mult, 1.6), "real PhysicsSim: mass pushed")
	_check(is_equal_approx(sim.stat(&"cue_power_mult", 1, 1.0), 1.15), "real PhysicsSim: stat_source resolves cue_power_mult")
	real.fx.apply(&"lean_on_rail_dead", 2, 6)
	_check(is_equal_approx(sim.rail_restitution_mult(&"rail_s_e"), 0.85), "real PhysicsSim: rail mult")
	real.fx.set_tilt_direction(Vector2(0, -2))
	_check(sim.tilt_direction.is_equal_approx(Vector2(0, -1)), "real PhysicsSim: tilt direction")


func _opportunities() -> void:
	var r := _rig()
	var fx := r.fx
	var roar := FxCatalog.event(&"crowd_roar")
	var ball := Ball.new()
	_keep.append(ball)
	fx.begin_event(roar)
	_check(fx.get_reward_multiplier() == 1.0, "opportunity Events carry reward_mult 1.0")
	_check(fx.pot_bonus() == 1.0, "no pot yet, no bonus")
	r.director.ball_potted.emit(ball, "s", &"corner_nw")
	_check(is_equal_approx(fx.pot_bonus(), 2.0), "crowd_roar: next pot ×2")
	r.director.end_shot(1)
	await process_frame
	_check(fx.pot_bonus() == 1.0, "crowd_roar spent after the first paying shot")
	r.director.ball_potted.emit(ball, "s2", &"side_n")
	_check(fx.pot_bonus() == 1.0, "and stays spent")
	r.director.end_shot(1)
	await process_frame
	r.loop.round_ended.emit(&"timer", 0)
	fx.begin_event(FxCatalog.event(&"pocket_jackpot"), &"side_s")
	r.director.ball_potted.emit(ball, "s3", &"side_n")
	_check(fx.pot_bonus() == 1.0, "jackpot: other pockets pay normal")
	r.director.ball_potted.emit(ball, "s3", &"side_s")
	_check(is_equal_approx(fx.pot_bonus(), 3.0), "jackpot pocket pays ×3")
	r.director.end_shot(2)
	await process_frame
	_check(is_equal_approx(fx.pot_bonus(), 1.0), "shot pots cleared after the Shot")


func _vote() -> void:
	var r := _rig()
	var sch := EventScheduler.new()
	sch.effects = r.fx
	sch.game_loop = r.loop
	sch.pocket_ids = [&"side_n", &"side_s"] as Array[StringName]
	_add(sch)
	var offers: Array = []
	sch.event_offer_ready.connect(func(ri: int, tier: int, ids: Array[StringName]) -> void: offers.append([ri, tier, ids]))
	# Night 1, tier 1: bouncer needs Night 2, so exactly the three others
	var ids := sch.offer(2, 1, 1)
	_check(ids.size() == 3 and not ids.has(&"bouncer"), "3 eligible tier-1 Events on Night 1")
	_check(offers.size() == 1 and offers[0][2] == ids, "event_offer_ready fired with the offer")
	for id in ids:
		_check(FxCatalog.event(id).min_night <= 1 and FxCatalog.event(id).tier == 1, "%s eligible" % id)
	# solo: the first pick is final; begin_round applies it and returns its time delta
	sch.submit_event_vote.rpc_id(1, ids[1])
	var applied: Array[StringName] = []
	sch.event_applied.connect(func(id: StringName, _t: int, _m: float) -> void: applied.append(id))
	r.loop.night_index = 0
	var bonus := sch.begin_round(2)
	_check(applied == [ids[1]], "the voted Event applies at Round start")
	_check(is_equal_approx(bonus, FxCatalog.event(ids[1]).round_time_add_sec), "begin_round returns round_time_add_sec")
	_check(r.fx.get_reward_multiplier() >= 1.0 and is_equal_approx(r.fx.get_reward_multiplier(), FxCatalog.event(ids[1]).reward_mult), "Event_Mult feeds get_reward_multiplier")
	# not offered again this Night
	r.loop.round_ended.emit(&"timer", 0)
	var again := sch.offer(3, 1, 1)
	_check(not again.has(ids[1]), "used Event is not re-offered this Night")
	# scripted_first: bouncer is forced on Night 2, once
	r.loop.night_started.emit(2, 900)
	var forced := sch.offer(2, 1, 2)
	_check(forced == [&"bouncer"], "scripted_first forced, not offered")
	sch.begin_round(2)
	_check(r.fx.is_live(&"bouncer_clock", 0), "bouncer applied")
	r.director.end_shot(1)
	_check(not r.fx.is_live(&"bouncer_clock", 0), "bouncer is one Turn per Round (-2)")
	r.loop.round_ended.emit(&"timer", 0)
	_check(sch.offer(2, 1, 2).size() == 3, "next time it is a normal choice")
	# vote tally: majority wins; a tie goes to the host's pick; no votes go to the host / first card
	sch._votes = {1: &"a", 2: &"b", 3: &"b"}
	sch._offer = [&"a", &"b", &"c"] as Array[StringName]
	sch._chosen = null
	sch._resolve()
	_check(sch._chosen == null, "tally over unknown ids resolves without crashing")
	var trio := sch.offer(2, 1, 1)
	sch._votes = {1: trio[0], 2: trio[1], 3: trio[1]}
	sch._resolve()
	_check(sch._chosen.id == trio[1], "majority wins")
	trio = sch.offer(2, 1, 1)
	sch._votes = {1: trio[2], 2: trio[1]}
	sch._resolve()
	_check(sch._chosen.id == trio[2], "tie → host's pick")
	trio = sch.offer(2, 1, 1)
	sch._resolve()
	_check(sch._chosen.id == trio[0], "no votes → first card")
	# 20 s timeout resolves the open vote by itself
	trio = sch.offer(2, 1, 1)
	sch._process(EventScheduler.VOTE_TIMEOUT_SEC + 0.1)
	_check(sch._offer.is_empty() and sch._chosen != null and sch._chosen.id == trio[0], "20 s timeout → host pick")
	# begin_round settles a vote still open when the host advances
	trio = sch.offer(2, 1, 1)
	sch.begin_round(2)
	_check(sch._offer.is_empty(), "begin_round settles an open vote")
	r.loop.round_ended.emit(&"timer", 0)
	# tier 2: Night 1's Round 3 offers the one Event that is open to it (Pocket Jackpot), every other waits for Night 2+
	var tier2 := sch.offer(3, 2, 1)
	_check(tier2.size() == 1 and tier2[0] == &"pocket_jackpot", "Night 1's tier-2 pool is the Pocket Jackpot")
	sch.apply_event(&"pocket_jackpot", 3, &"side_s")
	_check(sch.active_pocket == &"side_s", "a jackpot Round remembers its pocket (every peer's FX marks it)")
	r.loop.round_ended.emit(&"timer", 0)
	_check(sch.active_pocket == &"", "... and forgets it when the Round ends")


func _world() -> void:
	var r := _rig()
	var stream := StreamManager.new()
	stream.viewers = 500
	stream.hype = 0.5
	var economy := EconomyManager.new()
	economy.stream = stream
	economy.cash = 100
	economy.set_stock(1, [&"beer", &"bar_nuts", &"house_special"] as Array[StringName], [3, 3, 1] as Array[int])
	_add(stream)
	_add(economy)
	var table := Node3D.new()
	table.position = Vector3(0, 0, -3.5)
	_add(table)
	var bar := Bar.new()
	_add(bar)
	var wi := WorldInteractions.new()
	wi.effects = r.fx
	wi.stream = stream
	wi.economy = economy
	wi.game_loop = r.loop
	wi.round_director = r.director
	wi.table = table
	_add(wi)
	r.director.current_shooter_id = 2  # the local peer (1) is a non-shooter
	r.loop.phase = GameLoop.Phase.ROUND_LIVE
	var now := [0]
	wi.clock = func() -> int: return now[0]
	var at := [Vector3.ZERO]
	wi.player_position_source = func(_peer: int) -> Vector3: return at[0]
	var applied: Array[StringName] = []
	var rejected: Array[StringName] = []
	wi.interaction_applied.connect(func(_p: int, k: StringName, _t: int, _pl: Dictionary) -> void: applied.append(k))
	wi.interaction_rejected.connect(func(_k: StringName, why: StringName) -> void: rejected.append(why))

	# bump_table: cost first (hype 0.10), tilt pushes toward the table, payoff pending on the pot
	at[0] = Vector3(0.0, 0.0, -1.2)
	wi.request(&"bump_table", 0, {})
	_check(applied == [&"bump_table"], "bump_table applied")
	_check(is_equal_approx(stream.hype, 0.4), "hostile interaction spent hype first")
	_check(r.fx.is_live(&"bump_table_tilt", 0), "tilt Effect live")
	_check(r.sim.tilt_dir.is_equal_approx(Vector2(0, -1)), "tilt direction points at the table centre")
	_check(is_equal_approx(float(r.sim.stats.get(&"table_tilt_deg", 0.0)), 1.5), "tilt pushed to the sim")
	# cooldown per interactor
	wi.request(&"bump_table", 0, {})
	_check(rejected.back() == &"cooldown", "cooldown per interactor")
	_check(is_equal_approx(stream.hype, 0.4), "a rejection costs nothing")
	# the pot pays viewers +80
	var v0 := stream.viewers
	r.director.end_shot(1)
	_check(stream.viewers == v0 + 80, "bump payoff on shot_potted")
	_check(not r.fx.is_live(&"bump_table_tilt", 0), "tilt dies with the shot")
	# 2 hostile per Turn across the crew, the 3rd is refused; a Turn ending refills it
	now[0] = 100000
	at[0] = Vector3(-5.0, 0.0, 3.5)
	wi.request(&"heckle", 0, {})
	at[0] = Vector3(0.0, 0.0, -1.2)
	wi.request(&"bump_table", 0, {})
	var before := stream.viewers
	at[0] = Vector3(-6.3, 0.0, 5.8)
	wi.request(&"flick_lights", 0, {})
	_check(rejected.back() == &"hostile_cap" and stream.viewers == before, "3rd hostile per Turn refused, uncharged")
	at[0] = Vector3(6.3, 0.0, 5.8)
	wi.request(&"jukebox", 0, {})
	_check(applied.back() == &"jukebox", "non-hostile still works at the cap")
	_check(economy.cash == 60, "jukebox spent $40")
	wi.request(&"jukebox", 0, {})
	_check(rejected.back() == &"once_per_round", "jukebox once per Round")
	r.director.end_shot(0)
	at[0] = Vector3(-6.3, 0.0, 5.8)
	wi.request(&"flick_lights", 0, {})
	_check(applied.back() == &"flick_lights", "hostile budget refills next Turn")
	# reach, live-shot, shooter, toggles
	at[0] = Vector3(20.0, 0.0, 20.0)
	now[0] = 900000
	wi.request(&"chalk_the_cue", 0, {})
	_check(rejected.back() == &"too_far", "reach 2.0 m")
	at[0] = Vector3(0.0, 0.0, 0.0)
	r.loop.phase = GameLoop.Phase.INTERMISSION
	wi.request(&"kick_stool", 0, {})
	_check(rejected.back() == &"not_live", "hostile needs a live Round")
	r.loop.phase = GameLoop.Phase.ROUND_LIVE
	at[0] = Vector3(0.0, 0.0, 0.0)
	wi.hostile_policy = WorldInteractions.HostilePolicy.OFF
	wi.request(&"kick_stool", 0, {})
	_check(rejected.back() == &"hostile_off", "hostile toggle off")
	wi.request(&"jukebox", 0, {})  # not hostile: unaffected (rejected for reach here, not the toggle)
	_check(rejected.back() != &"hostile_off", "toggle leaves non-hostile alone")
	wi.hostile_policy = WorldInteractions.HostilePolicy.FRIENDS_ONLY
	wi.friends = PackedInt32Array([7])
	wi.request(&"kick_stool", 0, {})
	_check(applied.back() == &"kick_stool", "friends_only: the host may")
	wi.hostile_policy = WorldInteractions.HostilePolicy.ON
	r.director.current_shooter_id = 1
	now[0] += 1000000
	r.director.end_shot(0)
	wi.request(&"kick_stool", 0, {})
	_check(rejected.back() == &"shooter_cant_grief", "the shooter cannot grief themselves")
	r.director.current_shooter_id = 2
	# cost gating: no cash, no chalk
	economy.cash = 5
	at[0] = Vector3(2.4, 0.0, -1.2)
	wi.request(&"chalk_the_cue", 0, {})
	_check(rejected.back() == &"cant_afford" and economy.cash == 5, "cash cost refuses when short")
	# throw_drink: price = the drink's, view shake lands on the shooter only
	economy.cash = 100
	at[0] = Vector3(4.2, 0.0, 2.5)
	now[0] += 1000000
	r.director.end_shot(0)
	wi.request(&"throw_drink", 0, {&"drink_id": &"beer"})
	_check(applied.back() == &"throw_drink" and economy.cash == 50, "throw_drink costs the drink")
	_check(economy.stock_left(0) == 2, "a thrown drink leaves the Bartender's shelf")
	now[0] += 1000000
	r.director.end_shot(0)
	economy.set_stock(1, [&"beer"] as Array[StringName], [0] as Array[int])
	wi.request(&"throw_drink", 0, {&"drink_id": &"beer"})
	_check(rejected.back() == &"sold_out" and economy.cash == 50, "a sold-out drink cannot be thrown")
	economy.set_stock(1, [&"beer", &"bar_nuts", &"house_special"] as Array[StringName], [3, 3, 1] as Array[int])
	# bar_buy / bar_serve: validated, signalled, nothing charged
	var purchases: Array = []
	wi.bar_purchase_requested.connect(func(k: StringName, b: int, d: StringName, t: int) -> void: purchases.append([k, b, d, t]))
	wi.request(&"bar_buy", 0, {&"drink_id": &"beer"})
	_check(purchases == [[&"bar_buy", 1, &"beer", 1]] and economy.cash == 50, "bar_buy signals, charges nothing")
	wi.request(&"bar_serve", 0, {&"drink_id": &"bar_nuts", &"target_peer": 2})
	_check(purchases.back() == [&"bar_serve", 1, &"bar_nuts", 2], "bar_serve names the target")
	wi.request(&"bar_buy", 0, {&"drink_id": &"house_special"})
	_check(rejected.back() == &"intermission_only", "non-mid_round drinks are Intermission-only")
	wi.request(&"bar_buy", 0, {})
	_check(rejected.back() == &"bad_payload", "bar_buy needs a drink")
	wi.request(&"no_such_thing", 0, {})
	_check(rejected.back() == &"unknown_kind", "unknown kind rejected")
	# heckle pays on a miss only
	now[0] += 1000000
	at[0] = Vector3(-5.0, 0.0, 3.5)
	stream.hype = 0.5
	var vv := stream.viewers
	wi.request(&"heckle", 0, {})
	r.director.end_shot(0)
	_check(is_equal_approx(stream.hype, 0.5 - 0.08 + 0.20) and stream.viewers == vv + 40, "heckle pays hype + viewers on shot_missed")
	# props exist for the catalogue
	for id in [&"bump_table", &"kick_stool", &"jukebox", &"flick_lights", &"heckle", &"chalk_the_cue", &"throw_drink", &"bar_buy", &"bar_serve"]:
		_check(wi._prop_for(id, 0) != null, "prop for %s" % id)
	for rail in 6:
		_check(wi._prop_for(&"lean_on_rail", rail + 1) != null, "rail prop %d" % (rail + 1))
	await process_frame


func _economy_hook() -> void:
	var rig := _add(Node.new())
	var stream := StreamManager.new()
	var economy := EconomyManager.new()
	economy.name = "EconomyManager"
	economy.stream = stream
	var r := _rig()
	r.fx.get_parent().remove_child(r.fx)
	r.fx.name = "EffectManager"
	rig.add_child(stream)
	rig.add_child(economy)
	rig.add_child(r.fx)
	stream.viewers = 0
	var base := economy.award_shot_reward(10, [] as Array[StringName], &"")
	r.fx.serve_drink(&"moonshine", 1)  # ×1.6
	var boosted := economy.award_shot_reward(10, [] as Array[StringName], &"")
	_check(base == 3 and boosted == roundi(10 * 1.6 * 0.3), "award_shot_reward reads get_reward_multiplier()")
	var lone := EconomyManager.new()
	_add(lone)
	_check(lone.award_shot_reward(10, [] as Array[StringName], &"") == 3, "no EffectManager sibling → ×1.0")
	_check(economy.try_spend_cash(economy.cash + 1, &"x") == false and economy.try_spend_cash(1, &"x"), "try_spend_cash")


func _overlay() -> void:
	var r := _rig()
	var view: ViewOverlay = load("res://src/ui/ViewOverlay.tscn").instantiate()
	view.effects = r.fx
	_add(view)
	_check(not view.visible, "overlay hidden while nothing is active")
	r.fx.apply_local(FxCatalog.effect(&"flick_lights_dark"), 2, 1, EffectManager.SHOT)
	_check(view.visible and is_equal_approx(float((view.material as ShaderMaterial).get_shader_parameter(&"light_level")), 0.4), "flick_lights darkens my screen")
	r.fx.apply_local(FxCatalog.effect(&"flick_lights_dark"), 2, 2, EffectManager.SHOT)  # someone else's view: never kept here
	_check(r.fx.live_count() == 1, "VIEW effect on another peer is not applied locally")
	r.director.end_shot(0)
	_check(not view.visible, "overlay hides when the Shot ends")
	# lights_out is crew-wide: only the current shooter's screen goes dark
	r.director.current_shooter_id = 1
	r.fx.apply_local(FxCatalog.effect(&"lights_out_dark"), 0, 0, EffectManager.ROUND)
	_check(view.visible and is_equal_approx(float((view.material as ShaderMaterial).get_shader_parameter(&"fog_density")), 0.3), "lights_out on the shooter's screen")
	r.director.current_shooter_id = 2
	view._on_change()
	_check(not view.visible, "lights_out leaves a non-shooter's screen alone")
