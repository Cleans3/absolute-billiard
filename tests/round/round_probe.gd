extends SceneTree

## Headless Round probe (C2–C5): seeded rack, one live Shot at a time, foul + kitchen respawn,
## off-table and wedged-cue rules, table_cleared, and each trick on a scripted shot.
##   godot --path . --headless -s tests/round/round_probe.gd
## Shots are tuned to the current table/ball feel; the aim of each has a window of at least ~1°
## (noted inline) — a physics retune may need the constants re-found. Prints ROUND OK.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_CONTROLLER := preload("res://src/gameplay/cue/CueController.tscn")
const CUE_SPEC := preload("res://src/resources/cues/demo_cue.tres")
const SEED := 20260921
const SHOT_TIMEOUT_FRAMES := 4000
const BANK_OBJ := Vector2(-1.2, -0.5)  # into the south side pocket's east jaw, then in — window 55.5°..58° (wide mouths, 06 P30)
const BANK_AIM := 56.5
const RUNNER_OBJ := Vector2(-0.6, 0.6)  # south, foot, north cushion, then the north side pocket
const RUNNER_AIM := 53.3                # ~0.1° window (53.25-53.30 after the adhoc-1012a ball retune): three bounces amplify everything, see _trick_line
const RUNNER_SPAN := 0.5                # ± search around it if float noise shifts the window
const BEHIND := 0.4  # cue ball this far behind the object ball, on the aim line

var table: Table
var director: RoundDirector
var cue_node: Node3D
var cam: Camera3D
var cue_ball: Ball
var objs: Array[Ball] = []  # object balls by spawn_index 1..n (highest value first)
var config := NightConfig.new()
var r: float  # ball radius

# lambdas capture by value — every handler sets a member instead
var _events: Array[String] = []
var _ended: Array[Dictionary] = []
var _tricks: Array[StringName] = []
var _potted: Array[Ball] = []
var _strikes := 0
var _failures := 0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	cue_node = CUE_CONTROLLER.instantiate()
	root.add_child(cue_node)
	cam = Camera3D.new()
	root.add_child(cam)
	cam.current = true
	director = RoundDirector.new()
	director.table = table
	root.add_child(director)
	director.shot_started.connect(_on_started)
	director.ball_potted.connect(_on_potted)
	director.trick_detected.connect(_on_trick)
	director.shot_ended.connect(_on_ended)
	director.table_cleared.connect(_on_cleared)
	director.cue_respawned.connect(_on_respawn)
	_run()


