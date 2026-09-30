extends SceneTree

## Rules-and-gimmicks probe (REQ#rules-1): the ball types, authored racks, the drop pool, scoring
## (overrides, high_value, joker), bomb scatter, split spawn, call-pocket, shot clock, pocket radius +
## oscillation, and the shuffle consumer. Solo host; a fake EffectManager/EventScheduler feed the stats.
##   godot --path . --headless -s tests/round/rules_probe.gd      prints RULES OK

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")
const NIGHT_5 := preload("res://src/resources/nights/night_5.tres")
const SEED := 424242

var table: Table
var director: RoundDirector
var fx: FakeFx
var sched: FakeScheduler
var _failures := 0
var _checks := 0
var _ended: Array[Dictionary] = []


class FakeFx extends Node:
	signal effect_applied(id: StringName, target: int, owner: int, duration: float)
	signal effect_expired(id: StringName, target: int, owner: int)
	var stats := {}

	func get_stat(stat: StringName, _peer: int, base: float, _crew := true) -> float:
		return stats.get(stat, base)


class FakeScheduler extends Node:
	signal ball_shuffle_requested(count: int)


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	fx = FakeFx.new()
	fx.name = "EffectManager"
	root.add_child(fx)
	sched = FakeScheduler.new()
	sched.name = "EventScheduler"
	root.add_child(sched)
	director = RoundDirector.new()
	director.table = table
	root.add_child(director)
	director.shot_ended.connect(func(id: String, _s: int, pts: int, _t: Array[StringName], foul: bool) -> void:
		_ended.append({id = id, points = pts, foul = foul}))
	_run()


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", msg)


func _type(id: String) -> BallType:
	return RackDropper.ball_type(StringName(id))


func _run() -> void:
	await physics_frame
	_data()
	_authored()
	_pool()
	_scoring()
	_calls_and_clock()
	_pockets()
	await _bomb()
	_split()
	_shuffle()
	if _failures > 0:
		printerr("RULES FAILED: %d" % _failures)
		quit(1)
		return
	print("rules: %d checks" % _checks)
	print("RULES OK")
	quit()


## 1. the four new BallTypes exist with the 01 table's numbers.
func _data() -> void:
	var stone := _type("stone_ball")
	_check(stone.base_value == 0 and stone.mass_multiplier == 3.0 and not stone.counts_for_clear and stone.behaviour_tags.has(&"obstacle"), "stone_ball row")
	for id in ["bomb_ball", "split_ball", "joker_ball"]:
		var t := _type(id)
		_check(t.base_value == 250 and t.behaviour_tags.has(&"gimmick"), "%s row" % id)
	_check(_type("bomb_ball").behaviour_tags.has(&"volatile") and _type("split_ball").behaviour_tags.has(&"splitter") and _type("joker_ball").behaviour_tags.has(&"wild"), "gimmick tags")
	_check(_type("gold_prize").behaviour_tags.has(&"high_value"), "gold_prize high_value")
	var b: Ball = BALL.instantiate()
	b.ball_type = stone
	b.spec = table.spec
	root.add_child(b)
	_check(is_equal_approx(b.mass, Ball.REGULATION_MASS_KG * 3.0 * pow(b.radius / TableSpec.REG_BALL_RADIUS, 3.0)), "stone is 3x mass")
	b.queue_free()
	for t in RoundDirector.BALL_TYPES:
		_check(t != null, "wire list entry")


## 2. Night 1 / Night 5 racks are data: exact positions, legal spacing, fallback past the authored rounds.
func _authored() -> void:
	var half := RackDropper.interior(table.spec).size * 0.5
	var keep := RackDropper.keepouts(table.spec, table.layout)
	var head := Vector2(table.layout.spots.head.x, table.layout.spots.head.z)
	for cfg in [NIGHT_1, NIGHT_5]:
		_check(cfg.authored_racks.size() == cfg.rounds_count, "night %d has a rack per round" % cfg.night_number)
		for round_index in range(1, cfg.rounds_count + 1):
			var rack: RackLayout = cfg.authored_racks[round_index - 1]
			var entries := RackDropper.drop(table.spec, table.layout, cfg, 1, round_index)
			_check(entries.size() == rack.type_ids.size() and entries.size() == cfg.object_ball_count, "authored rack size n%d r%d" % [cfg.night_number, round_index])
			var again := RackDropper.drop(table.spec, table.layout, cfg, 999, round_index)
			for i in entries.size():
				var want := Vector2(rack.positions[i].x * half.x, rack.positions[i].y * half.y)
				_check(entries[i].pos.is_equal_approx(want) and entries[i].pos == again[i].pos, "authored position exact (seed-independent)")
				_check(entries[i].type.id == String(rack.type_ids[i]), "authored type")
				_check(entries[i].pos.distance_to(head) > 3.0 * table.spec.ball_radius_m, "authored ball off the cue's head spot")
				for k in keep:
					_check(entries[i].pos.distance_to(Vector2(k.x, k.y)) > k.z, "authored ball clear of pocket mouths")
				for j in i:
					_check(entries[i].pos.distance_to(entries[j].pos) >= 2.0 * table.spec.ball_radius_m, "authored balls do not overlap")
	var seeded := RackDropper.drop(table.spec, table.layout, NIGHT_1, 7, NIGHT_1.rounds_count + 1)
	_check(seeded.size() == NIGHT_1.object_ball_count, "past the authored rounds the seeded drop takes over")
	_check(RackDropper.drop(table.spec, table.layout, NIGHT_1, 7).size() == NIGHT_1.object_ball_count, "round_index 0 = seeded")


