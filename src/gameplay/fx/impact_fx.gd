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
const HARD_MPS := 8.0  # impact speed that maxes every hit scale (a full break hits at up to 20 m/s: past 8 every hit is full size)
const TIER_SCALE := [1.0, 0.6, 0.35]
const TIER_HITS_PER_FRAME := [6, 4, 2]
const WORDS := ["CLACK!", "CRACK!", "WHAM!", "SMACK!"]
const LABEL_GAP_MSEC := 160
const EVENT_COLORS: Array[Color] = [Color(1.0, 0.62, 0.2), Color(1.0, 0.25, 0.65)]  # hazard tier 1, tier 2+
const GO_COLOR := Color(0.55, 1.0, 0.6)
const FLAME_COLOR := Color(1.0, 0.38, 0.08)
const POP_REF_M := 2.0  # a pop this far from the camera is drawn at its table size; farther ones grow so the far end of the table still reads
const POP_FAR_MAX := 2.6
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
var _effects: EffectManager
var _sched: EventScheduler
var _beacon: MeshInstance3D  # the Pocket Jackpot's pocket: a pulsing ring and "x3" for the whole Round
var _beacon_label: Label3D
var _beacon_tween: Tween
var _beacon_at := Vector3.INF
var _flames := false  # the `flames` visual hook (Flaming Shot, 03 §3.8) is live: every hit throws embers
var _drinks_seen := {}  # "peer:drink:gift" -> true, so a refreshed Drink does not announce twice
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
	_connect_beats()
	set_process(false)


## The beats the game itself has: a hazard starting, a Drink going down, GO, a cleared table. Siblings found by path (a probe
## harness has none of them); every peer gets the same signals (EventScheduler.apply_event is call_local, the Effects are mirrored).
func _connect_beats() -> void:
	_sched = get_node_or_null(^"../EventScheduler") as EventScheduler
	if _sched != null:
		_sched.event_applied.connect(_on_event_applied)
	_effects = get_node_or_null(^"../EffectManager") as EffectManager
	if _effects != null:
		_effects.live_changed.connect(_on_live_changed)
		_effects.visual_hook_started.connect(func(tag: StringName) -> void: _flames = _flames or tag == &"flames")
		_effects.visual_hook_stopped.connect(func(tag: StringName) -> void: _flames = _flames and tag != &"flames")
	var loop := get_node_or_null(^"../GameLoop") as GameLoop
	if loop != null:
		loop.round_started.connect(_on_round_started)
		loop.round_ended.connect(_on_round_ended)


func _on_event_applied(event_id: StringName, tier: int, mult: float) -> void:
	var e := FxCatalog.event(event_id)
	if e == null:
		return
	var color := EVENT_COLORS[clampi(tier, 1, EVENT_COLORS.size()) - 1]
	var line := "NEW RULES"
	match e.opportunity:
		Event.Opportunity.NEXT_POT:
			line = "NEXT POT PAYS x%d" % roundi(e.opportunity_mult)
		Event.Opportunity.RANDOM_POCKET:
			line = "ONE POCKET PAYS x%d" % roundi(e.opportunity_mult)
		_:
			if absf(mult - 1.0) > 0.001:
				line = "PAYS x%.2f" % mult
	_stage.banner(FxStage.ROW_TRICK, e.display_name.to_upper() + "!", color, 0.9)
	_stage.banner(FxStage.ROW_MINOR, "HAZARD  -  " + line, color.lerp(Color.WHITE, 0.5), 1.0)
	if _tier() < 2:
		_stage.flash(color, 0.3, 0.8)
	_shake(0.45)
	if e.opportunity == Event.Opportunity.RANDOM_POCKET and _sched != null:
		_show_beacon(_sched.active_pocket, e.opportunity_mult)
	_fire(&"hazard", mult)


## The paying pocket of a Pocket Jackpot, marked on the table until the Round ends (it was announced nowhere: the crew could not see it).
func _show_beacon(pocket_id: StringName, mult: float) -> void:
	if not table.pockets.has(pocket_id):
		return
	var p: Vector3 = table.pockets[pocket_id].position
	_beacon_at = Vector3(p.x, table.to_global(Vector3(0.0, table.cloth_y(), 0.0)).y + _r * 1.5, p.z)
	_beacon.global_position = _beacon_at
	_beacon.scale = Vector3.ONE * _r * 16.0
	_beacon.set_instance_shader_parameter(&"tint", Color(1.0, 0.82, 0.2))
	_beacon.set_instance_shader_parameter(&"rays", 8.0)
	_beacon.visible = true
	_beacon_label.text = "x%d" % roundi(mult)
	_beacon_label.modulate = Color(1.0, 0.85, 0.25)
	_beacon_label.pixel_size = LABEL_PX * 1.7
	_beacon_label.global_position = _beacon_at + Vector3(0.0, _r * 4.0, 0.0)
	_beacon_label.visible = true
	if _beacon_tween != null:
		_beacon_tween.kill()
	_beacon_tween = create_tween().set_loops()
	_beacon_tween.tween_method(func(v: float) -> void: _beacon.set_instance_shader_parameter(&"progress", v), 0.0, 1.0, 1.2)


