extends SceneTree

## The small pieces of 06 P49: BallReplica's authoritative insert (a state older than the ball's newest event is never lost, a
## jump over 1 mm is spread over 100 ms and never shown as a pop, a smaller one is just taken; a state with no motion is held
## where it is), TableHash (equal input = equal digest in any dictionary order, one changed thing = another digest) and
## RoundDirector.table_check (a ball moved 1 mm, a retire, a pocket stat, a motion number or a hazard parameter each change it).
##   godot --path . --headless -s tests/sync/replica_probe.gd      prints REPLICA OK

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")

var _checks := 0
var _p: BallMotion.Params


class FakeFx extends Node:
	signal effect_applied(id: StringName, target: int, owner: int, duration: float)
	signal effect_expired(id: StringName, target: int, owner: int)
	var hazard := {}

	func get_stat(_stat: StringName, _peer: int, base: float, _crew := true) -> float:
		return base

	func hazard_state() -> Dictionary:
		return hazard


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		printerr("FAIL: ", msg)
		quit(1)


func _state(x: float) -> BallMotion.State:
	var s := BallMotion.State.new()
	s.pos = Vector3(x, _p.floor_y, 0.0)
	return s


func _shown(r: BallReplica, t: float) -> float:
	var out := BallMotion.State.new()
	r.sample(0, t, _p, out)
	return out.pos.x + r.blend_offset(0, t).x


func _init() -> void:
	_p = BallMotion.make_params(TableSpec.new(), 0.05715)
	call_deferred("_run")


func _run() -> void:
	_blend()
	_newest_wins()
	_hold()
	_hash()
	await _digest()
	print("replica: %d checks" % _checks)
	print("REPLICA OK")
	quit()


## A state with no motion at all is the host's "frozen here": it stays, even a few mm under the cloth (resting on a pocket's lip).
func _hold() -> void:
	var r := BallReplica.new()
	var lip := _state(0.3)
	lip.pos.y = _p.floor_y - 0.0036
	r.anchor(0, 100, lip)
	var out := BallMotion.State.new()
	r.sample(0, 400.0, _p, out)
	_check(is_equal_approx(out.pos.y, lip.pos.y), "a ball at rest on a lip is not dropped into the cup (y %f)" % out.pos.y)
	var moving := _state(0.3)
	moving.lin = Vector3(1.0, 0.0, 0.0)
	r.anchor(1, 100, moving)
	r.sample(1, 112.0, _p, out)
	_check(out.pos.x > 0.3, "and a moving one still moves")


func _digest() -> void:
	var table: Table = TABLE.instantiate()
	root.add_child(table)
	var fx := FakeFx.new()
	fx.name = "EffectManager"
	root.add_child(fx)
	var rd := RoundDirector.new()
	rd.table = table
	root.add_child(rd)
	await physics_frame
	_check(rd.table_check() == 0, "no Round, no digest")
	rd.start_round(NIGHT_1, 1, 1234)
	for i in 120:
		await physics_frame
	var base := rd.table_check()
	_check(base != 0 and base == rd.table_check(), "a digest, and a stable one")
	fx.hazard = {"corner": &"corner_ne", "pins": [Vector2(0.1, 0.2)]}
	var with_hazard := rd.table_check()
	_check(with_hazard != base, "the hazard parameters are in it")
	fx.hazard = {"pins": [Vector2(0.1, 0.2)], "corner": &"corner_ne"}
	_check(rd.table_check() == with_hazard, "in any key order")
	fx.hazard = {"corner": &"corner_ne", "pins": [Vector2(0.1, 0.3)]}
	_check(rd.table_check() != with_hazard, "and a pin that moved changes it")
	var ball: Ball = rd.get_balls()[3]
	var before := rd.table_check()
	ball.global_position += Vector3(0.0003, 0.0, 0.0)
	ball.global_position += Vector3(0.0012, 0.0, 0.0)
	_check(rd.table_check() != before, "a ball 1.5 mm off is another digest")
	ball.global_position -= Vector3(0.0015, 0.0, 0.0)
	_check(rd.table_check() == before, "and back")
	var before_pocket := rd.table_check()
	table.apply_pocket_stats(1.2, 0.0, 1234)
	_check(rd.table_check() != before_pocket, "pocket stats are in it")
	table.apply_pocket_stats(1.0, 0.0, 1234)
	table.sim.set_stat(&"table_tilt_deg", 1.0)
	_check(rd.table_check() != before_pocket, "tilt is in it")
	table.sim.set_stat(&"table_tilt_deg", 0.0)
	_check(rd.table_check() == before_pocket, "and out again")
	ball.retire()
	_check(rd.table_check() != before_pocket, "a retired ball is in it")
	rd.queue_free()
	table.queue_free()
	fx.queue_free()


