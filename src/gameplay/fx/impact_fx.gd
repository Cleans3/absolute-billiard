class_name ImpactFx
extends Node3D

## Chaos VFX for every hit, pot, trick shot and combo (docs/plan/10). Presentation only, on every peer, never writes state.
## Host: Ball.contacted / net_flag fire at the real moment. Client: PhysicsSim.frame_received frames are decoded by FxHitTap
## and scheduled with PhysicsSim.at_playback, so a pop lands when the ball it belongs to is drawn there (04 §2.4).
## All nodes are built once and reused; tier 1/2 shrink counts, tier 2 drops lights and screen flashes.

## Probes / debug: one per FX spawned. kind: &"ball" &"rail" &"kick" &"pot" &"scratch" &"penalty" &"trick" &"combo" &"lost".
signal fx_fired(kind: StringName, strength: float)

const SPARK_SLOTS := 8
const FOUNTAIN_SLOTS := 4
const FIZZLE_SLOTS := 2
const POP_SLOTS := 12
const LABEL_SLOTS := 6
const HARD_MPS := 8.0  # impact speed that maxes every hit scale (cue power cap is 10)
const TIER_SCALE := [1.0, 0.6, 0.35]
const TIER_HITS_PER_FRAME := [6, 4, 2]
const WORDS := ["CLACK!", "CRACK!", "WHAM!", "SMACK!"]
const LABEL_GAP_MSEC := 160
const LABEL_PX := 0.0022  # Label3D metres per pixel at size 1 (fixed_size: constant on screen)
const SHAKE_M := 0.12  # camera frustum offset at full trauma
const COMBO_COLORS: Array[Color] = [
	Color(1.0, 1.0, 1.0), Color(1.0, 0.95, 0.35), Color(1.0, 0.6, 0.2), Color(1.0, 0.3, 0.5), Color(0.9, 0.3, 1.0),
	Color(0.3, 0.8, 1.0), Color(0.4, 1.0, 0.5), Color(1.0, 0.85, 0.2), Color(1.0, 1.0, 1.0),
]
const TRICK_TITLES := {
	&"Combo": "COMBO SHOT!", &"Combo3": "TRIPLE COMBO!!", &"BankShot": "BANK SHOT!", &"KickShot": "KICK SHOT!",
	&"Carom": "CAROM!", &"RailRunner": "RAIL RUNNER!!!",
}
const TRICK_COLORS := {
	&"Combo": Color(1.0, 0.85, 0.2), &"Combo3": Color(1.0, 0.5, 0.15), &"BankShot": Color(0.3, 0.85, 1.0),
	&"KickShot": Color(0.5, 1.0, 0.45), &"Carom": Color(1.0, 0.4, 0.8), &"RailRunner": Color(1.0, 0.25, 0.25),
}

@export var round_director: RoundDirector
@export var table: Table

var combo := FxCombo.new()
var tap := FxHitTap.new()
var stats := {}  # kind -> times fired since the node was built (probes)

var _sim: PhysicsSim
var _r := 0.05715
var _shot_live := false
var _celebrated := ""  # shot_id whose trick already got its banner
var _by_id := {}
var _sparks: Array[GPUParticles3D] = []
var _fountains: Array[GPUParticles3D] = []
var _fizzles: Array[GPUParticles3D] = []
var _pops: Array[MeshInstance3D] = []
var _pop_t := PackedFloat32Array()
var _pop_dur := PackedFloat32Array()
var _labels: Array[Label3D] = []
var _label_t := PackedFloat32Array()
var _label_dur := PackedFloat32Array()
var _label_y := PackedFloat32Array()
var _next := {&"spark": 0, &"fountain": 0, &"fizzle": 0, &"pop": 0, &"label": 0}
var _light: OmniLight3D
var _light_energy := 0.0
var _stage: FxStage
var _trauma := 0.0
var _cam: Camera3D
var _frame_id := -1
var _frame_hits := 0
var _last_label_msec := 0


func _ready() -> void:
	set_process(false)
	if table == null or round_director == null:
		return  # a probe may build the node first and wire it later with `setup()`
	setup(table, round_director)


## Builds the pools and connects the sources. Called by `_ready` when both exports are set.
func setup(p_table: Table, p_director: RoundDirector) -> void:
	table = p_table
	round_director = p_director
	_sim = table.sim
	_r = table.spec.ball_radius_m
	tap.radius = _r
	tap.origin = table.global_position
	tap.half_length = table.spec.length_m * 0.5
	tap.half_width = table.spec.width_m * 0.5
	tap.params_for = _params_for
	_build_pools()
	_sim.shot_started_net.connect(_on_shot_started_net)
	_sim.shot_started.connect(_on_strike)
	_sim.ball_flag_applied.connect(_on_flag)
	if _sim.has_signal(&"frame_received") and not multiplayer.is_server():
		_sim.connect(&"frame_received", feed_frame)
	round_director.trick_detected.connect(_on_trick)
	round_director.shot_ended.connect(_on_shot_ended)
	set_process(false)


