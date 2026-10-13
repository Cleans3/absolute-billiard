extends SceneTree

## Chaos VFX probe (docs/plan/10): combo rules, the client-side contact classifier on synthetic frames, the classifier
## against a real break (its hits vs the host's own contacts), fake pots / tricks / scratches through ImpactFx, tier caps,
## pool stability (no node or object growth) and that everything goes back to sleep.
##   godot --path . --headless -s tests/fx/fx_probe.gd
## Prints FX OK.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const PENALTY := preload("res://src/resources/ball_types/black_penalty.tres")
const SEED := 20260921
const BASE := 1000  # tick of a synthetic frame's first byte

var table: Table
var director: RoundDirector
var fx: ImpactFx
var cam: Camera3D
var r: float
var y: float  # ball centre height
var _failures := 0
var _kinds := {}  # kind -> fx_fired count, from the signal
var _nodes_at_start := 0


func _init() -> void:
	table = TABLE.instantiate()
	root.add_child(table)
	cam = Camera3D.new()
	root.add_child(cam)
	cam.current = true
	director = RoundDirector.new()
	director.table = table
	root.add_child(director)
	fx = ImpactFx.new()
	fx.table = table
	fx.round_director = director
	root.add_child(fx)
	fx.fx_fired.connect(func(kind: StringName, _s: float) -> void: _kinds[kind] = int(_kinds.get(kind, 0)) + 1)
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures += 1
		printerr("FAIL: " + msg)


func _run() -> void:
	await physics_frame
	_nodes_at_start = _count_nodes(fx)
	r = table.spec.ball_radius_m
	y = table.spec.bed_height_m + r
	_combo_rules()
	_tap_synthetic()
	await _real_break()
	await _real_combo()
	await _fake_events()
	await _tiers()
	await _pools_and_sleep()
	print("FX OK" if _failures == 0 else "FX FAIL (%d)" % _failures)
	quit(0 if _failures == 0 else 1)


# ---- combo rules -------------------------------------------------------------------------------

func _combo_rules() -> void:
	print("probe: combo rules")
	var c := FxCombo.new()
	c.shot_started()
	_check(c.pot().n == 1 and c.pot().n == 2 and c.pot().n == 3, "pots in one Shot count 1, 2, 3")
	_check(FxCombo.level_for(1) == 0 and FxCombo.level_for(3) == 2 and FxCombo.level_for(99) == FxCombo.MAX_LEVEL, "level = n - 1, capped")
	_check(c.shot_ended(false) == 0 and c.streak == 1, "a clean potting Shot starts a streak")
	c.shot_started()
	_check(c.pot().n == 2, "the streak carries into the next Shot's first pot")
	c.shot_ended(false)
	_check(c.streak == 2, "two Shots in a row")
	c.shot_started()
	_check(c.shot_ended(false) == 2 and c.streak == 0, "a Shot with no pot breaks a streak of 2 and reports it")
	c.shot_started()
	c.pot()
	c.shot_ended(false)
	c.shot_started()
	c.shot_ended(true)
	_check(c.streak == 0, "a foul resets the streak")
	_check(FxCombo.trick_tier(1.15) == 1 and FxCombo.trick_tier(1.35) == 2 and FxCombo.trick_tier(1.6) == 4, "trick tiers follow the multiplier")


# ---- classifier on synthetic frames --------------------------------------------------------------

func _frame(events: Array) -> PackedByteArray:
	var f := PackedByteArray()
	BallEventCodec.begin(f, 1, BASE)
	var s := BallMotion.State.new()
	var origin := table.global_position
	for e in events:
		s.pos = origin + e.pos
		s.lin = e.lin
		s.ang = Vector3.ZERO
		BallEventCodec.append(f, e.id, e.get("flag", BallEventCodec.Flag.NONE), e.off, s, origin)
	return f


func _new_tap(strike := 0) -> FxHitTap:
	var t := FxHitTap.new()
	var p := BallMotion.make_params(table.spec, r)
	t.params_for = func(_id: int) -> BallMotion.Params: return p
	t.radius = r
	t.origin = table.global_position
	t.half_length = table.spec.length_m * 0.5
	t.half_width = table.spec.width_m * 0.5
	t.strike_id = strike
	var centres: Array[Vector2] = []
	var mouth := 0.0
	for id in table.pockets:
		var local := table.to_local(table.pockets[id].position)
		centres.append(Vector2(local.x, local.z))
		mouth = maxf(mouth, table.pockets[id].mouth_width_m)
	t.set_pockets(centres, mouth)
	return t