func _hide_beacon() -> void:
	if _beacon_tween != null:
		_beacon_tween.kill()
		_beacon_tween = null
	_beacon.visible = false
	_beacon_label.visible = false
	_beacon_at = Vector3.INF


## A Drink that just landed on this peer (bought, a gift, a slot win, the house): its name, in its tier's colour.
func _on_live_changed() -> void:
	var local := multiplayer.get_unique_id()
	var now := {}
	for r in _effects.live_drinks():
		var key := "%d:%s:%s" % [r.peer_id, r.drink.id, r.gift]
		now[key] = true
		if not _drinks_seen.has(key) and r.peer_id == local:
			_drink_banner(r.drink)
	_drinks_seen = now


func _drink_banner(d: Drink) -> void:
	var color := DrinkTier.colour(d.tier)
	_stage.banner(FxStage.ROW_MINOR, d.display_name.to_upper() + "!", color, 1.1)
	if _tier() < 2:
		_stage.flash(color, 0.14, 0.4)
	_fire(&"drink", float(d.tier))


func _on_round_started(round_index: int, _time: float, _hazard_tier: int) -> void:
	_stage.banner(FxStage.ROW_COMBO, "ROUND %d - GO!" % round_index, GO_COLOR, 1.0)
	if _tier() < 2:
		_stage.flash(GO_COLOR, 0.12, 0.5)
	_fire(&"go", float(round_index))


func _on_round_ended(reason: StringName, _points: int) -> void:
	_hide_beacon()
	match reason:
		&"cleared":
			var k := _tier_scale()
			_stage.banner(FxStage.ROW_TRICK, "TABLE CLEARED!", Color(1.0, 0.85, 0.2), 1.1)
			_stage.confetti(3, k)
			if _tier() < 2:
				_stage.flash(Color(1.0, 0.85, 0.2), 0.3, 0.8)
			_shake(0.6)
			_fire(&"cleared", 1.0)
		&"timer":
			_stage.banner(FxStage.ROW_COMBO, "TIME!", Color(1.0, 0.45, 0.35), 1.0)
			_fire(&"time", 0.0)
		_:
			_stage.banner(FxStage.ROW_COMBO, "ROUND OVER", Color(0.75, 0.8, 0.95), 0.8)
			_fire(&"time", 1.0)


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
	_hit(FxHitTap.Kind.KICK, ball.global_position, Vector3(aim.x, 0.0, aim.y), _sim.active_cue.speed_at(clampf(intent.power, 0.0, 1.0)))


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
	if combo.shot_pots == 0:  # a trick on a Shot that potted nothing pays nothing: a word, not a show
		var title: String = TRICK_TITLES.get(trick.id, "TRICK SHOT!")
		_stage.banner(FxStage.ROW_MINOR, title, color.lerp(Color.WHITE, 0.35), 0.9)
		_label(centre, title, color, 1.0, 1.3)
		_fire(&"trick_minor", trick.multiplier)
		return
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
	if _flames and t > 0.15:  # Flaming Shot: a second, fiery pop and a fountain of embers on every real hit
		_pop(pos, _r * lerpf(5.0, 12.0, t), FLAME_COLOR, 0.5)
		_fountain(pos, lerpf(0.4, 0.9, t) * k, FLAME_COLOR)
		_light_kick(pos, FLAME_COLOR, lerpf(1.0, 3.0, t))
		_fire(&"flames", strength)
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
	if _beacon_at.is_finite() and Vector2(at.x, at.z).distance_to(Vector2(_beacon_at.x, _beacon_at.z)) < _r * 3.0:
		text = "JACKPOT!"
		_stage.confetti(1, k * 0.6)
		_shake(0.3)
		_fire(&"jackpot", 1.0)
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


## 1 up close, up to POP_FAR_MAX at the far end of the table: the camera stands at the near rail, a pop in metres shrinks to a speck there.
func _far_scale(pos: Vector3) -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return 1.0
	return clampf(cam.global_position.distance_to(pos) / POP_REF_M, 1.0, POP_FAR_MAX)


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
	_beacon = _add(FxPresets.pop_sprite())
	_beacon.visible = false
	_beacon_label = _add(FxPresets.label3d())
	_beacon_label.visible = false
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
	m.scale = Vector3.ONE * size * _far_scale(pos)
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