# ---------------------------------------------------------------- sources

## Client: a contact-event frame as received from the host. Hits are scheduled on the playback clock.
func feed_frame(frame: PackedByteArray) -> void:
	for h in tap.process(frame, _sim.playback_tick()):
		_sim.at_playback(h.tick, _play.bind(h))


func _play(h: Dictionary) -> void:
	_hit(h.kind, h.pos, h.normal, h.strength)


func _on_shot_started_net(_id: int, _shooter: int, _base: int) -> void:
	_shot_live = true
	combo.shot_started()
	tap.reset()
	_by_id.clear()
	var cue_id := -1
	for b in _sim.get_balls():
		_by_id[b.net_id] = b
		if b.is_cue_ball:
			cue_id = b.net_id
		if multiplayer.is_server() and not b.contacted.is_connected(_on_contact):
			b.contacted.connect(_on_contact)
			b.net_flag.connect(_on_flag)
	tap.strike_id = cue_id
	var centres: Array[Vector2] = []
	var mouth := 0.0
	for id in table.pockets:
		var local := table.to_local(table.pockets[id].position)
		centres.append(Vector2(local.x, local.z))
		mouth = maxf(mouth, table.pockets[id].mouth_width_m)
	tap.set_pockets(centres, mouth)


## Host: the cue ball leaves the tip. (A client sees the same pop as the cue ball's first event, FxHitTap KICK.)
func _on_strike(ball: Ball, intent: ShotIntent) -> void:
	var aim := intent.aim_dir.normalized()
	_hit(FxHitTap.Kind.KICK, ball.global_position, Vector3(aim.x, 0.0, aim.y), clampf(intent.power, 0.0, 1.0) * _sim.active_cue.power_cap_speed_mps)


## The hit a host contact makes, or {}: both balls of a ball-ball touch report it, only the lower id speaks.
## Strength = relative pre-impact speed (RoundDirector's bomb uses the same), or the approach speed into a cushion.
## A cushion's signal can land a step late, when `pre_solve_velocity` already leaves the rail at e0 x the approach.
static func hit_from_contact(ball: Ball, other: Node, kind: StringName) -> Dictionary:
	if kind == &"BALL":
		var o := other as Ball
		if ball.net_id >= o.net_id:
			return {}
		var a := ball.global_position
		var b := o.global_position
		return {kind = FxHitTap.Kind.BALL, pos = (a + b) * 0.5, normal = (b - a).normalized(), strength = (ball.pre_solve_velocity - o.pre_solve_velocity).length()}
	var n: Vector3 = other.get_meta(&"rail_normal", Vector3.ZERO)
	var vn := ball.pre_solve_velocity.dot(n)
	return {kind = FxHitTap.Kind.RAIL, pos = ball.global_position - n * ball.radius, normal = n, strength = -vn if vn < 0.0 else vn / ball.spec.cushion_restitution}


func _on_contact(ball: Ball, other: Node, kind: StringName) -> void:
	var h := hit_from_contact(ball, other, kind)
	if not h.is_empty():
		_play(h)


func _params_for(id: int) -> BallMotion.Params:
	var b: Variant = _by_id.get(id)  # untyped: a split/bomb ball can be freed while still keyed here
	return (b as Ball).motion if is_instance_valid(b) else null


## A lifecycle flag, host (Ball.net_flag) or client at its playback tick (PhysicsSim.ball_flag_applied).
func _on_flag(ball: Ball, flag: int) -> void:
	if flag != BallEventCodec.Flag.POCKETED or not _shot_live:
		return
	var at := _pocket_pos(ball)
	if ball.is_cue_ball:
		_scratch(at)
		return
	var value := round_director.value_of(ball.ball_type)
	if value < 0:
		_penalty(at)
	else:
		_pot(at, ball.ball_type.color, value > 0)