func _tap_synthetic() -> void:
	print("probe: contact classifier, synthetic frames")
	var t := _new_tap()
	# the cue ball leaves the tip: first event of a ball at rest -> KICK
	var h := t.process(_frame([{id = 0, off = 2, pos = Vector3(-0.8, y, 0), lin = Vector3(4, 0, 0)}]), 0)
	_check(h.size() == 1 and h[0].kind == FxHitTap.Kind.KICK and absf(h[0].strength - 4.0) < 0.05, "cue strike is one KICK of ~4 m/s")
	# ...and 10 ticks on it meets a ball at rest: ball-ball, strength = relative pre-impact speed
	h = t.process(_frame([
		{id = 0, off = 12, pos = Vector3(-0.3, y, 0), lin = Vector3(0.3, 0, 0)},
		{id = 1, off = 12, pos = Vector3(-0.3 + 2.0 * r, y, 0), lin = Vector3(3.9, 0, 0)},
	]), 0)
	_check(h.size() == 1 and h[0].kind == FxHitTap.Kind.BALL, "two balls with an event on one tick make exactly one BALL hit (got %d)" % h.size())
	if h.size() == 1:
		_check(h[0].strength > 3.6 and h[0].strength < 4.0, "ball-ball strength ~ the closing speed (%.2f)" % h[0].strength)
		_check(h[0].tick == BASE + 12 and absf(h[0].pos.x - (-0.3 + r)) < 0.001, "hit sits at the contact point on the event's tick")
	# a ball rebounding off the far cushion: RAIL, strength = approach speed into the cushion
	t.process(_frame([{id = 2, off = 2, pos = Vector3(1.0, y, 0.3), lin = Vector3(5, 0, 0)}]), 0)
	h = t.process(_frame([{id = 2, off = 22, pos = Vector3(table.spec.length_m * 0.5 - r - 0.02, y, 0.3), lin = Vector3(-4, 0, 0)}]), 0)
	_check(h.size() == 1 and h[0].kind == FxHitTap.Kind.RAIL, "a rebound at the cushion is a RAIL hit")
	if h.size() == 1:
		_check(h[0].strength > 4.3 and h[0].strength < 4.9, "rail strength ~ approach speed (%.2f)" % h[0].strength)
		_check(h[0].normal.x < -0.9, "rail normal points away from the cushion")
	# the host rescales a rebound one tick after the bounce: that slower re-send is the same hit, not another
	t.process(_frame([{id = 6, off = 2, pos = Vector3(1.0, y, -0.3), lin = Vector3(6, 0, 0)}]), 0)
	var bounce := Vector3(table.spec.length_m * 0.5 - r - 0.02, y, -0.3)
	h = t.process(_frame([{id = 6, off = 22, pos = bounce, lin = Vector3(-5, 0, 0)}]), 0)
	h.append_array(t.process(_frame([{id = 6, off = 24, pos = bounce + Vector3(-0.08, 0, 0), lin = Vector3(-1.5, 0, 0)}]), 0))
	_check(h.size() == 1, "a cushion hit and its rescale echo are one RAIL hit (got %d)" % h.size())
	# a bounce at a corner pocket is the jaw's: the host reports no cushion there, so neither does the client
	var corner := Vector3(table.spec.length_m * 0.5 - r - 0.03, y, table.spec.width_m * 0.5 - r - 0.03)
	t.process(_frame([{id = 7, off = 2, pos = corner + Vector3(-0.6, 0, -0.6), lin = Vector3(5, 0, 3)}]), 0)
	h = t.process(_frame([{id = 7, off = 18, pos = corner, lin = Vector3(-4.5, 0, 3)}]), 0)
	_check(h.is_empty(), "a jaw bounce at a pocket is no RAIL hit (got %d)" % h.size())
	# a re-send that merely corrects a coasting ball is not an impact
	t.process(_frame([{id = 3, off = 2, pos = Vector3(0, y, 0.5), lin = Vector3(2, 0, 0)}]), 0)
	h = t.process(_frame([{id = 3, off = 12, pos = Vector3(0.28, y, 0.5), lin = Vector3(1.85, 0, 0)}]), 0)
	_check(h.is_empty(), "a divergence re-send is no hit")
	# a vertical hop or landing is not either
	h = t.process(_frame([{id = 3, off = 30, pos = Vector3(0.5, y, 0.5), lin = Vector3(1.8, 2.0, 0)}]), 0)
	_check(h.is_empty(), "a hop is no hit")
	# a lone jump of a ball that is not the cue ball in mid-table (blast / nudge) is dropped; the cue ball's is a KICK
	h = _new_tap().process(_frame([{id = 4, off = 3, pos = Vector3(0, y, 0), lin = Vector3(3, 0, 0)}]), 0)
	_check(h.is_empty(), "only the cue ball can be kicked")
	# lifecycle events never hit
	h = _new_tap().process(_frame([
		{id = 0, off = 3, pos = Vector3(0, y, 0), lin = Vector3(5, 0, 0), flag = BallEventCodec.Flag.POCKETED},
		{id = 0, off = BallReplica.NOW, pos = Vector3(0, y, 0), lin = Vector3(5, 0, 0)},
	]), 77)
	_check(h.is_empty(), "pocket / apply-now events are no hit")
	# a break-like frame: cue -> 1, then 1 -> 2 and 1 -> 3 a few ticks later, one frame, earliest first
	t = _new_tap()
	t.process(_frame([{id = 0, off = 1, pos = Vector3(-1, y, 0), lin = Vector3(8, 0, 0)}]), 0)
	h = t.process(_frame([
		{id = 0, off = 16, pos = Vector3(0, y, 0), lin = Vector3(0.4, 0, 0)},
		{id = 1, off = 16, pos = Vector3(2.0 * r, y, 0), lin = Vector3(7.4, 0, 0)},
		{id = 1, off = 30, pos = Vector3(0.3, y, 0), lin = Vector3(1.0, 0, 0)},
		{id = 2, off = 30, pos = Vector3(0.3 + 2.0 * r, y, 0), lin = Vector3(6.2, 0, 0)},
	]), 0)
	_check(h.size() == 2 and h[0].tick < h[1].tick, "a chain makes one hit per contact, in order (got %d)" % h.size())


