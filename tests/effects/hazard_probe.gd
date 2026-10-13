extends SceneTree

## The hazard models (adhoc-1014a G, 06 P50-P53, docs/plan/01 "Hazard models"): Sunken Ship, Vacation, Pinball, Double Ball and the
## stat-only hazards, on the host's Jolt and in the client's BallMotion.
##   pure     the rolls are deterministic, legal (pins clear of pockets, the head spot, the rack, each other), the model never
##            adds energy, the shoreline crossing is analytic (step-size independent)
##   pins     Jolt's combine, pinned: a pin returns a ball at e 1 and no friction, and the ball keeps rolling (speed never gained)
##   hostile  the adversarial pins: a full-power shot between two pins, and inside a cage of four, ends inside the shot ceiling
##   budget   events per break with each hazard on against the plain table (fail past 1.5x), client error at most 5 mm
##   double   the doubled rack: count, fit, the id budget, the reward scaling
##   godot --path . --headless -s tests/effects/hazard_probe.gd [-- --only=pure,pins,hostile,double]
##   godot --path . --headless -s tests/effects/hazard_budget_probe.gd     (the `budget` section on its own: it is the long one)
## Prints HAZARD OK, or the failing checks and HAZARD FAIL (exit 1).

const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE := preload("res://src/gameplay/table/Table.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const NIGHT_1 := preload("res://src/resources/nights/night_1.tres")
const NIGHT_3 := preload("res://src/resources/nights/night_3.tres")

const GATE_M := 0.005            ## client vs host at every tick (07 §3, the M3 gate)
const BUDGET_X := 1.5            ## events per break with a hazard on, against the plain table
const SEEDS := 200
const PIN_MM := [1850, 330, 1850, -330, 2200, 0, 1000, 700]  ## the break's splash meets the first three; the cue ball's line grazes none, so the rack does the work

var table: Table
var fails := 0
var finished := false
var only: PackedStringArray = []
var variant := ""
var _balls: Array[Ball] = []
var _contacts := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7).split(",")
		elif a.begins_with("--variant="):
			variant = a.substr(10)
	create_timer(1500.0).timeout.connect(func() -> void:
		if not finished:
			print("HAZARD FAIL (script error or hang)")
			quit(1))
	table = TABLE.instantiate()
	root.add_child(table)
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## The sections a run without --only= does. hazard_budget_probe.gd extends this script and swaps the list (run_all gives a probe 300 s).
func _default_sections() -> PackedStringArray:
	return PackedStringArray(["pure", "pins", "hostile", "double"])


func _on(section: String) -> bool:
	return only.has(section) if not only.is_empty() else _default_sections().has(section)