func _on_trick(trick: TrickShot, shot_id: String) -> void:
	if shot_id == _celebrated:
		return  # the list is sorted best first: the paid trick gets the stage
	_celebrated = shot_id
	var tier := FxCombo.trick_tier(trick.multiplier)
	var color: Color = TRICK_COLORS.get(trick.id, Color.WHITE)
	var k := _tier_scale()
	var centre := table.to_global(Vector3(0.0, table.cloth_y() + _r * 14.0, 0.0))
	_stage.banner(FxStage.ROW_TRICK, TRICK_TITLES.get(trick.id, "TRICK SHOT!"), color, 0.8 + 0.2 * tier)
	_stage.banner(FxStage.ROW_MINOR, "PAYS x%.2f" % trick.multiplier, color.lerp(Color.WHITE, 0.5), 1.0 + 0.1 * tier)
	_stage.confetti(tier, k)
	if _tier() < 2:
		_stage.flash(color, 0.12 + 0.05 * tier, 0.7)
	_label(centre, TRICK_TITLES.get(trick.id, "TRICK SHOT!"), color, 1.2 + 0.2 * tier, 1.8)
	_shake(0.35 + 0.12 * tier)
	_light_kick(centre, color, 2.0 + tier)
	_fire(&"trick", trick.multiplier)


func _on_shot_ended(_id: String, _shooter: int, _points: int, _tricks: Array[StringName], foul: bool) -> void:
	_shot_live = false
	var lost := combo.shot_ended(foul)
	if lost > 0:
		var centre := table.to_global(Vector3(0.0, table.cloth_y() + _r * 6.0, 0.0))
		_stage.banner(FxStage.ROW_MINOR, "STREAK x%d LOST" % lost, Color(0.6, 0.65, 0.8))
		_fizzle(centre, 1.0)
		_fire(&"lost", float(lost))


# ---------------------------------------------------------------- effects

## One impact of `strength` m/s at `pos`; `normal` is the contact normal (ball-ball), the cushion's inward normal (rail) or the kick direction.
func _hit(kind: int, pos: Vector3, normal: Vector3, strength: float) -> void:
	if strength < FxHitTap.MIN_DV or not _frame_ok():
		return
	var t := clampf(strength / HARD_MPS, 0.0, 1.0)
	var k := _tier_scale()
	var up := Vector3.UP
	match kind:
		FxHitTap.Kind.BALL:
			_pop(pos, _r * lerpf(4.0, 10.0, t), Color(1.0, 0.9, 0.55), 0.4)
			_spark(pos, up, lerpf(0.35, 1.0, t) * k, Color(1.0, 0.85, 0.45), 180.0)
			if t > 0.25:
				_light_kick(pos, Color(1.0, 0.9, 0.6), lerpf(0.8, 3.5, t))
			if t > 0.55:
				_word(pos, t)
			_shake(0.05 * t * t)
			_fire(&"ball", strength)
		FxHitTap.Kind.RAIL:
			_pop(pos, _r * lerpf(3.0, 7.0, t), Color(0.55, 0.85, 1.0), 0.32)
			_spark(pos, normal, lerpf(0.25, 0.8, t) * k, Color(0.6, 0.9, 1.0), 55.0)
			if t > 0.7:
				_word(pos, t)
			_shake(0.03 * t)
			_fire(&"rail", strength)
		_:
			_pop(pos, _r * lerpf(3.5, 8.0, t), Color(1.0, 0.6, 0.25), 0.36)
			_spark(pos, normal, lerpf(0.3, 0.9, t) * k, Color(1.0, 0.55, 0.2), 45.0)
			_fire(&"kick", strength)


func _pot(at: Vector3, color: Color, counts: bool) -> void:
	var c := {n = 1, level = 0}
	if counts:
		c = combo.pot()
	var lvl: int = c.level
	var tint: Color = COMBO_COLORS[lvl].lerp(color, 0.35) if lvl > 0 else color.lerp(Color(1.0, 0.85, 0.3), 0.5)
	var k := _tier_scale()
	_pop(at, _r * (9.0 + lvl * 2.0), tint, 0.6)
	_fountain(at, lerpf(0.5, 1.0, minf(lvl / 4.0, 1.0)) * k, tint)
	_light_kick(at, tint, 2.5 + lvl * 0.6)
	_shake(0.12 + 0.05 * lvl)
	var text := "POT!"
	if c.n >= FxCombo.MIN_ANNOUNCE:
		text = "COMBO x%d" % c.n
		_stage.banner(FxStage.ROW_COMBO, text + "!".repeat(mini(lvl >> 1, 3)), COMBO_COLORS[lvl], 0.85 + 0.12 * lvl)
		if _tier() < 2:
			_stage.flash(COMBO_COLORS[lvl], 0.08 + 0.03 * lvl, 0.35)
		if lvl >= 4:
			_stage.confetti(1, k * 0.5)
		_fire(&"combo", float(c.n))
	_label(at + Vector3(0.0, _r * 3.0, 0.0), text, tint, 1.0 + 0.15 * lvl, 1.0)
	_fire(&"pot", float(c.n))