# ---- classifier vs the host's own contacts on real shots --------------------------------------------

## Five hard shots at nearest / farthest object balls, tallying both sides of the wire.
func _real_break() -> void:
	print("probe: classifier vs real contacts")
	director.start_round(NightConfig.new(), 1, SEED)
	for i in 120:
		await physics_frame
	var sim := table.sim
	sim.capture = true
	var frames: Array[PackedByteArray] = []
	sim.frame_flushed.connect(func(f: PackedByteArray) -> void: frames.append(f.duplicate()))  # the sim reuses its buffer
	var truth := {ball = 0, rail = 0, ball_sum = 0.0, rail_sum = 0.0}
	var cue: Ball = null
	for b in director.get_balls():
		if b.is_cue_ball:
			cue = b
		b.contacted.connect(func(ball: Ball, other: Node, kind: StringName) -> void:
			var h := ImpactFx.hit_from_contact(ball, other, kind)
			if h.is_empty() or h.strength < FxHitTap.MIN_DV:
				return
			if h.kind == FxHitTap.Kind.BALL:
				truth.ball += 1
				truth.ball_sum += h.strength
			else:
				truth.rail += 1
				truth.rail_sum += h.strength)
	var before := _kinds.duplicate()
	var got := {ball = 0, rail = 0, kick = 0, ball_sum = 0.0, rail_sum = 0.0}
	var shots := 0
	var start := cue.global_position
	for k in 5:
		if k > 0:  # a cue ball resting within 4 radii of a cushion reads as a rail hit, not a strike (FxHitTap._solo): shoot each one from the open
			cue.restore(start)
			await physics_frame
			while sim.awake > 0 or director.shot_in_progress:
				await physics_frame
		var target: Ball = null  # alternate nearest / farthest object ball so the shots differ
		for b in director.get_balls():
			if b.is_cue_ball or b.is_pocketed or b.retired:
				continue
			var closer := target == null or b.global_position.distance_to(cue.global_position) < target.global_position.distance_to(cue.global_position)
			if target == null or closer == (k % 2 == 0):
				target = b
		var d := target.global_position - cue.global_position
		var intent := ShotIntent.new()
		intent.aim_dir = Vector2(d.x, d.z).normalized()
		intent.power = 1.0
		frames.clear()
		sim.request_shot(intent)
		await sim.all_resting
		for i in 40:
			await physics_frame
		shots += 1
		var tap := _new_tap(cue.net_id)
		tap.params_for = fx.tap.params_for
		for f in frames:
			for h in tap.process(f, 0):
				match h.kind:
					FxHitTap.Kind.BALL:
						got.ball += 1
						got.ball_sum += h.strength
					FxHitTap.Kind.RAIL:
						got.rail += 1
						got.rail_sum += h.strength
					_:
						got.kick += 1
		await create_timer(0.1).timeout
		if cue.is_pocketed or cue.retired:
			break
	print("fx_probe: %d shots | host contacts ball %d (%.1f m/s) rail %d (%.1f) | stream ball %d (%.1f) rail %d (%.1f) kick %d | fx_fired %s" % [
		shots, truth.ball, truth.ball_sum, truth.rail, truth.rail_sum, got.ball, got.ball_sum, got.rail, got.rail_sum, got.kick, str(_kinds)])
	_check(truth.ball >= 3 and truth.rail >= 2, "the shots have contacts to compare (ball %d, rail %d)" % [truth.ball, truth.rail])
	_check(absi(got.ball - truth.ball) <= maxi(3, ceili(truth.ball * 0.35)), "stream ball hits %d vs host %d" % [got.ball, truth.ball])
	_check(absi(got.rail - truth.rail) <= maxi(3, ceili(truth.rail * 0.35)), "stream rail hits %d vs host %d" % [got.rail, truth.rail])
	_check(absf(got.ball_sum - truth.ball_sum) <= truth.ball_sum * 0.35, "stream ball impact total %.1f vs host %.1f" % [got.ball_sum, truth.ball_sum])
	_check(got.kick == shots, "one cue strike per shot in the stream (got %d for %d)" % [got.kick, shots])
	_check(int(_kinds.get(&"kick", 0)) - int(before.get(&"kick", 0)) == shots, "the host path pops each strike once")
	_check(int(_kinds.get(&"ball", 0)) > int(before.get(&"ball", 0)), "the host path popped ball hits")
	sim.capture = false