func _run() -> void:
	await physics_frame
	cue_node.shot_sink = table.sim.request_shot
	r = table.spec.ball_radius_m
	print("probe: C2 rack")
	_rack()
	director.start_round(config, 1, SEED)
	cue_ball = director.get_balls()[0]
	for b in director.get_balls():
		if not b.is_cue_ball:
			objs.append(b)
	_check(cue_ball.is_cue_ball and objs.size() == config.object_ball_count)

	print("probe: C3 one shot at a time")
	await _gate()
	await _payout_and_clear()

	print("probe: C4 fouls")
	await _whiff()
	await _scratch()
	await _off_table()
	await _wedged()

	print("probe: C5 tricks")
	# kick: cue rails first, then hits the object — window ~3°..9° around 6°
	await _trick(Vector2(1.6, 0.3), [Vector2(1.9, 0.5)], 6.0, 0.4, [&"KickShot"])
	# carom: cue splits two touching balls without potting — window ±3° around 0°
	await _trick(Vector2(-1.4, 0.0), _pair(-0.2), 0.0, 0.3, [&"Carom"])
	# combo: the same split further up pots both in opposite corners — exactly 0° (symmetric)
	await _trick(Vector2(-1.4, 0.0), _pair(1.0), 0.0, 0.7, [&"Carom", &"Combo"], 2)
	# bank: one cushion, then the pocket
	await _trick_line(BANK_OBJ, BANK_AIM, 0.7, [&"BankShot"], 1)
	# rail-runner: three distinct cushions, then the pocket
	await _trick_line(RUNNER_OBJ, RUNNER_AIM, 0.7, [&"RailRunner", &"BankShot"], 1, RUNNER_SPAN)
	_detector()

	print("ROUND OK" if _failures == 0 else "ROUND FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)


# ---- C2 --------------------------------------------------------------------------------------

func _snapshot() -> Array[String]:
	var out: Array[String] = []
	for b in director.get_balls():
		var p := table.to_local(b.global_position)
		out.append("%s %.4f %.4f" % [b.ball_type.id, p.x, p.z])
	return out


func _rack() -> void:
	director.start_round(config, 1, SEED)
	var a := _snapshot()
	director.start_round(config, 1, SEED)
	_check(a == _snapshot(), "same seed + config must give the identical rack")
	director.start_round(config, 1, SEED + 1)
	_check(a != _snapshot(), "a different seed must give a different rack")
	director.start_round(config, 1, SEED)

	var balls := director.get_balls()
	var head: Vector3 = table.layout.spots.head
	_check(balls.size() == config.object_ball_count + 1)
	_check(absf(table.to_local(balls[0].global_position).x - head.x) < 0.001 and balls[0].is_cue_ball, "cue ball on the head spot")
	var gold := 0
	var black := 0
	for i in balls.size():
		var t := balls[i].ball_type
		gold += 1 if t.behaviour_tags.has(&"high_value") else 0
		black += 1 if t.behaviour_tags.has(&"penalty") else 0
		var p := table.to_local(balls[i].global_position)
		_check(RackDropper.interior(table.spec).has_point(Vector2(p.x, p.z)), "%s inside the cloth" % balls[i].id)
		for j in range(i + 1, balls.size()):
			var q := table.to_local(balls[j].global_position)
			_check(Vector2(p.x, p.z).distance_to(Vector2(q.x, q.z)) >= 2.0 * r, "%s overlaps %s" % [balls[i].id, balls[j].id])
		for k in RackDropper.keepouts(table.spec, table.layout):
			_check(Vector2(p.x, p.z).distance_to(Vector2(k.x, k.y)) >= k.z, "%s in a pocket mouth" % balls[i].id)
	_check(gold >= 1 and black >= 1, "rack has a prize and a penalty ball")
	print("probe: rack ok — %d balls, %d prize, %d penalty, seed reproducible" % [balls.size(), gold, black])


# ---- C3 --------------------------------------------------------------------------------------

## The real CueController path: a strike is vetoed while a shot is live, and exactly one
## shot_started / shot_ended fires per shot.
func _gate() -> void:
	await _place(Vector2(-1.4, 0.0), [Vector2(0.4, 0.0)])
	_check(director.can_strike(cue_ball) and not director.can_strike(objs[0]), "only the cue ball may be struck")
	_check(table.sim.shot_validator.is_valid(), "RoundDirector installs PhysicsSim.shot_validator")
	cue_ball.struck.connect(_on_struck)
	_strikes = 0
	var cue_pos := cue_ball.global_position
	cam.global_position = cue_pos + Vector3(-0.3, 0.0, 0.0)
	cam.look_at(cue_pos, Vector3.UP)
	_reset_records()
	cue_node.begin(cue_ball, -PI / 2.0)  # aim +x, at the object ball
	cue_node.fire(0.3)
	_check(director.shot_in_progress and _strikes == 1, "first strike goes through")
	cue_node.fire(0.3)  # same frame: the host validator must refuse it
	await physics_frame
	cue_node.fire(0.3)
	_check(_strikes == 1, "a strike while the shot is live is ignored (Ball.strike not called)")
	await _wait_shot()
	cue_ball.struck.disconnect(_on_struck)
	_check(_ended.size() == 1 and _events.count("started") == 1, "exactly one shot_started and shot_ended")
	_check(_ended[0].shot_id == "n1-r1-s1" and not director.shot_in_progress)
	_check(director.can_strike(cue_ball), "gate reopens after shot_ended")
	_check(not _ended[0].foul, "the cue ball reached an object ball: legal")


## Pot the top-value ball with every other ball already pocketed: raw_points is its base value,
## ball_potted fired, and table_cleared follows shot_ended.
func _payout_and_clear() -> void:
	var a := Vector2(2.2, 0.9)
	await _place(_behind(a, 46.0, 0.2), [a], true)
	_reset_records()
	await _shoot(46.0, 0.5)
	_check(not _ended[0].foul, "a clean pot is not a foul")
	_check(_potted == [objs[0]] and _ended[0].raw == director.raw_points_for(_potted), "raw_points = value of the potted ball (01 §2 scoring)")
	_check(_events == ["started", "potted", "ended", "cleared"], "order: %s" % [_events])
	director.start_round(config, 1, SEED)  # the rest of this table is marked pocketed — start over
	_refresh()


# ---- C4 --------------------------------------------------------------------------------------

func _whiff() -> void:
	await _place(Vector2(-1.4, 0.0), [])
	_reset_records()
	await _shoot(0.0, 0.3)
	_check(_ended[0].foul and _ended[0].raw == 0 and _ended[0].ids.is_empty(), "no object contact = foul, no points")
	_check(not _events.has("respawn:scratch"), "a whiff does not move the cue ball")


## Follow-through: both the object ball and the cue ball go down. Foul, 0 points, cue back in the
## kitchen clear of every ball, and the respawn is announced before shot_ended.
func _scratch() -> void:
	var a := Vector2(2.2, 0.9)
	await _place(_behind(a, 46.0, 0.2), [a])
	_reset_records()
	await _shoot(46.0, 0.5, Vector2(0.0, 0.9))  # window ~40°..54°
	_check(_ended[0].foul and _ended[0].raw == 0 and _ended[0].ids.is_empty(), "scratch = foul, no points, no tricks")
	_check(_potted == [objs[0]], "the object ball still fell (ball_potted fires at the drop)")
	_check(_events.find("respawn:scratch") != -1 and _events.find("respawn:scratch") < _events.find("ended"), "respawn before shot_ended: %s" % [_events])
	var p := table.to_local(cue_ball.global_position)
	_check(p.x + r < table.spec.kitchen_line_x + 0.0001, "cue ball respawned behind the kitchen line (x=%.3f)" % p.x)
	_check(not cue_ball.is_pocketed and cue_ball.visible)
	for b in objs:
		if not b.is_pocketed and b.visible:
			_check(cue_ball.global_position.distance_to(b.global_position) >= 2.0 * r, "kitchen respawn clear of %s" % b.id)


## A ball flung off the table during a legal shot: foul, and it comes back where it last rested.
func _off_table() -> void:
	var start := Vector2(0.3, 0.0)
	await _place(Vector2(-0.6, 0.0), [start, Vector2(1.0, 0.8)])
	_reset_records()
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 0.15
	cue_ball.strike(intent, CUE_SPEC)
	objs[1].linear_velocity = Vector3(6.0, 6.0, 0.0)  # off over the foot rail
	await _wait_shot()
	_check(_ended[0].foul and _ended[0].raw == 0, "a ball off the table is a foul")
	_check(not objs[1].is_pocketed and objs[1].visible and not objs[1].freeze, "the stray is back in play")
	var back := table.to_local(objs[1].global_position)
	_check(Vector2(back.x, back.z).distance_to(Vector2(1.0, 0.8)) < 0.05, "stray respawned at its last resting spot (%s)" % back)
	_check(not _events.has("respawn:scratch") and not _events.has("respawn:off_table"), "only an object ball left")


## Wedged cue (blocked in 16 directions) is detected, and a shot that ends that way respawns it in
## the kitchen with a `wedged` signal.
func _wedged() -> void:
	await _place(Vector2(-0.5, 0.0), [])
	_check(not director.is_cue_wedged(), "a free cue ball is not wedged")
	var ring: Array = []
	for i in 6:
		ring.append(Vector2(-0.5, 0.0) + Vector2.from_angle(TAU * i / 6.0) * (2.0 * r + 0.001))
	await _place(Vector2(-0.5, 0.0), ring, false, true)  # frozen: the ring stays exactly as placed
	_check(director.is_cue_wedged(), "cue ball ringed by six balls is wedged")
	_reset_records()
	var intent := ShotIntent.new()  # power 0: the shot opens, nothing moves, it resolves at once
	cue_ball.strike(intent, CUE_SPEC)
	await _wait_shot()
	_check(_events.has("respawn:wedged"), "wedged cue respawned: %s" % [_events])
	_check(not director.is_cue_wedged() and table.to_local(cue_ball.global_position).x < table.spec.kitchen_line_x)


# ---- C5 --------------------------------------------------------------------------------------

## One scripted shot, then `_expect`.
func _trick(cue_pos: Vector2, obj_pos: Array, aim_deg: float, power: float, want: Array, pots := 0) -> void:
	await _place(cue_pos, obj_pos)
	_reset_records()
	await _shoot(aim_deg, power)
	_expect(want, pots)


## Object ball struck head-on from BEHIND away. A pot after several cushions has a tiny aim window
## (cross-machine float noise could move it), so a miss retries ±0.1° steps up to `span`.
func _trick_line(obj: Vector2, aim_deg: float, power: float, want: Array, pots: int, span := 0.0) -> void:
	var k := 0
	while true:
		var off := ((k + 1) / 2) * 0.1 * (1.0 if k % 2 == 1 else -1.0)
		if absf(off) > span + 0.0001:
			break
		await _place(_behind(obj, aim_deg + off, BEHIND), [obj])
		_reset_records()
		await _shoot(aim_deg + off, power)
		if not _ended[0].foul and want.all(func(id: StringName) -> bool: return _ended[0].ids.has(id)):
			break
		k += 1
	_expect(want, pots)


## Every id in `want` detected, trick_detected fired for each in the same order, sorted by
## multiplier desc so ids[0] is the payout, and `pots` object balls potted.
func _expect(want: Array, pots: int) -> void:
	var ids: Array[StringName] = _ended[0].ids
	print("probe: trick shot %s pots=%d -> %s" % [want, _potted.size(), ids])
	_check(not _ended[0].foul, "trick shots are legal shots (%s %s)" % [_events, director._log.entries.map(func(e): return "%s:%s>%s" % [e.kind, e.a.id, e.b.id if e.b else e.pocket_id])])
	for id in want:
		_check(ids.has(id), "%s not detected (got %s)" % [id, ids])
	_check(_potted.size() == pots, "expected %d pots, got %d" % [pots, _potted.size()])
	for i in range(1, ids.size()):
		_check(TrickShot.multiplier_for(ids[i - 1]) > TrickShot.multiplier_for(ids[i]), "trick_ids sorted by multiplier desc: %s" % [ids])
	_check(ids == _tricks, "trick_detected emitted once per id, in order: %s vs %s" % [ids, _tricks])
	_check(_ended[0].raw == director.raw_points_for(_potted), "raw_points = scored value of the potted balls")


## TrickDetector on hand-built logs: the cases physics cannot pin down (3+ pots, jaw rattle).
func _detector() -> void:
	var cue := Ball.new()
	cue.is_cue_ball = true
	var a := Ball.new()
	var b := Ball.new()
	var c := Ball.new()
	var log := ContactLog.new()
	log.add_ball(cue, a)
	log.add_rail(a, &"n")
	log.add_rail(a, &"e")
	log.add_rail(a, &"s")
	log.add_pocket(a, &"corner")
	var ids := _detect(log, cue)
	_check(ids == [&"RailRunner", &"BankShot"], "three distinct cushions then a pot: %s" % [ids])

	log.clear()
	log.add_ball(cue, a)
	for _i in 4:
		log.add_rail(a, &"e")  # one jaw rattling is one bounce
	log.add_pocket(a, &"corner")
	ids = _detect(log, cue)
	_check(not ids.has(&"RailRunner") and ids == [&"BankShot"], "jaw rattle is not a rail-runner: %s" % [ids])

	log.clear()
	log.add_ball(cue, a)
	log.add_pocket(a, &"p1")
	log.add_rail(a, &"e")  # after the pot: not a bank
	ids = _detect(log, cue)
	_check(ids.is_empty(), "rails after the pocket do not count: %s" % [ids])

	log.clear()
	for o in [a, b, c]:
		log.add_ball(cue, o)
	for o in [a, b, c]:
		log.add_pocket(o, &"p")
	ids = _detect(log, cue)
	_check(ids == [&"Carom", &"Combo3"], "three pots: Combo3 (not Combo), and the carom: %s" % [ids])

	log.clear()
	log.add_ball(cue, a)
	log.add_rail(cue, &"n")  # rail AFTER the first object hit: no kick
	ids = _detect(log, cue)
	_check(ids.is_empty(), "no kick when the cushion comes after the object ball: %s" % [ids])
	for n in [cue, a, b, c]:
		n.free()


func _detect(log: ContactLog, cue: Ball) -> Array[StringName]:
	var ids: Array[StringName] = []
	for t in TrickDetector.detect(log, cue, "x"):
		ids.append(t.id)
	return ids


# ---- harness ---------------------------------------------------------------------------------

## A failed GDScript assert only aborts its own function and the run still ends "OK", so count.
func _check(ok: bool, msg := "") -> void:
	if not ok:
		_failures += 1
		printerr("FAIL: ", msg)

func _on_started(_id: String, _shooter: int) -> void:
	_events.append("started")


func _on_potted(ball: Ball, _id: String, _pocket: StringName) -> void:
	_events.append("potted")
	_potted.append(ball)


func _on_trick(t: TrickShot, _id: String) -> void:
	_tricks.append(t.id)


func _on_ended(id: String, shooter: int, raw: int, ids: Array[StringName], foul: bool) -> void:
	_events.append("ended")
	_ended.append({shot_id = id, shooter = shooter, raw = raw, ids = ids, foul = foul})


func _on_cleared(_round: String) -> void:
	_events.append("cleared")


func _on_respawn(reason: StringName) -> void:
	_events.append("respawn:" + reason)


func _on_struck(_ball: Ball, _intent: ShotIntent) -> void:
	_strikes += 1


func _reset_records() -> void:
	_events.clear()
	_ended.clear()
	_tricks.clear()
	_potted.clear()


func _refresh() -> void:
	cue_ball = director.get_balls()[0]
	objs.clear()
	for b in director.get_balls():
		if not b.is_cue_ball:
			objs.append(b)


func _world(p: Vector2, b: Ball) -> Vector3:
	return table.to_global(Vector3(p.x, table.cloth_y() + b.radius + table.spec.clearance_margin_m, p.y))


func _pair(x: float) -> Array:
	return [Vector2(x, r + 0.002), Vector2(x, -(r + 0.002))]


func _behind(target: Vector2, aim_deg: float, dist: float) -> Vector2:
	return target - Vector2.from_angle(deg_to_rad(aim_deg)) * dist


## Cue ball + the listed object balls (in spawn order) go to exact spots; every other object ball
## leaves play (`clear_rest` also marks them pocketed, so a lone pot clears the table; `hold`
## freezes the placed ones where they are).
func _place(cue_pos: Vector2, obj_pos: Array, clear_rest := false, hold := false) -> void:
	cue_ball.restore(_world(cue_pos, cue_ball))
	for i in objs.size():
		if i < obj_pos.size():
			objs[i].restore(_world(obj_pos[i], objs[i]))
			objs[i].freeze = hold
		else:
			objs[i].is_pocketed = clear_rest
			objs[i].retire()
			objs[i].global_position = _world(Vector2.ZERO, objs[i])  # parked on the cloth, out of play
	await physics_frame
	await physics_frame
	var frames := 0
	while frames < 600:
		var still := true
		for b in director.get_balls():
			still = still and (b.freeze or b.is_resting)
		if still and frames > 5:
			return
		frames += 1
		await physics_frame
	_check(false, "table never settled")


func _shoot(aim_deg: float, power: float, spin := Vector2.ZERO) -> void:
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.from_angle(deg_to_rad(aim_deg))
	intent.power = power
	intent.spin_offset = spin
	_check(director.can_strike(cue_ball), "gate open before the shot")
	cue_ball.strike(intent, CUE_SPEC)
	await _wait_shot()


func _wait_shot() -> void:
	var frames := 0
	while _ended.is_empty() and frames < SHOT_TIMEOUT_FRAMES:
		frames += 1
		await physics_frame
	_check(not _ended.is_empty(), "shot never ended")