## 3. drop pool: gimmicks once each, stone counted in the ≤12 cap.
func _pool() -> void:
	var cfg := NightConfig.new()
	cfg.object_ball_count = 12
	cfg.unlocked_ball_types = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty", &"bomb_ball", &"split_ball", &"joker_ball", &"stone_ball"]
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	_check(RackDropper.rack_size(cfg) == RackDropper.MAX_OBJECT_BALLS, "rack capped at 12 with a stone")
	var types := RackDropper.compose(cfg, RackDropper.rack_size(cfg), rng)
	var counts := {}
	for t in types:
		counts[t.id] = int(counts.get(t.id, 0)) + 1
	_check(types.size() == 12, "12 balls")
	_check(counts.get("stone_ball", 0) == RackDropper.STONES_PER_RACK, "one stone")
	for id in ["bomb_ball", "split_ball", "joker_ball"]:
		_check(counts.get(id, 0) == 1, "%s appears once" % id)
	cfg.object_ball_count = 8
	_check(RackDropper.rack_size(cfg) == 9, "stone adds to the count below the cap")
	var full := RackDropper.drop(table.spec, table.layout, cfg, SEED)
	_check(full.size() == 9, "seeded drop places every ball incl. the stone")


## 4. scoring: overrides, high_value +25 %, joker x2 on the best ball, penalties in the sum.
func _scoring() -> void:
	var red := _ball("red_basic")
	var gold := _ball("gold_prize")
	var black := _ball("black_penalty")
	var joker := _ball("joker_ball")
	_check(director.raw_points_for([red] as Array[Ball]) == 100, "red = 100")
	_check(director.raw_points_for([gold] as Array[Ball]) == 625, "gold = 500 + 25 %")
	_check(director.raw_points_for([black, red] as Array[Ball]) == -150, "penalty rides the sum")
	_check(director.raw_points_for([gold, joker] as Array[Ball]) == 625 + 250 + 625, "joker doubles the best (gold) once")
	_check(director.raw_points_for([red, joker] as Array[Ball]) == 100 + 250 + 250, "joker doubles the best of red/joker")
	director.ball_overrides = [BallTypeOverride.make(&"red_basic", 150)] as Array[BallTypeOverride]
	_check(director.raw_points_for([red] as Array[Ball]) == 150, "shop override replaces base_value")
	_check(_type("red_basic").base_value == 100, "the resource is never mutated")
	director.ball_overrides = [] as Array[BallTypeOverride]
	for b in [red, gold, black, joker]:
		b.queue_free()


func _ball(id: String) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = _type(id)
	b.spec = table.spec
	root.add_child(b)
	return b


## 5 + 6. rule_call_pocket (validator + scoring) and the shot clock whiff foul.
func _calls_and_clock() -> void:
	director.start_round(NIGHT_1, 1, SEED)
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 0.5
	_check(director._validate_shot(1, intent) == &"", "no rule: a shot with no call is fine")
	fx.stats[&"rule_call_pocket"] = 1.0
	_check(director._validate_shot(1, intent) == &"call_pocket", "rule on: the shot must name a pocket")
	intent.called_pocket = &"nowhere"
	_check(director._validate_shot(1, intent) == &"call_pocket", "an unknown pocket is no call")
	intent.called_pocket = &"corner_nw"
	_check(director._validate_shot(1, intent) == &"", "a named pocket passes")
	# scoring: pot elsewhere = 0, no foul
	var red := _ball("red_basic")
	red.pocketed_in = &"corner_ne"
	director._call_rule = true
	director._called_pocket = &"corner_nw"
	director._potted = [red] as Array[Ball]
	_check(director.raw_points_for(director._scoring_pots()) == 0, "pot in another pocket scores 0")
	red.pocketed_in = &"corner_nw"
	_check(director.raw_points_for(director._scoring_pots()) == 100, "pot in the called pocket scores")
	director._call_rule = false
	director._potted = [] as Array[Ball]
	red.queue_free()
	fx.stats.erase(&"rule_call_pocket")
	# the wire carries the call
	var sim := table.sim
	intent.called_pocket = &"side_s"
	var ids := sim._pocket_ids()
	_check(ids.has(&"side_s") and ids.find(&"side_s") + 1 < 255, "pocket index fits the wire byte")
	# shot clock
	fx.stats[&"shot_clock_sec"] = 6.0
	director._begin_turn()
	_check(is_equal_approx(director.shot_clock_left, 6.0), "clock armed from shot_clock_sec")
	_ended.clear()
	director._process(3.0)
	_check(_ended.is_empty() and director.shot_clock_left > 2.9, "still ticking")
	director._process(3.5)
	_check(_ended.size() == 1 and _ended[0].foul and _ended[0].points == 0, "clock at 0 = whiff foul, 0 points")
	fx.stats.erase(&"shot_clock_sec")
	director._begin_turn()
	_check(director.shot_clock_left == 0.0, "no clock without the stat")