# ---- a real two-pot trick shot, end to end ---------------------------------------------------------

func _world(spot: Vector2, b: Ball) -> Vector3:
	return table.to_global(Vector3(spot.x, table.cloth_y() + b.radius, spot.y))


## round_probe's combo: the cue ball splits two touching balls dead centre and both go in opposite corners
## (Carom + Combo). Whatever the physics does, the FX must follow it: two pots, a COMBO x2, one trick celebration.
func _real_combo() -> void:
	print("probe: real two-pot trick shot")
	director.start_round(NightConfig.new(), 1, SEED)
	for i in 60:
		await physics_frame
	var cue: Ball = null
	var objs: Array[Ball] = []
	var rest: Array[Ball] = []
	for b in director.get_balls():
		if b.is_cue_ball:
			cue = b
		elif director.value_of(b.ball_type) > 0 and objs.size() < 2:
			objs.append(b)  # the pair that gets split: two scoring balls, not the penalty black
		else:
			rest.append(b)
	var spots := [Vector2(1.0, r + 0.002), Vector2(1.0, -(r + 0.002))]
	cue.restore(_world(Vector2(-1.4, 0.0), cue))
	for i in objs.size():
		objs[i].restore(_world(spots[i], objs[i]))
	for b in rest:  # everything else leaves play, parked on the cloth
		b.is_pocketed = false
		b.retire()
		b.global_position = _world(Vector2.ZERO, b)
	for i in 200:  # settle on the cloth: a shot is only legal at rest
		await physics_frame
	fx.combo = FxCombo.new()
	_kinds.clear()
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 0.7
	table.sim.request_shot(intent)
	await director.shot_ended
	await create_timer(0.1).timeout
	print("fx_probe: two-pot shot fired %s" % str(_kinds))
	_check(int(_kinds.get(&"pot", 0)) == 2, "two real pots, two pot FX (got %d)" % int(_kinds.get(&"pot", 0)))
	_check(int(_kinds.get(&"combo", 0)) == 1, "the second pot reads COMBO x2")
	_check(int(_kinds.get(&"trick", 0)) == 1, "the trick shot gets one celebration")
	_check(int(_kinds.get(&"ball", 0)) >= 2 and int(_kinds.get(&"kick", 0)) == 1, "the strike and the splitting hits popped")
	_check(fx.combo.streak == 1, "the potting Shot started a streak")