func _run() -> void:
	await physics_frame
	if _on("pure"):
		_pure()
		_model()
	if _on("pins"):
		await _pins()
	if _on("hostile"):
		await _hostile()
	if _on("budget"):
		await _budget()
	if _on("budget"):
		await _budget_double()
	if _on("double"):
		_double()
	finished = true
	print("HAZARD OK" if fails == 0 else "HAZARD FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


# ---------------------------------------------------------------- pure: the rolls

func _pure() -> void:
	var spec := table.spec
	var layout := table.layout
	var r := spec.ball_radius_m
	var offset := Transform3D(Basis(), Vector3(0.0, 0.0, -3.5))  # where MainLevel puts the table
	var same := 0
	var legal := 0
	var corners := {}
	var sides := {}
	var shores_ok := 0
	var tilt_ok := 0
	var pin_gap := INF
	var pin_pocket := INF
	var pin_head := INF
	var pin_foot := INF
	var pin_edge := INF
	var pin_avoid := INF
	var distinct := {}
	var authored := PackedVector2Array()
	for e in RackDropper.authored(spec, NIGHT_1.authored_racks[0]):
		authored.append(e.pos)
	for s in SEEDS:
		var seed_ := hash([77, 1, s])
		for kind in [HazardModel.SUNKEN_SHIP, HazardModel.VACATION, HazardModel.PINBALL]:
			var a := HazardModel.roll(kind, seed_, spec, layout, authored)
			if a == HazardModel.roll(kind, seed_, spec, layout, authored):
				same += 1
			var m := HazardModel.from_params(kind, a, spec, layout, offset)
			if m != null and m.state() == HazardModel.from_params(kind, a, spec, layout, offset).state() and hash(m.state()) == hash(HazardModel.from_params(kind, a, spec, layout, offset).state()):
				legal += 1
			match kind:
				HazardModel.SUNKEN_SHIP:
					corners[m.corner] = true
					var ps: PocketSpec = layout.pockets.filter(func(p: PocketSpec) -> bool: return p.id == m.corner)[0]
					var want := Vector2(ps.position.x, ps.position.z).normalized()
					if m.tilt_dir.distance_to(want) < 1e-9:
						tilt_ok += 1
				HazardModel.VACATION:
					sides[a[1]] = true
					if absi(a[0]) <= int(spec.width_m * 120.0):
						shores_ok += 1
					distinct[a[0]] = true
				HazardModel.PINBALL:
					for i in m.pins_local.size():
						var q := m.pins_local[i]
						pin_edge = minf(pin_edge, minf(spec.length_m * 0.5 - absf(q.x), spec.width_m * 0.5 - absf(q.y)))
						pin_head = minf(pin_head, q.distance_to(Vector2(layout.spots.head.x, layout.spots.head.z)))
						pin_foot = minf(pin_foot, q.distance_to(Vector2(layout.spots.foot.x, layout.spots.foot.z)))
						for pk in layout.pockets:
							pin_pocket = minf(pin_pocket, q.distance_to(Vector2(pk.position.x, pk.position.z)) - layout.holes[pk.id].cup_radius * 1.5)
						for av in authored:
							pin_avoid = minf(pin_avoid, q.distance_to(av))
						for j in range(i + 1, m.pins_local.size()):
							pin_gap = minf(pin_gap, q.distance_to(m.pins_local[j]))
	_check(same == SEEDS * 3, "every roll is the same twice for the same seed (%d of %d)" % [same, SEEDS * 3])
	_check(legal == SEEDS * 3, "every roll builds, and its state() is the same twice (%d of %d)" % [legal, SEEDS * 3])
	_check(corners.size() == 4, "Sunken Ship picks every corner over %d seeds (%s)" % [SEEDS, corners.keys()])
	_check(tilt_ok == SEEDS, "the tilt points at the chosen pocket's centre, read from the layout (%d of %d, table offset in z)" % [tilt_ok, SEEDS])
	_check(sides.size() == 2 and shores_ok == SEEDS and distinct.size() > 50, "Vacation: both sides, the shoreline within +-12 %% of the width, %d distinct shorelines" % distinct.size())
	_check(pin_gap >= HazardModel.PIN_GAP_RADII * r * 0.81, "pins never closer than %.3f m (min %.3f)" % [HazardModel.PIN_GAP_RADII * r * 0.81, pin_gap])
	_check(pin_pocket >= HazardModel.PIN_POCKET_RADII * r - 0.002, "pins clear of every pocket (cup circle x1.5 + 8 radii): margin %.3f m" % pin_pocket)
	_check(pin_head >= HazardModel.PIN_HEAD_RADII * r - 0.002 and pin_foot >= HazardModel.PIN_RACK_RADII * r - 0.002, "pins clear of the head spot (%.2f m) and the rack (%.2f m)" % [pin_head, pin_foot])
	_check(pin_edge >= HazardModel.PIN_EDGE_RADII * r - 0.002, "pins clear of the rails (%.2f m)" % pin_edge)
	_check(pin_avoid >= HazardModel.PIN_AVOID_RADII * r - 0.002, "pins clear of an authored rack's balls (%.2f m)" % pin_avoid)
	# the zones, exactly
	var vm := HazardModel.from_params(HazardModel.VACATION, PackedInt32Array([100, 1]), spec, layout, offset)
	var on_water := Vector3(0.0, 0.0, -3.5 + 0.5)
	var on_sand := Vector3(0.0, 0.0, -3.5 - 0.5)
	_check(vm.zone_mult(on_water, 0.0, 0.0) == HazardModel.WATER_MULT and vm.zone_mult(on_sand, 0.0, 0.0) == HazardModel.SAND_MULT, "water on the +z side, sand on the other")
	var line := Vector3(0.0, 0.0, -3.5 + 0.1)
	_check(vm.zone_mult(line, 0.0, 1.0) == HazardModel.WATER_MULT and vm.zone_mult(line, 0.0, -1.0) == HazardModel.SAND_MULT, "on the line, the side the ball is moving into")
	_check(vm.zone_mult(Vector3.ZERO, 1.0, 0.0) != 1.0 and HazardModel.from_params(HazardModel.SUNKEN_SHIP, PackedInt32Array([0]), spec, layout, offset).zone_mult(on_water, 1.0, 1.0) == 1.0, "only Vacation has zones")
	_check(HazardModel.from_params(HazardModel.PINBALL, PackedInt32Array([1, 2, 3]), spec, layout, offset) == null, "a payload of the wrong length builds nothing")


# ---------------------------------------------------------------- pure: BallMotion

func _params(h: HazardModel, tilt := Vector2.ZERO) -> BallMotion.Params:
	var p := BallMotion.make_params(table.spec, table.spec.ball_radius_m)
	p.hazard = h
	p.tilt = tilt
	return p


func _model() -> void:
	var spec := table.spec
	var layout := table.layout
	var r := spec.ball_radius_m
	var pins := HazardModel.from_params(HazardModel.PINBALL, PackedInt32Array(PIN_MM), spec, layout, table.global_transform)
	var p := _params(pins)
	# 1. a bounce keeps the speed and the rolling: a head-on hit of a rolling ball comes back at its speed, not 43 % of it
	var s := BallMotion.State.new()
	s.pos = Vector3(0.0, p.floor_y, 0.0)
	s.lin = Vector3(6.0, 0.0, 0.0)
	s.ang = Vector3(0.0, 0.0, -6.0 / r)
	var out := HazardModel.bounce(s.lin, s.ang, Vector2(-1.0, 0.0))
	_check(absf(out[0].length() - 6.0) < 1e-5 and absf(out[0].x + 6.0) < 1e-5, "e = 1: the bounce returns the speed (%.4f)" % out[0].length())
	var slip := Vector2(out[0].x + r * out[1].z, out[0].z - r * out[1].x).length()
	_check(slip < 1e-5, "... and the ball keeps rolling (slip %s m/s: no skid)" % slip)
	var slow := HazardModel.bounce(Vector3(0.1, 0.0, 0.3), Vector3(0.0, 2.0, 0.0), Vector2(-1.0, 0.0))
	_check(absf(slow[0].x) < 1e-6 and absf(slow[0].z - 0.3) < 1e-6, "a hit slower than Jolt's bounce threshold (%.1f m/s) loses the normal speed only" % HazardModel.PIN_STICK_MPS)
	# 2. nothing is ever gained: random balls through the pins, 8 s in uneven chunks, speed never up
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var worst_gain := 0.0
	var hits := 0
	var t0 := Time.get_ticks_usec()
	for k in 300:
		var st := BallMotion.State.new()
		st.pos = Vector3(rng.randf_range(-2.0, 2.0), p.floor_y, rng.randf_range(-1.0, 1.0)) + table.global_position
		var sp := rng.randf_range(0.5, 24.0)
		var ang := rng.randf() * TAU
		st.lin = Vector3(cos(ang) * sp, 0.0, sin(ang) * sp)
		st.ang = Vector3(st.lin.z / r, rng.randf_range(-20.0, 20.0), -st.lin.x / r)
		var v_prev := Vector2(st.lin.x, st.lin.z).length()
		for c in 40:
			var before := st.lin
			BallMotion.advance(st, rng.randf_range(0.01, 0.4), p)
			var v_now := Vector2(st.lin.x, st.lin.z).length()
			worst_gain = maxf(worst_gain, v_now - v_prev)
			if (st.lin - before).length() > 1.0 and before.dot(st.lin) < 0.0:
				hits += 1
			v_prev = v_now
	var cost_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check(worst_gain < 2e-5, "the model never gains speed off a pin (300 balls x 40 chunks, %d reversals, worst gain %s m/s)" % [hits, worst_gain])
	print("hazard: BallMotion with pins: 300 x 40 chunks in %.0f ms (%.1f us per chunk)" % [cost_ms, cost_ms * 1000.0 / 12000.0])
	# 3. the shoreline crossing is analytic: one 4 s stretch equals 800 steps of 5 ms (and a ball crossing it slows in the sand)
	var vac := HazardModel.from_params(HazardModel.VACATION, PackedInt32Array([0, 1]), spec, layout, table.global_transform)
	var pv := _params(vac)
	var worst := 0.0
	for k in 40:
		var a := BallMotion.State.new()
		a.pos = Vector3(rng.randf_range(-1.5, 1.5), pv.floor_y, rng.randf_range(-0.8, 0.8)) + table.global_position
		var sp2 := rng.randf_range(0.6, 5.0)
		var an := rng.randf() * TAU
		a.lin = Vector3(cos(an) * sp2, 0.0, sin(an) * sp2)
		a.ang = Vector3(a.lin.z / r, 0.0, -a.lin.x / r)
		var b := BallMotion.State.new()
		b.copy_from(a)
		BallMotion.advance(a, 4.0, pv)
		for i in 800:
			BallMotion.advance(b, 0.005, pv)
		worst = maxf(worst, a.pos.distance_to(b.pos))
	_check(worst < 0.001, "the shoreline is crossed analytically: 4 s at once = 800 steps (worst %.2f mm)" % (worst * 1000.0))
	var w := BallMotion.State.new()
	w.pos = Vector3(0.0, pv.floor_y, 0.5) + table.global_position  # water
	w.lin = Vector3(1.0, 0.0, 0.0)
	w.ang = Vector3(0.0, 0.0, -1.0 / r)
	var sd := BallMotion.State.new()
	sd.pos = Vector3(0.0, pv.floor_y, -0.5) + table.global_position  # sand
	sd.lin = w.lin
	sd.ang = w.ang
	var plain := _params(null)
	var pw := BallMotion.State.new()
	pw.copy_from(w)
	BallMotion.advance(w, 1.0, pv)
	BallMotion.advance(sd, 1.0, pv)
	BallMotion.advance(pw, 1.0, plain)
	_check(w.lin.x > pw.lin.x + 0.1 and sd.lin.x < pw.lin.x - 0.2, "after 1 s from 1 m/s: water %.3f > plain %.3f > sand %.3f m/s" % [w.lin.x, pw.lin.x, sd.lin.x])


# ---------------------------------------------------------------- helpers: balls and shots

func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	b.contacted.connect(func(_a: Ball, _o: Node, _k: StringName) -> void: _contacts += 1)
	_balls.append(b)
	return b


func _clear() -> void:
	for b in _balls:
		b.queue_free()
	_balls.clear()
	for i in 6:
		await physics_frame


func _install(kind: StringName, params: PackedInt32Array) -> HazardModel:
	var m := HazardModel.from_params(kind, params, table.spec, table.layout, table.global_transform)
	table.sim.set_hazard(m)
	return m


func _y() -> float:
	return table.spec.bed_height_m + table.spec.ball_radius_m + 0.002


func _settle() -> void:
	for i in 90:
		await physics_frame


# ---------------------------------------------------------------- pins: Jolt's combine, pinned

func _pins() -> void:
	_install(HazardModel.PINBALL, PackedInt32Array([0, 0, 1500, 1000, -1500, -1000, 1500, -1000]))
	var r := table.spec.ball_radius_m
	var pin_at := Vector2(table.global_position.x, table.global_position.z)
	var worst_gain := 0.0
	var worst_loss := 0.0
	var worst_tangent := 0.0
	var worst_roll := 0.0
	var cases := 0
	# a ball already rolling at `speed` (set after a tiny strike opens the shot), head-on and glancing, slow to the 24 m/s cap
	for speed in [1.0, 3.0, 8.0, 15.0, 23.0]:
		for off in [0.0, 0.03, 0.07]:
			var b := _ball(CUE_T, Vector3(-1.6, _y(), off) + table.global_position)
			await _settle()
			var intent := ShotIntent.new()
			intent.aim_dir = Vector2.RIGHT
			intent.power = 0.02
			table.sim.request_shot(intent)
			await physics_frame
			b.linear_velocity = Vector3(speed, 0.0, 0.0)
			b.angular_velocity = Vector3(0.0, 0.0, -speed / r)
			var hist: Array[Vector3] = [Vector3(speed, 0.0, 0.0), Vector3(speed, 0.0, 0.0)]
			var pre := Vector3.ZERO
			var post := Vector3.ZERO
			var seen := false
			var after := 0
			var frames_after := -1
			for i in 1200:
				await physics_frame
				var v := b.linear_velocity
				if not seen and b.pin_hits > 0:  # the tick the pin's answer is applied; Jolt's own (flatter) one is still on screen the tick before
					seen = true
					pre = hist[hist.size() - 2]
					post = v
					frames_after = clampi(floori(0.8 / pre.length() * 120.0), 3, 36)  # 0.3 s, or 0.8 m of travel for a fast ball (the west rail is near)
				if seen:
					after += 1
					if after == frames_after:
						var slip := Vector2(v.x + r * b.angular_velocity.z, v.z - r * b.angular_velocity.x).length()
						worst_roll = maxf(worst_roll, slip / maxf(v.length(), 0.01))
						worst_loss = maxf(worst_loss, 1.0 - v.length() / (post.length() - 0.245 * after / 120.0))
						break
				hist.append(v)
			if seen:
				cases += 1
				worst_gain = maxf(worst_gain, post.length() / pre.length() - 1.0)
				# specular: a path at lateral offset `off` meets the circle of radius pin + ball at sin(phi) = off / R; no friction = the mirror image
				var big_r := table.sim.hazard.pin_r + r
				var phi := asin(clampf(off / big_r, -1.0, 1.0))
				var n := Vector2(-cos(phi), sin(phi))
				var want := Vector2(pre.x, pre.z) - 2.0 * Vector2(pre.x, pre.z).dot(n) * n
				worst_tangent = maxf(worst_tangent, (Vector2(post.x, post.z) - want).length() / pre.length())
				print("hazard:   speed %.0f off %.2f: pre %s post %s want %s err %.3f slip-ratio %.3f hits %d" % [speed, off, pre, post, want, (Vector2(post.x, post.z) - want).length() / pre.length(), worst_roll, b.pin_hits])
			b.queue_free()
			_balls.erase(b)
			await physics_frame
			await physics_frame
	print("hazard: pin hits %d: gain %.4f (never above 0), speed lost beyond drag %.3f, tangent change %.3f, slip after 0.3 s %.3f of speed" % [cases, worst_gain, worst_loss, worst_tangent, worst_roll])
	_check(cases >= 13, "the shots reached the pin (%d of 15)" % cases)
	_check(worst_gain <= 0.0005, "a pin never adds speed (worst %+.4f %%)" % (worst_gain * 100.0))
	_check(worst_loss <= 0.06, "a pin returns the ball's speed: 0.3 s later it is within 6 %% of the rolling-drag expectation (%.3f)" % worst_loss)
	_check(worst_tangent <= 0.03, "a pin has no friction: the ball leaves as the mirror image of how it came (worst error %.3f of its speed)" % worst_tangent)
	_check(worst_roll <= 0.12, "the ball keeps rolling off a pin: slip %.3f of its speed (a skid would lose 57 %% on a head-on hit)" % worst_roll)
	await _clear()
	table.sim.set_hazard(null)


# ---------------------------------------------------------------- hostile: no way to loop

## One full-power shot of the Round's cue ball from `from`, under a real RoundDirector (it owns the shot ceiling); returns
## {ended, sec, stilled, hits, gain}: `stilled` = the ceiling had to end it, `gain` = the most the ball's speed ever rose above its
## speed at the first pin hit (a pin must not lift it).
func _hostile_shot(label: String, cue: Ball, director: RoundDirector, from: Vector2, aim: Vector2, backstop := false, rolling_at := 0.0, preset_hits := 0) -> Dictionary:
	cue.restore(table.to_global(Vector3(from.x, table.cloth_y() + cue.radius, from.y)))
	for i in 90:
		await physics_frame
	var intent := ShotIntent.new()
	intent.aim_dir = aim
	intent.power = 1.0
	var ended := []
	director.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], _f: bool) -> void: ended.append(true), CONNECT_ONE_SHOT)
	var t0 := Time.get_ticks_usec()
	cue.strike(intent, preload("res://src/resources/cues/demo_cue.tres"))
	if rolling_at > 0.0:  # the shot opens with the strike; then the ball is set rolling true along the aim, so a ping-pong on the axis stays on it
		await physics_frame
		cue.linear_velocity = Vector3(aim.x, 0.0, aim.y).normalized() * rolling_at
		cue.angular_velocity = Vector3(cue.linear_velocity.z, 0.0, -cue.linear_velocity.x) / cue.radius
		cue.pin_hits = preset_hits
	var frames := 0
	var v_hit := 0.0
	var gain := 0.0
	var v0 := 0.0
	var hits := 0
	var hist: Array[float] = [0.0, 0.0]
	var ratios: Array[float] = []  # speed after / before each pin hit
	while ended.is_empty() and frames < 120 * 30:
		await physics_frame
		frames += 1
		var v := cue.linear_velocity.length()
		if cue.pin_hits > hits and cue.pin_hits > 0 and hist[hist.size() - 2] > 1.0:
			ratios.append(v / hist[hist.size() - 2])
		hits = maxi(hits, cue.pin_hits)  # (it goes back to 0 when the ball rests)
		hist.append(v)
		if backstop and frames == 24:
			director.set("_shot_time", RoundDirector.SHOT_CEILING_SEC - 0.05)  # whatever the pins are doing, the director stills the table now
		if frames == 2:
			v0 = v
		if cue.pin_hits > 0 and v_hit == 0.0:
			v_hit = v
		if v_hit > 0.0:
			gain = maxf(gain, v / v_hit - 1.0)
	var sec: float = director.get("_shot_time")
	var stilled := sec > RoundDirector.SHOT_CEILING_SEC
	print("hazard: %s: start %.1f m/s, %d pin hits, shot over: %s after %.1f s%s (%.0f s of wall), speed never above %+.2f %% of the first hit's" % [label, v0, hits, not ended.is_empty(), frames / 120.0, " (the ceiling stilled it)" if stilled else " (it ran out by itself)", (Time.get_ticks_usec() - t0) / 1e6, gain * 100.0])
	return {ended = not ended.is_empty(), sec = frames / 120.0, stilled = stilled, hits = hits, gain = gain, ratios = ratios}