func _scratch(at: Vector3) -> void:
	_fizzle(at, 1.0)
	_label(at + Vector3(0.0, _r * 3.0, 0.0), "SCRATCH...", Color(0.6, 0.65, 0.85), 1.1, 1.2)
	_fire(&"scratch", 0.0)


func _penalty(at: Vector3) -> void:
	_fizzle(at, 1.0)
	_label(at + Vector3(0.0, _r * 3.0, 0.0), "OUCH!", Color(1.0, 0.3, 0.3), 1.2, 1.1)
	_shake(0.1)
	_fire(&"penalty", 0.0)


func _word(pos: Vector3, t: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_label_msec < LABEL_GAP_MSEC:
		return
	_last_label_msec = now
	_label(pos + Vector3(0.0, _r * 2.5, 0.0), WORDS[int(t * 10.0) % WORDS.size()], Color(1.0, 0.95, 0.7), 0.8 + 0.5 * t, 0.6)


## Spawn rate cap per frame and tier: a 40-contact break must not become 40 sprites in one frame.
func _frame_ok() -> bool:
	var f := Engine.get_process_frames()
	if f != _frame_id:
		_frame_id = f
		_frame_hits = 0
	_frame_hits += 1
	return _frame_hits <= TIER_HITS_PER_FRAME[_tier()]


func _tier() -> int:
	return clampi(QualityManager.current_tier, 0, 2)


func _tier_scale() -> float:
	return TIER_SCALE[_tier()]


func _fire(kind: StringName, strength: float) -> void:
	stats[kind] = int(stats.get(kind, 0)) + 1
	fx_fired.emit(kind, strength)


# ---------------------------------------------------------------- pools

func _build_pools() -> void:
	var white_fade := FxPresets.fade_ramp(Color(1.0, 1.0, 1.0), Color(1.0, 0.6, 0.2))
	for i in SPARK_SLOTS:
		_sparks.append(_add(FxPresets.emitter3d(36, 0.55, Vector2(2.0, 6.0), 180.0, 6.0, _r * 0.8, white_fade)))
	for i in FOUNTAIN_SLOTS:
		_fountains.append(_add(FxPresets.emitter3d(120, 1.2, Vector2(3.0, 7.5), 35.0, 8.0, _r * 0.9, white_fade)))
	var grey := FxPresets.fade_ramp(Color(0.75, 0.8, 0.95), Color(0.3, 0.3, 0.4))
	for i in FIZZLE_SLOTS:
		_fizzles.append(_add(FxPresets.emitter3d(28, 1.3, Vector2(0.4, 1.4), 70.0, 2.5, _r * 0.9, grey)))
	for i in POP_SLOTS:
		_pops.append(_add(FxPresets.pop_sprite()))
		_pop_t.append(-1.0)
		_pop_dur.append(1.0)
	for i in LABEL_SLOTS:
		_labels.append(_add(FxPresets.label3d()))
		_label_t.append(-1.0)
		_label_dur.append(1.0)
		_label_y.append(0.0)
	_light = OmniLight3D.new()
	_light.omni_range = _r * 90.0
	_light.shadow_enabled = false
	_light.light_energy = 0.0
	_light.visible = false
	add_child(_light)
	_stage = FxStage.new()
	add_child(_stage)


func _add(n: Node) -> Node:
	add_child(n)
	return n


## Next slot of a pool, round-robin over the share of it this tier may use (fewer live nodes = fewer draw calls).
func _take(kind: StringName, count: int) -> int:
	var i: int = _next[kind]
	_next[kind] = (i + 1) % maxi(1, ceili(count * _tier_scale()))
	return i


## Aims a pooled emitter (+Y along `dir`) at `pos`, tints it and fires it at `ratio` of its amount.
func _launch(p: GPUParticles3D, pos: Vector3, dir: Vector3, ratio: float, color: Color, spread := -1.0) -> void:
	p.global_position = pos
	p.global_basis = Basis(Quaternion(Vector3.UP, dir.normalized() if dir.length() > 0.001 else Vector3.UP))
	var pm := p.process_material as ParticleProcessMaterial
	pm.color = color
	if spread >= 0.0:
		pm.spread = spread
	p.amount_ratio = clampf(ratio, 0.05, 1.0)
	p.restart()


func _spark(pos: Vector3, dir: Vector3, ratio: float, color: Color, spread: float) -> void:
	_launch(_sparks[_take(&"spark", SPARK_SLOTS)], pos, dir, ratio, color, spread)


func _fountain(pos: Vector3, ratio: float, color: Color) -> void:
	var p := _fountains[_take(&"fountain", FOUNTAIN_SLOTS)]
	_launch(p, pos + Vector3(0.0, _r * 1.5, 0.0), Vector3.UP, ratio, color)


func _fizzle(pos: Vector3, ratio: float) -> void:
	var p := _fizzles[_take(&"fizzle", FIZZLE_SLOTS)]
	_launch(p, pos + Vector3(0.0, _r * 1.5, 0.0), Vector3.UP, ratio * _tier_scale(), Color(0.6, 0.65, 0.9))


func _pop(pos: Vector3, size: float, color: Color, sec: float) -> void:
	var i := _take(&"pop", POP_SLOTS)
	var m := _pops[i]
	m.global_position = pos
	m.scale = Vector3.ONE * size
	m.set_instance_shader_parameter(&"tint", color)
	m.set_instance_shader_parameter(&"progress", 0.0)
	m.set_instance_shader_parameter(&"rays", [5.0, 6.0, 8.0][i % 3])
	m.visible = true
	_pop_t[i] = 0.0
	_pop_dur[i] = sec
	set_process(true)


## Floating text that rises and fades over `sec`; `size` scales the base pixel size.
func _label(pos: Vector3, text: String, color: Color, size: float, sec: float) -> void:
	var i := _take(&"label", LABEL_SLOTS)
	var l := _labels[i]
	l.text = text
	l.modulate = color
	l.pixel_size = LABEL_PX * size
	l.global_position = pos
	l.visible = true
	_label_t[i] = 0.0
	_label_dur[i] = sec
	_label_y[i] = pos.y
	set_process(true)


## One shared realtime light (07 §2 budget: 3, one extra on top of the bar's two); tier 2 has none.
func _light_kick(pos: Vector3, color: Color, energy: float) -> void:
	if _tier() >= 2:
		return
	_light.global_position = pos + Vector3(0.0, _r * 5.0, 0.0)
	_light.light_color = color
	_light_energy = maxf(_light_energy, energy)
	_light.light_energy = _light_energy
	_light.visible = true
	set_process(true)


func _shake(amount: float) -> void:
	if amount <= 0.0:
		return
	_trauma = minf(_trauma + amount * (1.0 if _tier() == 0 else 0.5), 1.0)
	set_process(true)


func _pocket_pos(ball: Ball) -> Vector3:
	var best := ball.global_position
	var best_d := INF
	for id in table.pockets:
		var p: Vector3 = table.pockets[id].position
		var d := ball.global_position.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = p
	return Vector3(best.x, table.to_global(Vector3(0.0, table.cloth_y(), 0.0)).y, best.z)


func _process(delta: float) -> void:
	var busy := false
	for i in POP_SLOTS:
		var t := _pop_t[i]
		if t < 0.0:
			continue
		t += delta
		if t >= _pop_dur[i]:
			_pop_t[i] = -1.0
			_pops[i].visible = false
			continue
		_pop_t[i] = t
		_pops[i].set_instance_shader_parameter(&"progress", t / _pop_dur[i])
		busy = true
	for i in LABEL_SLOTS:
		var t := _label_t[i]
		if t < 0.0:
			continue
		t += delta
		if t >= _label_dur[i]:
			_label_t[i] = -1.0
			_labels[i].visible = false
			continue
		_label_t[i] = t
		var u := t / _label_dur[i]
		var l := _labels[i]
		l.global_position.y = _label_y[i] + u * 0.45
		l.modulate.a = 1.0 - smoothstep(0.6, 1.0, u)
		busy = true
	if _light_energy > 0.01:
		_light_energy *= exp(-delta * 9.0)
		_light.light_energy = _light_energy
		busy = true
	elif _light.visible:
		_light_energy = 0.0
		_light.visible = false
	busy = _shake_step(delta) or busy
	if not busy:
		set_process(false)


## Frustum offset on the live camera, decaying trauma squared. True while still moving.
func _shake_step(delta: float) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam != _cam and _cam != null and is_instance_valid(_cam):
		_cam.h_offset = 0.0
		_cam.v_offset = 0.0
	_cam = cam
	if _cam == null:
		return false
	if _trauma <= 0.0:
		_cam.h_offset = 0.0
		_cam.v_offset = 0.0
		return false
	_trauma = maxf(_trauma - delta * 1.6, 0.0)
	var s := _trauma * _trauma * SHAKE_M
	var tm := Time.get_ticks_msec() * 0.001
	_cam.h_offset = s * (sin(tm * 71.0) + 0.6 * sin(tm * 113.0))
	_cam.v_offset = s * (sin(tm * 83.0 + 1.0) + 0.6 * sin(tm * 127.0))
	return true