# ---- pots, scratches, tricks, streaks through the real node ------------------------------------------

func _pot_flag(ball: Ball) -> void:
	ball.net_flag.emit(ball, BallEventCodec.Flag.POCKETED)


func _fake_events() -> void:
	print("probe: pots / scratch / penalty / trick / streak")
	var objs: Array[Ball] = []  # object balls worth points (a BallType with a positive value)
	var cue: Ball = null
	for b in director.get_balls():
		if b.is_cue_ball:
			cue = b
		elif director.value_of(b.ball_type) > 0:
			objs.append(b)
	var sim := table.sim
	_kinds.clear()
	fx.combo = FxCombo.new()  # the real shots above left a streak behind
	var tid := "probe-1"
	# a pot between shots is nobody's: no FX, no combo count
	sim.ball_flag_applied.emit(objs[0], BallEventCodec.Flag.POCKETED)
	_check(_kinds.is_empty(), "a drop between shots fires nothing")
	sim.shot_started_net.emit(1, 1, 0)
	sim.ball_flag_applied.emit(objs[0], BallEventCodec.Flag.POCKETED)  # the client path
	_pot_flag(objs[1])  # the host path (Ball.net_flag is connected by shot_started_net)
	_check(int(_kinds.get(&"pot", 0)) == 2, "two pots fired two pot FX (got %d)" % int(_kinds.get(&"pot", 0)))
	_check(int(_kinds.get(&"combo", 0)) == 1, "the second pot of a Shot is a COMBO")
	_check(fx.combo.shot_pots == 2, "FxCombo counted both")
	var banner: Label = fx._stage._rows[FxStage.ROW_COMBO]
	_check(banner.visible and banner.text.begins_with("COMBO x2"), "the combo banner shows COMBO x2 (%s)" % banner.text)
	sim.ball_flag_applied.emit(cue, BallEventCodec.Flag.POCKETED)
	_check(int(_kinds.get(&"scratch", 0)) == 1, "the cue ball dropping is a scratch")
	var bad: Ball = objs[2]
	bad.ball_type = PENALTY
	sim.ball_flag_applied.emit(bad, BallEventCodec.Flag.POCKETED)
	_check(int(_kinds.get(&"penalty", 0)) == 1 and fx.combo.shot_pots == 2, "a penalty ball fizzles and is no combo pot")
	sim.ball_flag_applied.emit(objs[3], BallEventCodec.Flag.RETIRED)
	_check(int(_kinds.get(&"pot", 0)) == 2, "only POCKETED flags are pots")
	director.trick_detected.emit(TrickShot.make(&"Carom", tid), tid)
	director.trick_detected.emit(TrickShot.make(&"Combo", tid), tid)
	_check(int(_kinds.get(&"trick", 0)) == 1, "one celebration per Shot, the best trick first")
	var trick_banner: Label = fx._stage._rows[FxStage.ROW_TRICK]
	_check(trick_banner.visible and trick_banner.text == "CAROM!", "the trick banner names the trick (%s)" % trick_banner.text)
	await process_frame
	await process_frame  # process_frame fires before the nodes' _process: the shake lands on the second
	_check(fx.is_processing() and absf(cam.h_offset) + absf(cam.v_offset) > 0.0, "a trick shakes the camera (%.4f, %.4f)" % [cam.h_offset, cam.v_offset])
	var none: Array[StringName] = []
	director.shot_ended.emit(tid, 1, 100, none, false)
	_check(fx.combo.streak == 1, "a clean potting Shot starts a streak")
	# next Shot: its first pot already reads COMBO x2 off the streak
	sim.shot_started_net.emit(2, 1, 0)
	sim.ball_flag_applied.emit(objs[4], BallEventCodec.Flag.POCKETED)
	_check(int(_kinds.get(&"combo", 0)) == 2, "a pot straight after a potting Shot continues the streak")
	director.shot_ended.emit("probe-2", 1, 100, none, false)
	sim.shot_started_net.emit(3, 1, 0)
	director.shot_ended.emit("probe-3", 1, 0, none, true)
	_check(int(_kinds.get(&"lost", 0)) == 1, "a streak of 2 ending in a foul is mourned")
	# the fake shots above ran out of the live-shot state: nothing fires between shots
	var n := _kinds.duplicate()
	sim.ball_flag_applied.emit(objs[5], BallEventCodec.Flag.POCKETED)
	_check(_kinds == n, "no FX after shot_ended")
	# the client path: a contact frame fed straight in pops on the spot (host at_playback is immediate)
	var balls := int(_kinds.get(&"ball", 0))
	sim.shot_started_net.emit(4, 1, 0)
	fx.feed_frame(_frame([
		{id = 0, off = 5, pos = Vector3(0, y, 0), lin = Vector3(0.2, 0, 0)},
		{id = 1, off = 5, pos = Vector3(2.0 * r, y, 0), lin = Vector3(4.0, 0, 0)},
	]))
	_check(int(_kinds.get(&"ball", 0)) == balls, "an unseen-before pair at rest is not a hit (strength 0)")
	fx.feed_frame(_frame([{id = 0, off = 1, pos = Vector3(-0.5, y, 0), lin = Vector3(4.0, 0, 0)}]))
	_check(int(_kinds.get(&"kick", 0)) >= 1, "feed_frame pops a cue strike")
	sim.shot_started_net.emit(5, 1, 0)  # leave the live state tidy for the next section
	director.shot_ended.emit("probe-4", 1, 0, none, false)
	# a trick on a Shot that potted nothing pays nothing: a minor word, no confetti, no shake
	sim.shot_started_net.emit(6, 1, 0)
	var shown := int(_kinds.get(&"trick", 0))
	director.trick_detected.emit(TrickShot.make(&"Carom", "probe-dud"), "probe-dud")
	_check(int(_kinds.get(&"trick_minor", 0)) >= 1 and int(_kinds.get(&"trick", 0)) == shown, "a trick with no pot is a minor word, not a celebration")
	director.shot_ended.emit("probe-dud", 1, 0, none, false)
	# pops grow with the camera distance so the far end of the table still reads
	var near_pos: Vector3 = cam.global_position + Vector3(0.0, 0.0, -1.0)
	var far_pos: Vector3 = cam.global_position + Vector3(0.0, 0.0, -6.0)
	_check(is_equal_approx(fx._far_scale(near_pos), 1.0) and fx._far_scale(far_pos) > 2.0 and fx._far_scale(far_pos) <= ImpactFx.POP_FAR_MAX, "pop size grows with distance, capped (%.2f)" % fx._far_scale(far_pos))
	# the game's own beats: a hazard starting, a Drink going down, GO, a cleared table, the Flaming Shot
	_kinds.clear()
	fx._on_event_applied(&"tilted_table", 1, 1.25)
	var haz: Label = fx._stage._rows[FxStage.ROW_TRICK]
	_check(int(_kinds.get(&"hazard", 0)) == 1 and haz.visible and haz.text == "TILTED TABLE!", "a hazard starting is announced (%s)" % haz.text)
	fx._drink_banner(FxCatalog.drink(&"beer"))
	var sip: Label = fx._stage._rows[FxStage.ROW_MINOR]
	_check(int(_kinds.get(&"drink", 0)) == 1 and sip.text == "BEER!", "a drink going down is announced (%s)" % sip.text)
	fx._on_round_started(2, 120.0, 1)
	_check(int(_kinds.get(&"go", 0)) == 1 and (fx._stage._rows[FxStage.ROW_COMBO] as Label).text == "ROUND 2 - GO!", "a Round starting says GO")
	fx._on_round_ended(&"cleared", 900)
	_check(int(_kinds.get(&"cleared", 0)) == 1 and (fx._stage._rows[FxStage.ROW_TRICK] as Label).text == "TABLE CLEARED!", "a cleared table is celebrated")
	fx._flames = true
	sim.shot_started_net.emit(7, 1, 0)
	fx._hit(FxHitTap.Kind.BALL, table.global_position + Vector3(0, y, 0), Vector3.RIGHT, 6.0)
	_check(int(_kinds.get(&"flames", 0)) == 1 and int(_kinds.get(&"ball", 0)) == 1, "a hit under the Flaming Shot throws embers")
	fx._flames = false
	director.shot_ended.emit("probe-5", 1, 0, none, false)
	# the Pocket Jackpot marks its pocket for the Round and a pot there is a JACKPOT
	var jp: PocketSpec = table.pockets[table.pockets.keys()[0]]
	fx._show_beacon(table.pockets.keys()[0], 3.0)
	_check(fx._beacon.visible and fx._beacon_label.visible and fx._beacon_label.text == "x3", "the jackpot pocket is marked")
	sim.shot_started_net.emit(8, 1, 0)
	_kinds.clear()
	fx._pot(Vector3(jp.position.x, jp.position.y, jp.position.z), Color.RED, true)
	_check(int(_kinds.get(&"jackpot", 0)) == 1, "a pot in the marked pocket is a JACKPOT")
	director.shot_ended.emit("probe-6", 1, 0, none, false)
	fx._on_round_ended(&"shots", 0)
	_check(not fx._beacon.visible and not fx._beacon_label.visible, "the mark goes with the Round")