func _blend() -> void:
	var r := BallReplica.new()
	r.anchor(0, 100, _state(0.0))
	# the host says the ball is 5 mm over, stamped for tick 110, heard at 105
	r.insert_blended(0, 110, _state(0.005), 105.0, _p)
	_check(is_zero_approx(_shown(r, 109.0)), "before its tick the old place is drawn")
	_check(is_zero_approx(_shown(r, 110.0)), "at its tick nothing has moved yet: no pop (%f)" % _shown(r, 110.0))
	var prev := 0.0
	var worst_step := 0.0
	for t in range(111, 123):
		var x := _shown(r, float(t))
		_check(x >= prev - 1e-9, "the correction only ever closes")
		worst_step = maxf(worst_step, x - prev)
		prev = x
	_check(absf(prev - 0.005) < 1e-6, "100 ms later it is on the host's place (%f)" % prev)
	_check(worst_step <= 0.005 / BallReplica.BLEND_TICKS + 1e-6, "no step bigger than 1/12 of the error (%f)" % worst_step)
	_check(is_zero_approx(r.blend_offset(0, 400.0).x), "and the blend is gone")
	# 0.5 mm is under the threshold: taken at once
	var r2 := BallReplica.new()
	r2.anchor(0, 100, _state(0.0))
	r2.insert_blended(0, 110, _state(0.0005), 105.0, _p)
	_check(is_zero_approx(r2.blend_offset(0, 110.0).x) and absf(_shown(r2, 110.0) - 0.0005) < 1e-9, "under 1 mm: no blend")
	# a second correction mid-blend continues from what is drawn
	var r3 := BallReplica.new()
	r3.anchor(0, 100, _state(0.0))
	r3.insert_blended(0, 110, _state(0.010), 105.0, _p)
	var mid := _shown(r3, 116.0)
	r3.insert_blended(0, 116, _state(0.0), 116.0, _p)
	_check(absf(_shown(r3, 116.0) - mid) < 1e-9, "a correction on a correction does not pop either (%f vs %f)" % [_shown(r3, 116.0), mid])
	# a lifecycle change is a teleport
	r3.clear_blend(0)
	_check(is_zero_approx(r3.blend_offset(0, 118.0).x), "clear_blend")


func _newest_wins() -> void:
	var r := BallReplica.new()
	r.anchor(0, 500, _state(0.1))  # a ball registered late: its anchor is newer than the host's stamp
	r.insert_blended(0, 100, _state(0.2), 520.0, _p)
	_check(r.newest_tick(0) == 500, "the authoritative state takes the ball's newest tick, not its own older one")
	_check(absf(_shown(r, 600.0) - 0.2) < 1e-6 or absf(_shown(r, 700.0) - 0.2) < 1e-6, "and it wins")


func _hash() -> void:
	var a := TableHash.new()
	a.add_variant({"b": 2, "a": [1, 2.0, "x"], "c": Vector2(1, 2)})
	var b := TableHash.new()
	b.add_variant({"c": Vector2(1, 2), "a": [1, 2.0, "x"], "b": 2})
	_check(a.result() == b.result(), "a dictionary hashes the same in any order")
	var c := TableHash.new()
	c.add_variant({"c": Vector2(1, 2), "a": [1, 2.0001, "x"], "b": 2})
	_check(a.result() != c.result(), "a changed number changes the digest")
	var d := TableHash.new()
	d.add_float(0.70000001)
	var e := TableHash.new()
	e.add_float(0.7)
	_check(d.result() == e.result(), "floats are rounded to 1e-4")
	_check(TableHash.new().result() != 0, "a digest is never 0 (0 = none on the wire)")