func _hostile() -> void:
	var ceiling := RoundDirector.SHOT_CEILING_SEC
	var director := RoundDirector.new()
	director.table = table
	root.add_child(director)
	await physics_frame
	var cfg := NightConfig.new()
	cfg.object_ball_count = 1
	cfg.rounds_count = 1
	cfg.unlocked_ball_types = [&"red_basic"]
	director.start_round(cfg, 1, 99)
	var cue: Ball = director.get_balls()[0]
	var gap_mm := roundi(HazardModel.PIN_GAP_RADII * table.spec.ball_radius_m * 1000.0)
	var h := gap_mm / 2
	# two pins at the closest the roll allows, the ball in the corridor between them, shot along it
	_install(HazardModel.PINBALL, PackedInt32Array([0, -h, 0, h, 1800, 700, -1800, -700]))
	var a: Dictionary = await _hostile_shot("two pins %.2f m apart, shot along the corridor" % (gap_mm / 1000.0), cue, director, Vector2.ZERO, Vector2(0.0, 1.0), false, 20.0)
	_check(a.ended and a.sec <= ceiling + 1.5, "a full-power shot between two pins ends inside the shot ceiling (%.1f s <= %.0f s)" % [a.sec, ceiling])
	_check(a.hits >= 3 and a.gain <= 0.002, "... it really ricocheted (%d pin hits; a pin between two others amplifies every offset, so it leaves the corridor soon) and never gained speed (%+.3f %%)" % [a.hits, a.gain * 100.0])
	var elastic_ok: bool = a.ratios.size() >= 2
	for i in a.ratios.size():
		elastic_ok = elastic_ok and a.ratios[i] > 0.985 and a.ratios[i] < 1.0005
	print("hazard: speed after / before each hit: %s" % [a.ratios.map(func(x: float) -> String: return "%.3f" % x)])
	_check(elastic_ok, "the hits of a ball return its speed (e 1): %s" % [a.ratios])
	# the cap: a ball that has already had PIN_ELASTIC_HITS hits this shot meets the pin as a plain e 0.9 obstacle (head-on: the whole speed x 0.9)
	var cap: Dictionary = await _hostile_shot("the 9th hit of a ball", cue, director, Vector2.ZERO, Vector2(0.0, 1.0), false, 20.0, HazardModel.PIN_ELASTIC_HITS)
	_check(cap.ratios.size() >= 1 and cap.ratios[0] > HazardModel.PIN_CAP_E - 0.02 and cap.ratios[0] < HazardModel.PIN_CAP_E + 0.02, "from hit %d the pin is a plain e %.1f obstacle: %s" % [HazardModel.PIN_ELASTIC_HITS + 1, HazardModel.PIN_CAP_E, cap.ratios])
	var bs: Dictionary = await _hostile_shot("the ceiling as a backstop", cue, director, Vector2.ZERO, Vector2(0.0, 1.0), true, 20.0)
	_check(bs.ended and bs.sec <= 0.6, "the shot ceiling stills a ricochet in pins at once (%.2f s)" % bs.sec)
	var c: Dictionary = await _hostile_shot("... slightly off the axis", cue, director, Vector2.ZERO, Vector2(0.05, 1.0).normalized())
	_check(c.ended and c.sec <= ceiling + 1.5 and c.gain <= 0.002, "off the axis too (%.1f s)" % c.sec)
	# a ring of four pins round the ball, every 30 degrees from 7: the ball escapes through a gap or ricochets in the ring
	_install(HazardModel.PINBALL, PackedInt32Array([-h, -h, h, -h, -h, h, h, h]))
	var worst := 0.0
	var ring_hits := 0
	for k in 6:
		var d: Dictionary = await _hostile_shot("ring of four, angle %d" % (k * 30 + 7), cue, director, Vector2.ZERO, Vector2.from_angle(deg_to_rad(k * 30.0 + 7.0)))
		worst = maxf(worst, d.sec)
		ring_hits += d.hits
		_check(d.ended and d.sec <= ceiling + 1.5 and d.gain <= 0.002, "ring shot %d ends inside the ceiling (%.1f s), no speed gained (%+.3f %%)" % [k, d.sec, d.gain * 100.0])
	print("hazard: ring of four: worst %.1f s of the shot, %d pin hits in 6 shots" % [worst, ring_hits])
	# the client model too: 12 s of a ping-pong in one advance() call terminates, fast
	var m := _install(HazardModel.PINBALL, PackedInt32Array([0, -h, 0, h, 1800, 700, -1800, -700]))
	var s := BallMotion.State.new()
	var p := _params(m)
	s.pos = Vector3(0.0, p.floor_y, 0.0) + table.global_position
	s.lin = Vector3(0.0, 0.0, 24.0)
	s.ang = Vector3(24.0 / table.spec.ball_radius_m, 0.0, 0.0)
	var t0 := Time.get_ticks_usec()
	BallMotion.advance(s, 12.0, p)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check(ms < 250.0, "BallMotion.advance over 12 s of ping-pong between two pins returns (%.0f ms, MAX_PHASES %d)" % [ms, BallMotion.MAX_PHASES])
	table.sim.set_hazard(null)
	director.queue_free()
	await physics_frame