# ---- tiers -------------------------------------------------------------------------------------

func _burst(count: int) -> int:
	var before := int(_kinds.get(&"rail", 0))
	for i in count:
		fx._hit(FxHitTap.Kind.RAIL, table.global_position + Vector3(0, y, 0), Vector3.BACK, 5.0)
	return int(_kinds.get(&"rail", 0)) - before


func _tiers() -> void:
	print("probe: tier scaling")
	await process_frame
	QualityManager.current_tier = 0
	_check(_burst(30) == ImpactFx.TIER_HITS_PER_FRAME[0], "tier 0 caps one frame at %d hits" % ImpactFx.TIER_HITS_PER_FRAME[0])
	await process_frame
	QualityManager.current_tier = 2
	_check(_burst(30) == ImpactFx.TIER_HITS_PER_FRAME[2], "tier 2 caps one frame at %d hits" % ImpactFx.TIER_HITS_PER_FRAME[2])
	fx._light.visible = false
	fx._light_kick(Vector3.ZERO, Color.WHITE, 3.0)
	_check(not fx._light.visible, "tier 2 has no flash light")
	QualityManager.current_tier = 0
	await process_frame


# ---- pools and sleep ---------------------------------------------------------------------------

func _count_nodes(n: Node) -> int:
	var c := 1
	for k in n.get_children():
		c += _count_nodes(k)
	return c