## 7. pocket radius / oscillation: geometry rebuilt from the stat, offsets a pure function of the seed.
func _pockets() -> void:
	var base_w: float = table.layout.pockets[0].mouth_width_m
	table.apply_pocket_stats(1.5, 0.0, SEED)
	_check(is_equal_approx(table.layout.pockets[0].mouth_width_m, base_w * 1.5), "pocket_radius_mult widens the mouth")
	_check(is_equal_approx(table.get_pocket(&"corner_nw").mouth_width_m, base_w * 1.5), "PocketSpec follows")
	table.apply_pocket_stats(1.0, 0.0, SEED)
	_check(is_equal_approx(table.layout.pockets[0].mouth_width_m, base_w), "back to stock")
	# fx-driven refresh
	fx.stats[&"pocket_radius_mult"] = 1.1
	fx.stats[&"pocket_oscillation_m"] = 0.05
	director._refresh_pocket_stats()
	_check(is_equal_approx(table.pocket_radius_mult, 1.1) and is_equal_approx(table.pocket_osc_m, 0.05), "RoundDirector pushes the stats to the Table")
	fx.stats.erase(&"pocket_radius_mult")
	fx.stats.erase(&"pocket_oscillation_m")
	director._refresh_pocket_stats()
	_check(is_equal_approx(table.pocket_radius_mult, 1.0) and table.pocket_osc_m == 0.0, "expiry restores the pockets")
	# determinism: the same seed + time gives the same chute offsets on every run; another seed shifts them
	var run_a := _chutes(SEED)
	table.apply_pocket_stats(1.0, 0.0, SEED)
	var run_b := _chutes(SEED)
	var run_c := _chutes(SEED + 1)
	_check(run_a == run_b and not run_a.is_empty(), "same seed + time = same chute offsets across runs")
	_check(run_a != run_c, "another seed = other phases")
	var moved := false
	for a in table.get_children():
		if a is Area3D and a.has_meta(&"pocket_id"):
			moved = moved or not a.position.is_equal_approx(a.get_meta(&"base_position"))
	_check(moved, "chutes actually slide")
	_check(is_equal_approx(Table.pocket_offset(SEED, &"side_n", 1.7, 0.06), Table.pocket_offset(SEED, &"side_n", 1.7, 0.06)), "pure function")
	_check(not is_equal_approx(Table.pocket_offset(SEED, &"side_n", 1.7, 0.06), Table.pocket_offset(SEED + 1, &"side_n", 1.7, 0.06)) \
		or not is_equal_approx(Table.pocket_offset(SEED, &"side_s", 1.7, 0.06), Table.pocket_offset(SEED + 1, &"side_s", 1.7, 0.06)), "another seed shifts the phase")
	_check(absf(Table.pocket_offset(SEED, &"corner_ne", 3.3, 0.06)) <= 0.06, "amplitude bounds it")
	table.apply_pocket_stats(1.0, 0.0, SEED)


## Chute positions after 1.7 s of oscillation under `seed`, as one comparable array.
func _chutes(seed: int) -> Array[Vector3]:
	table.apply_pocket_stats(1.0, 0.06, seed)
	table.set_pocket_time(1.7)
	var out: Array[Vector3] = []
	for a in table.get_children():
		if a is Area3D and a.has_meta(&"pocket_id"):
			out.append(a.position)
	return out


## Helper: an empty Round with only the cue ball, then the given object balls at rest.
func _setup(types: Array, positions: Array) -> Array[Ball]:
	director.start_round(NIGHT_1, 1, SEED)
	director._clear_balls()
	var head: Vector3 = table.layout.spots.head
	director._cue_ball = director._spawn(RoundDirector.CUE_TYPE, Vector2(head.x, head.z), 0)
	var out: Array[Ball] = []
	for i in types.size():
		out.append(director._spawn(_type(types[i]), positions[i], i + 1))
	director._next_net_id = types.size() + 1
	director._round_active = true
	return out