# ---------------------------------------------------------------- budget: events per break

func _break(angle: float, rack: Array[Dictionary] = []) -> Dictionary:
	var sim := table.sim
	_contacts = 0
	var y := _y()
	var g := table.global_position
	_ball(CUE_T, Vector3(-table.spec.length_m / 4.0, y, 0.0) + g)
	var r := table.spec.ball_radius_m
	var apex := table.spec.length_m / 4.0
	if rack.is_empty():  # SYNC's fixture: a 15-ball triangle
		for row in 5:
			for k in row + 1:
				_ball(RED_T, Vector3(apex + row * r * 1.74, y, (k - row * 0.5) * r * 2.02) + g)
	else:  # a RackDropper rack (Night rack, or Double Ball's doubled one)
		for e in rack:
			_ball(e.type, Vector3(e.pos.x, y, e.pos.y) + g)
	var diff := SimDiff.new()
	root.add_child(diff)
	diff.attach(sim)
	await _settle()
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT.rotated(angle)
	intent.power = 1.0
	var over := []
	sim.all_resting.connect(func() -> void: over.append(true), CONNECT_ONE_SHOT)
	sim.request_shot(intent)
	var ceiling := RoundDirector.SHOT_CEILING_TILTED_SEC if sim.table_tilt_deg != 0.0 else RoundDirector.SHOT_CEILING_SEC
	var ticks := 0
	var pin_hits := 0
	var seen_hits := {}
	var hl := table.spec.length_m * 0.5 + RoundDirector.OFF_TABLE_RADII * r
	var hw := table.spec.width_m * 0.5 + RoundDirector.OFF_TABLE_RADII * r
	while over.is_empty() and ticks < 120 * 40:
		await physics_frame
		ticks += 1
		for b in _balls:  # what RoundDirector._retire_off_table does: a ball that left the table is retired, the shot can end
			var p := b.global_position
			if not b.retired and not b.is_pocketed and (p.y < table.spec.bed_height_m - 1.0 or ((absf(p.x - g.x) > hl or absf(p.z - g.z) > hw) and not table.in_hole(Vector2(p.x - g.x, p.z - g.z), r))):
				b.retire()
		for b in _balls:  # (a ball's counter goes back to 0 when it rests)
			var h: int = b.pin_hits
			if h > int(seen_hits.get(b, 0)):
				pin_hits += h - int(seen_hits.get(b, 0))
			seen_hits[b] = h
		if ticks > ceiling * 120.0:  # RoundDirector's shot ceiling: past it every ball is stilled
			for b in _balls:
				if not b.is_pocketed:  # (a ball falling into a cup is not on the cloth to be stilled)
					b.linear_velocity = Vector3.ZERO
					b.angular_velocity = Vector3.ZERO
	for i in 40:
		await physics_frame
	var res := {events = diff.events, contacts = _contacts, err = diff.max_err_m, first_bad = diff.first_bad, pin_hits = pin_hits}
	if diff.max_err_m > GATE_M:
		print("hazard:   %s" % diff.report())
	diff.queue_free()
	await _clear()
	return res


