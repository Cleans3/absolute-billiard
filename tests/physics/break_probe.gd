extends SceneTree

## Full-power break (adhoc-1013c U12, 01 §3 "The break"): a Round's opening shot at full charge must move the rack, not two or
## three balls of it. Ten seeded 12-ball racks (RackDropper.drop) are broken from the head spot at power 1.0, aimed at the
## formation's centre; "moved" = potted, or travelled more than one ball radius. Accept: mean >= 70 % and no seed under 50 %;
## no ball may leave the table along the cloth or fall through it (tunnelling at the 24 m/s ceiling) and at most `HOP_OUT_MAX` of
## the 120 balls may be kicked out through the air by a pocket rim (the real pockets' reject-at-speed, 01 §2; the game calls that
## a foul, `RoundDirector`), every shot rests inside 10 s. The authored Night 1 triangle is gated too, the other authored racks
## (spread out on purpose, they are puzzles not breaks) are printed.
##   godot --path . --headless -s tests/physics/break_probe.gd        prints BREAK OK

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RACKS := ["n1_r1", "n1_r2", "n1_r3", "finale_r1", "finale_r2", "finale_r3"]
const HOP_OUT_MAX := 3
const SEEDS := 10
const BALLS := 12
const MEAN_MIN := 0.70
const SEED_MIN := 0.50
const REST_MAX_SEC := 10.0
const CAP_SEC := 20.0
const OFF_TABLE_M := 0.05

var table: Table
var _fail := 0
var _hopped := 0  # balls kicked out of the table through the air, over every break
var _balls: Array[Ball] = []


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail += 1
		printerr("BREAK: " + msg)


func _run() -> void:
	await physics_frame
	var cfg := NightConfig.new()
	cfg.object_ball_count = BALLS
	cfg.rounds_count = 1
	cfg.unlocked_ball_types = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]
	var sum := 0.0
	var worst := 1.0
	var rests := PackedFloat32Array()
	for s in SEEDS:
		var r := await _break(RackDropper.drop(table.spec, table.layout, cfg, 7000 + s), "seed %d" % (7000 + s))
		sum += r.moved
		worst = minf(worst, r.moved)
		rests.append(r.rest)
	var mean := sum / SEEDS
	rests.sort()
	print("break: %d seeded racks of %d: mean %.0f %% moved, worst %.0f %%, rest median %.1f s max %.1f s" % [SEEDS, BALLS, mean * 100.0, worst * 100.0, rests[SEEDS / 2], rests[SEEDS - 1]])
	_check(mean >= MEAN_MIN, "mean %.0f %% of the rack moved, need >= %.0f %%" % [mean * 100.0, MEAN_MIN * 100.0])
	_check(worst >= SEED_MIN, "worst seed moved %.0f %%, need >= %.0f %%" % [worst * 100.0, SEED_MIN * 100.0])
	print("break: %d of %d balls were kicked out of the table through the air by a pocket rim (allowed: %d)" % [_hopped, SEEDS * (BALLS + 1), HOP_OUT_MAX])
	_check(_hopped <= HOP_OUT_MAX, "%d balls hopped out of the table over %d breaks, allowed %d" % [_hopped, SEEDS, HOP_OUT_MAX])
	for id in RACKS:
		var rack: RackLayout = load("res://src/resources/racks/%s.tres" % id)
		var r := await _break(RackDropper.authored(table.spec, rack), id)
		if id == "n1_r1":
			_check(r.moved >= MEAN_MIN, "the Night 1 triangle moved %.0f %%, need >= %.0f %%" % [r.moved * 100.0, MEAN_MIN * 100.0])
	if _fail > 0:
		printerr("BREAK FAILED: %d" % _fail)
		quit(1)
		return
	print("BREAK OK")
	quit()


## Racks `entries` (RackDropper placements: table-local x, z), breaks it, returns {moved: fraction, rest: seconds}.
func _break(entries: Array[Dictionary], what: String) -> Dictionary:
	var y := table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	var head: Vector3 = table.layout.spots.head  # spots is a Dictionary: a typed declaration, not an inference
	var cue := _spawn(CUE_T, Vector3(head.x, y, head.z))
	var objs: Array[Ball] = []
	var start: Array[Vector3] = []
	var centre := Vector3.ZERO
	for e in entries:
		var p := Vector3(e.pos.x, y, e.pos.y)
		objs.append(_spawn(e.type, p))
		start.append(p)
		centre += p
	centre /= float(entries.size())
	for i in 90:  # balls placed on the cloth settle to is_resting before a shot is legal
		await physics_frame
	while table.sim.awake > 0:
		await physics_frame
	var intent := ShotIntent.new()
	var d := centre - cue.global_position
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 1.0
	var f0 := Engine.get_physics_frames()
	table.sim.request_shot(intent)
	var guard := Time.get_ticks_msec() + int(CAP_SEC * 1000.0)
	await physics_frame
	var floor_y := table.spec.bed_height_m + table.spec.ball_radius_m
	var hl := table.spec.length_m * 0.5 + OFF_TABLE_M
	var hw := table.spec.width_m * 0.5 + OFF_TABLE_M
	var out := {}  # Ball -> true once its centre is past the nose rectangle and not over a pocket
	var off := 0   # left along the cloth (tunnelled) or fell through it
	var hopped := 0  # left through the air
	while table.sim.awake > 0 and Time.get_ticks_msec() < guard:
		await physics_frame
		for b in _balls:
			if b.is_pocketed or b.retired:
				continue
			var p := b.global_position
			if p.y < table.spec.bed_height_m - 1.0:  # what RoundDirector does to a ball that has left: it is retired, the shot can end
				if not out.has(b):
					out[b] = true
					off += 1
				b.retire()
				continue
			if out.has(b) or not (absf(p.x) > hl or absf(p.z) > hw or is_nan(p.x)):
				continue
			if table.in_hole(Vector2(p.x, p.z), table.spec.ball_radius_m):
				continue
			out[b] = true
			if absf(p.y - floor_y) <= table.spec.ball_radius_m or p.y < floor_y:
				off += 1
			else:
				hopped += 1
	_hopped += hopped
	var rest := (Engine.get_physics_frames() - f0) / float(PhysicsSim.LIVE_TICK)
	var moved := 0
	for i in objs.size():
		var b := objs[i]
		var gone := b.is_pocketed or b.retired
		if gone or b.global_position.distance_to(start[i]) > table.spec.ball_radius_m:
			moved += 1
	var frac := float(moved) / float(objs.size())
	print("break: %s: %d / %d moved (%.0f %%), %d potted, rest %.1f s" % [what, moved, objs.size(), frac * 100.0, objs.filter(func(b: Ball) -> bool: return b.is_pocketed).size(), rest])
	if hopped > 0:
		print("break: %s: %d ball(s) hopped out of the table" % [what, hopped])
	_check(off == 0, "%s: %d ball(s) left the table along the cloth or fell through it" % [what, off])
	_check(rest <= REST_MAX_SEC, "%s: rest after %.1f s, ceiling %.0f s" % [what, rest, REST_MAX_SEC])
	for b in _balls:
		root.remove_child(b)
		b.free()
	_balls.clear()
	for i in 4:
		await physics_frame
	return {moved = frac, rest = rest}


func _spawn(type: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = type
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	_balls.append(b)
	return b