func _settle() -> void:
	for i in 240:
		await physics_frame
		var still := true
		for b in director.get_balls():
			still = still and b.is_resting
		if still and i > 10:
			return


func _fire(aim: Vector2, power: float) -> void:
	var intent := ShotIntent.new()
	intent.aim_dir = aim
	intent.power = power
	table.sim.request_shot(intent)
	for i in 1200:
		await physics_frame
		if not director.shot_in_progress and i > 5:
			return


## 8. bomb: a hard strike scatters neighbours and removes only the bomb; a soft one does nothing.
func _bomb() -> void:
	var objs := _setup(["bomb_ball", "red_basic", "red_basic"], [Vector2(-0.3, 0.0), Vector2(-0.3, 0.55), Vector2(0.3, -0.5)])
	await _settle()
	var neighbour_before := objs[1].global_position
	var far_before := objs[2].global_position
	director.shot_in_progress = false
	await _fire(Vector2.RIGHT, 0.12)  # soft: well under 3 m/s at the bomb
	_check(not objs[0].retired, "a soft tap leaves the bomb alone")
	objs = _setup(["bomb_ball", "red_basic", "red_basic"], [Vector2(-0.3, 0.0), Vector2(-0.3, 0.55), Vector2(1.3, -0.9)])
	await _settle()
	neighbour_before = objs[1].global_position
	far_before = objs[2].global_position
	var bomb := objs[0]
	await _fire(Vector2.RIGHT, 1.0)
	_check(bomb.retired and not bomb.is_pocketed, "the bomb removes itself, unpotted")
	_check(objs[1].global_position.distance_to(neighbour_before) > 0.05, "a neighbour inside the radius was scattered")
	_check(objs[2].global_position.distance_to(far_before) < 0.01, "a ball outside the radius stayed put")
	_check(director.raw_points_for([] as Array[Ball]) == 0, "no score for a detonation")


## 9. split: one red_basic per potted split_ball at its rest spot.
func _split() -> void:
	var objs := _setup(["split_ball", "red_basic"], [Vector2(-0.4, 0.3), Vector2(0.6, -0.3)])
	var split := objs[0]
	var spot := director._local(split)
	director._rest_pos[split] = spot
	split.is_pocketed = true
	split.retire()
	director._potted = [split] as Array[Ball]
	var before := director.get_balls().size()
	director._spawn_splits()
	_check(director.get_balls().size() == before + 1, "one ball spawned per split pot")
	var born := director.get_balls()[director.get_balls().size() - 1]
	_check(born.ball_type.id == "red_basic" and director._local(born).distance_to(spot) < 4.0 * table.spec.ball_radius_m, "a red_basic at the split's rest spot")
	_check(born.net_id == director._next_net_id - 1 and born.net_id > 2, "fresh wire id")
	director._potted = [] as Array[Ball]
	# is_table_cleared ignores a retired bomb, counts a live red
	_check(not director.is_table_cleared(), "a live red keeps the table uncleared")


## 10. shuffle: N balls re-rolled in place (position + wire id kept), seeded, via the EventScheduler signal.
func _shuffle() -> void:
	var cfg := NightConfig.new()
	cfg.unlocked_ball_types = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]
	var run := func() -> Array:
		var objs := _setup(["red_basic", "red_basic", "red_basic", "red_basic", "red_basic"], [Vector2(-0.4, -0.5), Vector2(-0.2, 0.5), Vector2(0.2, -0.4), Vector2(0.5, 0.4), Vector2(0.9, 0.0)])
		director._config = cfg
		var nodes := objs.duplicate()
		var pos_before: Array[Vector2] = []
		for b in objs:
			pos_before.append(director._local(b))
		sched.ball_shuffle_requested.emit(3)
		var replaced := 0
		var types := ""
		for i in objs.size():
			var now: Ball = null
			for b in director.get_balls():
				if b.net_id == i + 1:
					now = b
			_check(now != null and director._local(now).is_equal_approx(pos_before[i]), "shuffle keeps wire id and spot")
			replaced += 1 if now != nodes[i] else 0
			types += now.ball_type.id + ","
		_check(replaced == 3, "exactly 3 balls re-rolled (got %d)" % replaced)
		return [types, replaced]
	var a: Array = run.call()
	var b: Array = run.call()
	_check(a[0] == b[0], "same seed and Round state re-roll to the same types")
	director.shot_in_progress = true
	director._pending_shuffle = 0
	sched.ball_shuffle_requested.emit(2)
	_check(director._pending_shuffle == 2, "a shuffle mid-Shot waits for the Shot to end")
	director.shot_in_progress = false
	director._pending_shuffle = 0