func _budget() -> void:
	var sim := table.sim
	var variants := {
		"plain": func() -> void: pass,
		"sunken_ship (4 deg to a corner)": func() -> void:
			var m := _install(HazardModel.SUNKEN_SHIP, PackedInt32Array([3]))
			sim.set_tilt_direction(m.tilt_dir)
			sim.set_stat(&"table_tilt_deg", 4.0),
		"vacation (water +z, sand -z)": func() -> void: _install(HazardModel.VACATION, PackedInt32Array([0, 1])),
		"pinball (4 pins in the break's way)": func() -> void: _install(HazardModel.PINBALL, PackedInt32Array(PIN_MM)),
		"ice_rink (cloth x0.45)": func() -> void: sim.set_stat(&"cloth_friction_mult", 0.45),
		"lead_ball (cue ball x2.2)": func() -> void: sim.set_stat(&"cue_ball_mass_mult", 2.2),
	}
	var angles := [0.0, 0.025]
	var base_events := 0.0
	var base_per_contact := 0.0
	for label: String in variants:
		if variant != "" and label != "plain" and not label.contains(variant):
			continue
		var events := 0
		var contacts := 0
		var pin_hits := 0
		var worst := 0.0
		var bad := ""
		variants[label].call()
		for a in angles:
			var r: Dictionary = await _break(a)
			events += r.events
			contacts += r.contacts
			pin_hits += r.pin_hits
			worst = maxf(worst, r.err)
			if bad == "" and r.first_bad != "":
				bad = r.first_bad
		sim.set_hazard(null)
		sim.set_stat(&"table_tilt_deg", 0.0)
		sim.set_stat(&"cloth_friction_mult", 1.0)
		sim.set_stat(&"cue_ball_mass_mult", 1.0)
		var per_shot := events / float(angles.size())
		var per_contact := events / float(maxi(contacts, 1))
		if label == "plain":
			base_events = per_shot
			base_per_contact = per_contact
		print("hazard: %-38s %6.1f events/break (x%.2f), %.2f per contact (x%.2f), max client error %.2f mm%s" % [label, per_shot, per_shot / base_events, per_contact, per_contact / base_per_contact, worst * 1000.0, ", %.1f pin hits/break" % (pin_hits / float(angles.size())) if pin_hits > 0 else ""])
		_check(worst <= GATE_M, "%s: the client stays within %.0f mm of the host (%.2f mm) %s" % [label, GATE_M * 1000.0, worst * 1000.0, bad])
		# the budget: raw events within 1.5x of the plain break. A friction hazard that lengthens every shot also lengthens the
		# shot's rail hits (physics, not model error): those are held to the same 1.5x per contact instead.
		var by_shot := per_shot <= base_events * BUDGET_X
		var by_contact := per_contact <= base_per_contact * BUDGET_X
		_check(by_shot or by_contact, "%s: events per break within %.1fx of the plain table (x%.2f raw, x%.2f per contact)" % [label, BUDGET_X, per_shot / base_events, per_contact / base_per_contact])