## Fires `rounds` frames of hits, pots and tricks far past every pool's size.
func _storm(rounds: int, tag: String) -> void:
	var balls := director.get_balls()
	for i in rounds:
		await process_frame
		for k in 4:
			fx._hit(i % 3, table.global_position + Vector3(0, y, 0), Vector3.UP, 2.0 + (i % 7))
		if i % 40 == 0:
			table.sim.ball_flag_applied.emit(balls[1 + (i / 40) % 8], BallEventCodec.Flag.POCKETED)
			director.trick_detected.emit(TrickShot.make(&"RailRunner", "%s-%d" % [tag, i]), "%s-%d" % [tag, i])


func _pools_and_sleep() -> void:
	print("probe: pool stability and idle")
	var sim := table.sim
	sim.shot_started_net.emit(9, 1, 0)
	var counts: Array[int] = []
	for round in 3:  # round 0 builds engine-side caches (fonts, shader variants): not a leak
		await _storm(300, "storm%d" % round)
		await create_timer(2.8).timeout
		counts.append(int(Performance.get_monitor(Performance.OBJECT_COUNT)))
	print("fx_probe: objects after each storm %s, %d nodes under ImpactFx" % [str(counts), _count_nodes(fx)])
	_check(counts[2] <= counts[1] + 2, "no object leak across storms %s" % str(counts))
	var none: Array[StringName] = []
	director.shot_ended.emit("storm", 1, 0, none, false)
	_check(_count_nodes(fx) == _nodes_at_start, "the pools never grow (%d -> %d nodes)" % [_nodes_at_start, _count_nodes(fx)])
	await create_timer(3.2).timeout
	_check(not fx.is_processing(), "ImpactFx sleeps once every effect has played out")
	_check(fx._stage.idle(), "FxStage sleeps too")
	_check(cam.h_offset == 0.0 and cam.v_offset == 0.0, "the camera is left where it was")
	for m in fx._pops:
		_check(not m.visible, "every pop sprite is hidden again")
		break