## Double Ball's break against the plain RackDropper rack it doubles (12 -> 24 object balls): events grow with the balls that move,
## so the budget here is x2.2 (2 x the balls, plus the pots' cup landings), not the x1.5 of a hazard that changes no ball count.
func _budget_double() -> void:
	var cfg := NightConfig.new()
	cfg.object_ball_count = 12
	cfg.unlocked_ball_types = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]
	var plain := {events = 0, contacts = 0, err = 0.0}
	var dbl := {events = 0, contacts = 0, err = 0.0}
	var seeds := [7000, 7001]
	for sd in seeds:
		for pair in [[plain, 1.0], [dbl, 2.0]]:
			var rack := RackDropper.drop(table.spec, table.layout, cfg, sd, 0, pair[1])
			var cue_to_rack := Vector2(rack.map(func(e: Dictionary) -> float: return e.pos.x).reduce(func(a: float, b: float) -> float: return a + b) / rack.size() + table.spec.length_m / 4.0, 0.0)
			var res: Dictionary = await _break(atan2(0.0, cue_to_rack.x), rack)
			var tgt: Dictionary = pair[0]
			tgt.events += res.events
			tgt.contacts += res.contacts
			tgt.err = maxf(tgt.err, res.err)
	var pe: float = plain.events / float(seeds.size())
	var de: float = dbl.events / float(seeds.size())
	print("hazard: %-38s %6.1f events/break (x%.2f of the plain 12-ball rack's %.1f), %.1f contacts, max client error %.2f mm" % ["double_ball (12 -> 24 object balls)", de, de / pe, pe, dbl.contacts / float(seeds.size()), dbl.err * 1000.0])
	_check(dbl.err <= GATE_M, "double_ball: the client stays within %.0f mm of the host (%.2f mm)" % [GATE_M * 1000.0, dbl.err * 1000.0])
	_check(de <= pe * 2.2, "double_ball: events per break within x2.2 of the plain rack (x%.2f)" % (de / pe))
	_check(de <= 450.0, "double_ball: under the plain break's 450-event budget (07 §3): %.0f" % de)


# ---------------------------------------------------------------- double: the rack

func _double() -> void:
	var spec := table.spec
	var layout := table.layout
	var r := spec.ball_radius_m
	var interior := RackDropper.interior(spec)
	var biggest := 0
	var min_gap := INF
	var inside := true
	var keep_ok := true
	var ids_max := 0
	var plain_total := 0.0
	var double_total := 0.0
	var keeps := RackDropper.keepouts(spec, layout)
	for cfg: NightConfig in [NIGHT_1, NIGHT_3]:
		for s in 30:
			var plain := RackDropper.drop(spec, layout, cfg, 500 + s, cfg.rounds_count + 1)
			var dbl := RackDropper.drop(spec, layout, cfg, 500 + s, cfg.rounds_count + 1, 2.0)
			_check(dbl.size() == mini(2 * plain.size(), RackDropper.object_cap(2.0)), "%s seed %d: %d balls doubled to %d" % [cfg.resource_path.get_file(), s, plain.size(), dbl.size()])
			biggest = maxi(biggest, dbl.size())
			var splitters := 0
			for e in dbl:
				var p: Vector2 = e.pos
				inside = inside and interior.has_point(p)
				for k in keeps:
					keep_ok = keep_ok and p.distance_to(Vector2(k.x, k.y)) >= k.z - 1e-6
				if (e.type as BallType).behaviour_tags.has(&"splitter"):
					splitters += 1
				double_total += (e.type as BallType).base_value / 2.0
			for e in plain:
				plain_total += (e.type as BallType).base_value
			for i in dbl.size():
				for j in range(i + 1, dbl.size()):
					min_gap = minf(min_gap, (dbl[i].pos as Vector2).distance_to(dbl[j].pos))
			ids_max = maxi(ids_max, 1 + dbl.size() + splitters)
	# the worst case: a 12-ball rack with every gimmick in the pool, doubled
	var worst_cfg := NightConfig.new()
	worst_cfg.object_ball_count = 12
	worst_cfg.unlocked_ball_types = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty", &"stone_ball", &"bomb_ball", &"split_ball", &"joker_ball"]
	for s in 20:
		var big := RackDropper.drop(spec, layout, worst_cfg, 900 + s, 0, 2.0)
		var splitters := big.filter(func(e: Dictionary) -> bool: return (e.type as BallType).behaviour_tags.has(&"splitter")).size()
		biggest = maxi(biggest, big.size())
		ids_max = maxi(ids_max, 1 + big.size() + splitters)  # the cue ball, the rack, one red child per splitter
	_check(biggest == RackDropper.object_cap(2.0), "the largest doubled rack is %d object balls (the cap, %d)" % [biggest, RackDropper.object_cap(2.0)])
	_check(ids_max < BallEventCodec.MAX_BALLS, "net ids stay under %d with the cue ball and every splitter's child: max %d" % [BallEventCodec.MAX_BALLS, ids_max])
	_check(inside and keep_ok, "every doubled ball is on the cloth, out of the pockets")
	_check(min_gap >= 2.0 * r, "no two balls overlap (closest centres %.1f mm, diameter %.1f)" % [min_gap * 1000.0, 2.0 * r * 1000.0])
	var ratio := double_total / plain_total
	_check(ratio > 0.8 and ratio < 1.25, "each pot pays half: a doubled rack is worth %.2f of a plain one" % ratio)
	print("hazard: Double Ball: largest rack %d object balls (+ the cue ball + the splitters' children: net ids <= %d of %d); value of the Night racks at half a ball: x%.2f of the plain racks" % [biggest, ids_max, BallEventCodec.MAX_BALLS, ratio])
