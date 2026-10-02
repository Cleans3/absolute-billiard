class_name RoundDirector
extends Node

## Shot/scoring brain of a Round (01 §3–§4): seeded rack, one live Shot at a time, contact log,
## foul + kitchen respawn, tricks, table_cleared. Every foul, respawn and trick is resolved on
## PhysicsSim.all_resting, BEFORE `shot_ended`, so consumers see a finished, legal table.
## Balls are its children; shot_id = "<round_id>-s<n>" counted from 1.

signal rack_ready(seed: int)
signal shot_started(shot_id: String, shooter_id: int)
signal ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)
signal trick_detected(trick: TrickShot, shot_id: String)
signal shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)
signal table_cleared(round_id: String)
## reason: &"scratch" | &"wedged" | &"off_table" — the cue ball was put back in the kitchen.
signal cue_respawned(reason: StringName)
## Host and clients: whose Turn it is (04 §5 `set_shooter`).
signal shooter_changed(peer_id: int)
## Every peer: the shooter's clock started with `seconds` on it (03 `shot_clock_sec`; never emitted at 0).
signal shot_clock_started(seconds: float)

const CUE_TYPE := preload("res://src/resources/ball_types/cue.tres")
## Wire ids for `push_rack`: the index. Append new BallTypes at the end, never reorder.
const BALL_TYPES: Array[BallType] = [
	CUE_TYPE,
	preload("res://src/resources/ball_types/red_basic.tres"),
	preload("res://src/resources/ball_types/blue_mid.tres"),
	preload("res://src/resources/ball_types/gold_prize.tres"),
	preload("res://src/resources/ball_types/black_penalty.tres"),
	preload("res://src/resources/ball_types/stone_ball.tres"),
	preload("res://src/resources/ball_types/bomb_ball.tres"),
	preload("res://src/resources/ball_types/split_ball.tres"),
	preload("res://src/resources/ball_types/joker_ball.tres"),
]
const HOST_ID := 1
const HIGH_VALUE_MULT := 1.25  # 01 §2 `high_value` tag
const BOMB_MIN_IMPACT_MPS := 3.0  # [tune] relative pre-impact speed that sets a bomb_ball off
const BOMB_RADIUS_RADII := 14.0   # [tune] blast radius in ball radii
const BOMB_KICK_MPS := 3.0        # [tune] speed given to a neighbour at zero distance, linear falloff
const RACK_ENTRY_SIZE := 10  # net_id u8 | type u8 | x f32 | z f32 (table-local)
const SHOT_CEILING_SEC := 12.0  # 01 §3: past this every ball is stilled and the shot resolves anyway
const WEDGE_DIRECTIONS := 16
const OFF_TABLE_RADII := 2.0    # past the nose rectangle by this many radii = off the table (A3)

@export var table: Table
@export var ball_scene: PackedScene = preload("res://src/gameplay/balls/Ball.tscn")

var shot_in_progress := false
## Peer whose Turn it is; rotates by NetManager.seat_order() after every shot_ended.
var current_shooter_id := 1
## Shop-bought tier upgrades (EconomyManager.ball_overrides()), installed by GameLoop before start_round.
var ball_overrides: Array[BallTypeOverride] = []
## Seconds left on the shooter's clock; 0 = no clock (03 `shot_clock_sec`). Host counts, clients mirror.
var shot_clock_left := 0.0

var _config: NightConfig
var _fx: Node  # ../EffectManager, duck-typed: probes run without one
var _called_pocket := &""
var _call_rule := false
var _pending_shuffle := 0
var _shuffle_serial := 0
var _pocket_dirty := false
var _next_net_id := 0
var _round_id := ""
var _seed := 0
var _shot_index := 0
var _round_active := false
var _balls: Array[Ball] = []
var _cue_ball: Ball
var _log := ContactLog.new()
var _shot_id := ""
var _shooter_id := 0
var _shot_time := 0.0
var _potted: Array[Ball] = []
var _off_table: Array[Ball] = []  # left the table this shot and not yet put back
var _rest_pos: Dictionary = {}    # Ball -> Vector2 table-local, taken as the shot opens


func _ready() -> void:
	set_physics_process(false)
	set_process(false)
	if not table.is_node_ready():
		await table.ready
	table.sim.shot_started.connect(_on_sim_shot_started)
	table.sim.all_resting.connect(_on_all_resting)
	table.sim.shot_started_net.connect(_on_net_shot_started)
	table.sim.ball_flag_applied.connect(_on_net_flag_applied)
	table.sim.nudged.connect(_on_nudged)
	table.sim.shot_validator = _validate_shot
	table.ball_dropped.connect(_on_ball_dropped)
	_fx = get_node_or_null(^"../EffectManager")
	if _fx != null:
		_fx.effect_applied.connect(_refresh_pocket_stats.unbind(4))
		_fx.effect_expired.connect(_refresh_pocket_stats.unbind(3))
	table.sim.blind_ended.connect(_on_blind_ended)
	var nm := get_node_or_null(^"/root/NetManager")  # absent in `-s` probes
	if nm != null:
		nm.app_resumed.connect(_on_host_resumed)
	var events := get_node_or_null(^"../EventScheduler")
	if events != null:
		events.ball_shuffle_requested.connect(_on_shuffle_requested)


## A strike is legal on the cue ball only, and only between shots.
func can_strike(ball: Ball) -> bool:
	return _round_active and not shot_in_progress and _balls.has(ball) and ball.is_cue_ball


## PhysicsSim.shot_validator: `&""` = ok. Host-side; is the sender the current shooter, is a Round live.
func _validate_shot(peer_id: int, intent: ShotIntent) -> StringName:
	if not _round_active:
		return &"no_round"
	if shot_in_progress:
		return &"balls_moving"
	if peer_id != current_shooter_id:
		return &"not_your_turn"
	if not (intent.power >= 0.0 and intent.power <= 1.001):
		return &"bad_power"
	if not intent.aim_dir.is_finite() or intent.aim_dir.length_squared() < 0.000001:
		return &"bad_aim"
	if _rule_call_pocket(peer_id) and not table.pockets.has(intent.called_pocket):
		return &"call_pocket"  # 03 `rule_call_pocket`: the shot must name a pocket
	return &""


func _rule_call_pocket(peer_id: int) -> bool:
	return _fx != null and _fx.get_stat(&"rule_call_pocket", peer_id, 0.0) > 0.0


## Peer ids by seat; empty when no NetManager session exists (headless probes, tools).
func _seat_order() -> PackedInt32Array:
	var net := get_tree().root.get_node_or_null(^"NetManager")
	return net.call(&"seat_order") if net != null and net.has_method(&"seat_order") else PackedInt32Array()


func _rotate_shooter() -> void:
	var order := _seat_order()
	if order.is_empty():
		return
	var i := order.find(current_shooter_id)
	_set_shooter_rpc.rpc(order[(i + 1) % order.size()])
	_begin_turn()


## Host: a Turn begins — arm the shot clock if 03's `shot_clock_sec` is live for the current shooter.
func _begin_turn() -> void:
	shot_clock_left = 0.0
	if _fx != null:
		shot_clock_left = _fx.get_stat(&"shot_clock_sec", current_shooter_id, 0.0)
	set_process(shot_clock_left > 0.0)
	if shot_clock_left > 0.0:
		_shot_clock_rpc.rpc(shot_clock_left)


@rpc("authority", "call_local", "reliable", 3)
func _shot_clock_rpc(seconds: float) -> void:
	shot_clock_left = seconds
	shot_clock_started.emit(seconds)


## The clock ran out with no strike: a whiff foul (08 §3) — no shot fired, the Shot still costs its
## budget slot and the foul's viewer drop, exactly as GameLoop settles any foul shot_ended.
func _clock_whiff() -> void:
	set_process(false)
	shot_clock_left = 0.0
	_shot_index += 1
	var id := "%s-s%d" % [_round_id, _shot_index]
	var shooter := current_shooter_id
	shot_started.emit(id, shooter)
	if not multiplayer.get_peers().is_empty():
		_shot_resolved_rpc.rpc(id, shooter, Engine.get_physics_frames(), 0, PackedStringArray(), true)
	var no_tricks: Array[StringName] = []
	shot_ended.emit(id, shooter, 0, no_tricks, true)
	_rotate_shooter()


func _process(delta: float) -> void:
	if _round_active and not shot_in_progress and shot_clock_left > 0.0 and multiplayer.is_server():
		shot_clock_left -= delta
		if shot_clock_left <= 0.0:
			_clock_whiff()


@rpc("authority", "call_local", "reliable", 3)
func _set_shooter_rpc(peer_id: int) -> void:
	current_shooter_id = peer_id
	shooter_changed.emit(peer_id)


func get_balls() -> Array[Ball]:
	return _balls.duplicate()


func start_round(config: NightConfig, round_index: int, seed: int) -> void:
	assert(not shot_in_progress, "start_round during a live shot")
	_clear_balls()
	_round_id = "n%d-r%d" % [config.night_number, round_index]
	_seed = seed
	_config = config
	_shot_index = 0
	_pending_shuffle = 0
	_shuffle_serial = 0
	_refresh_pocket_stats()  # geometry for this Round is settled while the table is empty
	var head: Vector3 = table.layout.spots.head
	_cue_ball = _spawn(CUE_TYPE, Vector2(head.x, head.z), 0)
	_next_net_id = 1
	for entry in RackDropper.drop(table.spec, table.layout, config, seed, round_index):
		_spawn(entry.type, entry.pos, _next_net_id)
		_next_net_id += 1
	_round_active = true
	var order := _seat_order()
	if not order.is_empty() and not order.has(current_shooter_id):
		_set_shooter_rpc.rpc(order[0])
	_begin_turn()
	if not multiplayer.get_peers().is_empty():
		_push_rack_rpc.rpc(_round_id, seed, _rack_blob(), table.sim.pocket_time())
	rack_ready.emit(seed)


func _rack_blob() -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(_balls.size() * RACK_ENTRY_SIZE)
	for i in _balls.size():
		var b := _balls[i]
		var p := _local(b)
		var o := i * RACK_ENTRY_SIZE
		blob[o] = b.net_id
		blob[o + 1] = BALL_TYPES.find(b.ball_type)
		blob.encode_float(o + 2, p.x)
		blob.encode_float(o + 6, p.y)
	return blob


## Clients spawn the host's rack as kinematic puppets (PhysicsSim.register flips them to client mode).
@rpc("authority", "call_remote", "reliable", 3)
func _push_rack_rpc(round_id: String, seed: int, blob: PackedByteArray, host_pocket_t: float) -> void:
	table.sim.sync_pocket_clock(host_pocket_t)
	_apply_rack(round_id, seed, blob)
	_round_active = true
	rack_ready.emit(seed)


## Client: rebuild the ball set from a rack blob (also the ball-set half of a full state).
func _apply_rack(round_id: String, seed: int, blob: PackedByteArray) -> void:
	_clear_balls()
	_round_id = round_id
	_seed = seed
	_shot_index = 0
	_next_net_id = 1
	_refresh_pocket_stats()
	for o in range(0, blob.size(), RACK_ENTRY_SIZE):
		var ball := _spawn(BALL_TYPES[blob[o + 1]], Vector2(blob.decode_float(o + 2), blob.decode_float(o + 6)), blob[o])
		_next_net_id = maxi(_next_net_id, blob[o] + 1)
		if ball.is_cue_ball:
			_cue_ball = ball


# ---------------------------------------------------------------- full state (04 §5, §6)

## Client, back from the background: everything the stream carried meanwhile is gone.
func _on_blind_ended() -> void:
	if not multiplayer.is_server():
		_request_full_state_rpc.rpc_id(HOST_ID)


## Host, back from the background: its streams stalled, so every client re-syncs from a snapshot.
func _on_host_resumed() -> void:
	if multiplayer.is_server():
		for id in multiplayer.get_peers():
			send_full_state(id)


@rpc("any_peer", "call_remote", "reliable", 3)
func _request_full_state_rpc() -> void:
	if multiplayer.is_server():
		send_full_state(multiplayer.get_remote_sender_id())


## Host: one peer gets the rack blob + a ball-state frame (the same encoders as the live stream) plus the
## Round scalars, then whatever the sibling managers mirror (Round state, Cash, live Effects).
func send_full_state(peer_id: int) -> void:
	if _round_id == "":
		return
	_full_state_rpc.rpc_id(peer_id, _round_id, _seed, _shot_index, current_shooter_id, _round_active, shot_in_progress, shot_clock_left, _rack_blob(), table.sim.snapshot_frame(), table.sim.pocket_time())
	for n in [&"../GameLoop", &"../EconomyManager", &"../EffectManager"]:
		var node := get_node_or_null(NodePath(n))
		if node != null and node.has_method(&"resync_peer"):
			node.call(&"resync_peer", peer_id)


@rpc("authority", "call_remote", "reliable", 3)
func _full_state_rpc(round_id: String, seed: int, shot_index: int, shooter_id: int, active: bool, live: bool, clock_left: float, blob: PackedByteArray, frame: PackedByteArray, host_pocket_t: float) -> void:
	_apply_rack(round_id, seed, blob)
	_shot_index = shot_index
	_shot_id = "%s-s%d" % [round_id, shot_index] if shot_index > 0 else ""
	_round_active = active
	shot_in_progress = live
	shot_clock_left = clock_left
	table.sim.apply_snapshot(frame, host_pocket_t)
	if current_shooter_id != shooter_id:
		current_shooter_id = shooter_id
		shooter_changed.emit(shooter_id)


## Freezes the table where it stands (visible through Intermission); start_round clears it.
func end_round() -> void:
	assert(not shot_in_progress, "end_round during a live shot")
	_round_active = false
	for b in _balls:
		b.freeze = true


## True when the resting cue ball cannot move in any of 16 sampled directions (01 §3).
func is_cue_wedged() -> bool:
	if _cue_ball == null or _cue_ball.is_pocketed:
		return false
	var step := table.spec.clearance_margin_m
	for i in WEDGE_DIRECTIONS:
		var motion := Vector3.RIGHT.rotated(Vector3.UP, TAU * i / WEDGE_DIRECTIONS) * step
		if not _cue_ball.test_move(_cue_ball.global_transform, motion):
			return false
	return true


func _physics_process(delta: float) -> void:
	_shot_time += delta
	_retire_off_table()
	if _shot_time > SHOT_CEILING_SEC:
		for b in _balls:
			b.linear_velocity = Vector3.ZERO  # Ball._integrate_forces snaps a still ball to rest
			b.angular_velocity = Vector3.ZERO


func _spawn(type: BallType, pos: Vector2, index: int) -> Ball:
	var b: Ball = ball_scene.instantiate()
	b.ball_type = type
	b.spec = table.spec
	b.spawn_index = index
	b.net_id = index  # wire id: cue 0, rack balls 1.. in spawn order, identical on every peer
	b.id = "%s_%d" % [type.id, index]
	add_child(b)
	b.global_position = _world(pos, b)
	table.sim.register(b)
	b.contacted.connect(_on_contacted)
	_balls.append(b)
	return b


func _clear_balls() -> void:
	for b in _balls:
		remove_child(b)  # out of the tree now, so PhysicsSim forgets it this frame
		b.queue_free()
	_balls.clear()
	_cue_ball = null
	_potted.clear()
	_off_table.clear()


func _world(p: Vector2, ball: Ball) -> Vector3:
	return table.to_global(Vector3(p.x, table.cloth_y() + ball.radius + table.spec.clearance_margin_m, p.y))


func _local(ball: Ball) -> Vector2:
	var p := table.to_local(ball.global_position)
	return Vector2(p.x, p.z)


func _on_sim_shot_started(_ball: Ball, intent: ShotIntent) -> void:
	if shot_in_progress or not _round_active:
		return  # a strike that got past the gate opens no second shot
	shot_in_progress = true
	_shot_index += 1
	_shot_id = "%s-s%d" % [_round_id, _shot_index]
	_shooter_id = intent.shooter_id
	_called_pocket = intent.called_pocket
	_call_rule = _rule_call_pocket(_shooter_id)
	shot_clock_left = 0.0
	set_process(false)
	_shot_time = 0.0
	_log.clear()
	_potted.clear()
	_off_table.clear()
	_rest_pos.clear()
	for b in _balls:
		if not b.is_pocketed:
			_rest_pos[b] = _local(b)
	set_physics_process(true)
	shot_started.emit(_shot_id, _shooter_id)


## Clients: the network-level shot start (host already ran `_on_sim_shot_started`).
func _on_net_shot_started(_id: int, shooter_id: int, _base_tick: int) -> void:
	if multiplayer.is_server():
		return
	shot_in_progress = true
	_shot_index += 1
	_shot_id = "%s-s%d" % [_round_id, _shot_index]
	shot_started.emit(_shot_id, shooter_id)


## Clients: a streamed pot lands at playback time, so the popup follows the ball into the pocket.
func _on_net_flag_applied(ball: Ball, flag: int) -> void:
	if flag != BallEventCodec.Flag.POCKETED or ball.is_cue_ball:
		return
	var best := &""
	var best_d := INF
	for id in table.pockets:
		var d := ball.global_position.distance_squared_to(table.to_global(table.pockets[id].position))
		if d < best_d:
			best_d = d
			best = id
	ball_potted.emit(ball, _shot_id, best)


@rpc("authority", "call_remote", "reliable", 3)
func _shot_resolved_rpc(shot_id: String, shooter_id: int, end_tick: int, raw_points: int, trick_ids: PackedStringArray, foul: bool) -> void:
	var ids: Array[StringName] = []
	for t in trick_ids:
		ids.append(StringName(t))
	table.sim.at_playback(end_tick, func() -> void:
		for id in ids:  # rebuilt from the id: multiplier and tags are pure functions of it
			trick_detected.emit(TrickShot.make(id, shot_id), shot_id)
		shot_in_progress = false
		shot_ended.emit(shot_id, shooter_id, raw_points, ids, foul))


func _on_nudged(_direction: Vector2, _strength: float, source_peer_id: int) -> void:
	if shot_in_progress:
		_log.add_nudge(source_peer_id)


func _on_contacted(ball: Ball, other: Node, kind: StringName) -> void:
	if not shot_in_progress:
		return
	if other is Ball:
		_maybe_detonate(ball, other)
	if kind == ContactLog.RAIL:
		_log.add_rail(ball, other.get_meta(&"rail_id", &""))
	elif other is Ball:
		_log.add_ball(ball, other)


func _on_ball_dropped(ball: Ball, pocket_id: StringName) -> void:
	if not shot_in_progress or not _balls.has(ball):
		return
	_log.add_pocket(ball, pocket_id)
	if not ball.is_cue_ball:
		_potted.append(ball)
		ball_potted.emit(ball, _shot_id, pocket_id)


func _is_off_table(ball: Ball) -> bool:
	var s := table.spec
	var p := table.to_local(ball.global_position)
	var margin := OFF_TABLE_RADII * s.ball_radius_m
	return absf(p.x) > s.length_m * 0.5 + margin \
		or absf(p.z) > s.width_m * 0.5 + margin \
		or p.y < table.cloth_y() - s.ball_radius_m


## Out-of-bounds balls are logged and retired the moment they leave, so the shot can settle.
func _retire_off_table() -> void:
	for b in _balls:
		if not b.is_pocketed and not _off_table.has(b) and _is_off_table(b):
			_off_table.append(b)
			_log.add_off_table(b)
			b.retire()


func _on_all_resting() -> void:
	if not shot_in_progress:
		return
	_retire_off_table()
	var scratched := false
	var whiffed := true
	for e in _log.entries:
		if e.kind == ContactLog.POCKET and e.a == _cue_ball:
			scratched = true
		elif e.kind == ContactLog.BALL and e.a == _cue_ball:
			whiffed = false
	var foul := whiffed or scratched or not _off_table.is_empty()

	var cue_reason := &"scratch" if scratched else &""
	for b in _off_table.duplicate():
		if b.is_cue_ball:
			cue_reason = &"off_table"
		else:
			_respawn_object(b)
	if cue_reason == &"" and is_cue_wedged():
		cue_reason = &"wedged"  # no foul, no shot cost — just freed
	if cue_reason != &"":
		_respawn_cue(cue_reason)

	var raw_points := 0
	var trick_ids: Array[StringName] = []
	if not foul:
		raw_points = raw_points_for(_scoring_pots())
		for t in TrickDetector.detect(_log, _cue_ball, _shot_id):
			trick_ids.append(t.id)
			trick_detected.emit(t, _shot_id)

	_spawn_splits()
	var cleared := is_table_cleared()
	var round_id := _round_id
	var shot_id := _shot_id
	var shooter_id := _shooter_id
	shot_in_progress = false
	set_physics_process(false)
	if not multiplayer.get_peers().is_empty():
		_shot_resolved_rpc.rpc(shot_id, shooter_id, Engine.get_physics_frames(), raw_points, PackedStringArray(trick_ids), foul)
	shot_ended.emit(shot_id, shooter_id, raw_points, trick_ids, foul)
	if cleared:
		table_cleared.emit(round_id)
	_rotate_shooter()
	_after_shot()


## No ball that counts for clear and is worth points is still on the table (01 §3).
func is_table_cleared() -> bool:
	for b in _balls:
		if b.ball_type.counts_for_clear and b.ball_type.base_value > 0 and not b.is_pocketed and not b.retired:
			return false
	return true


## Table-local positions of every ball still on the cloth except `skip`.
func _positions_except(skip: Ball) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for b in _balls:
		if b != skip and not b.is_pocketed and not _off_table.has(b):
			out.append(_local(b))
	return out


func _respawn_seed(ball: Ball) -> int:
	return hash([_seed, _shot_index, ball.spawn_index])


## Back at its last resting spot, or the nearest clear one if another ball has settled there.
func _respawn_object(ball: Ball) -> void:
	var spot := RackDropper.place_near(table.spec, table.layout, _rest_pos[ball], RackDropper.interior(table.spec), _positions_except(ball), _respawn_seed(ball))
	_off_table.erase(ball)
	ball.restore(_world(spot, ball))


func _respawn_cue(reason: StringName) -> void:
	var head: Vector3 = table.layout.spots.head
	var spot := RackDropper.place_near(table.spec, table.layout, Vector2(head.x, head.z), RackDropper.kitchen(table.spec), _positions_except(_cue_ball), _respawn_seed(_cue_ball))
	_off_table.erase(_cue_ball)
	_cue_ball.restore(_world(spot, _cue_ball))
	cue_respawned.emit(reason)


# ---------------------------------------------------------------- rules: value, score, gimmicks (01 §2)

## `value(ball_type)`: a shop override replaces the resource's `base_value`; nothing mutates the resource.
func value_of(type: BallType) -> int:
	for o in ball_overrides:
		if String(o.id) == type.id:
			return o.base_value
	return type.base_value


## Σ value over `potted`: `high_value` +25 %, `wild` (joker) doubles the single best ball of the Shot,
## penalties stay negative in the sum. Trick multipliers are 02's and disjoint from this.
func raw_points_for(potted: Array[Ball]) -> int:
	var total := 0.0
	var best := 0.0
	var wild := false
	for b in potted:
		var v := float(value_of(b.ball_type))
		if b.ball_type.behaviour_tags.has(&"high_value"):
			v *= HIGH_VALUE_MULT
		wild = wild or b.ball_type.behaviour_tags.has(&"wild")
		total += v
		best = maxf(best, v)
	if wild:
		total += best
	return roundi(total)


## With `rule_call_pocket` live, a pot elsewhere than the called pocket scores 0 — never a foul.
func _scoring_pots() -> Array[Ball]:
	if not _call_rule:
		return _potted
	return _potted.filter(func(b: Ball) -> bool: return b.pocketed_in == _called_pocket)


var _detonating: Array[Ball] = []


## A bomb_ball struck at ≥ BOMB_MIN_IMPACT_MPS (relative, pre-solve) scatters its neighbours and removes
## only itself (06 P8). Host only: clients never see contacts, they see the retire + the scattered balls.
func _maybe_detonate(a: Ball, b: Ball) -> void:
	if (a.pre_solve_velocity - b.pre_solve_velocity).length() < BOMB_MIN_IMPACT_MPS:
		return
	for bomb in [a, b]:
		if bomb.ball_type.behaviour_tags.has(&"volatile") and not bomb.retired and not _detonating.has(bomb):
			_detonating.append(bomb)
			_detonate.call_deferred(bomb)


func _detonate(bomb: Ball) -> void:
	_detonating.erase(bomb)
	if bomb.retired or bomb.is_pocketed or not shot_in_progress:
		return
	var reach := BOMB_RADIUS_RADII * bomb.radius
	for b in _balls:
		if b == bomb or b.retired or b.is_pocketed:
			continue
		var d := b.global_position - bomb.global_position
		d.y = 0.0
		var dist := d.length()
		if dist >= reach:
			continue
		var dir := d / dist if dist > 0.0001 else Vector3.RIGHT
		b.wake()
		b.apply_central_impulse(dir * BOMB_KICK_MPS * (1.0 - dist / reach) * b.mass)
	var spawner := get_tree().get_first_node_in_group(&"player_spawner")  # by group: a -s probe compiles this before the autoloads exist
	if spawner != null:  # players near the blast go limp (06 P15)
		spawner.call(&"knock_blast", bomb.global_position)
	bomb.retire()


## One red_basic per potted split_ball at its last rest spot (or the nearest clear one), 12-ball cap.
## Returns how many were spawned. Clients spawn them at playback of the Shot's end.
func _spawn_splits() -> int:
	var n := 0
	for b in _potted.duplicate():
		if not b.ball_type.behaviour_tags.has(&"splitter") or _next_net_id >= BallEventCodec.MAX_BALLS or _live_object_count() >= RackDropper.MAX_OBJECT_BALLS:
			continue
		var spot := RackDropper.place_near(table.spec, table.layout, _rest_pos.get(b, Vector2.ZERO), RackDropper.interior(table.spec), _positions_except(null), hash([_seed, _shot_index, b.spawn_index]))
		var nb := _spawn(BALL_TYPES[1], spot, _next_net_id)
		_next_net_id += 1
		n += 1
		if not multiplayer.get_peers().is_empty():
			_spawn_rpc.rpc(nb.net_id, 1, spot.x, spot.y, table.sim.after_shot_tick())
	return n


func _live_object_count() -> int:
	var n := 0
	for b in _balls:
		if not b.is_cue_ball and not b.retired:
			n += 1
	return n


@rpc("authority", "call_remote", "reliable", 3)
func _spawn_rpc(net_id: int, type_idx: int, x: float, z: float, tick: int) -> void:
	table.sim.at_playback(tick, func() -> void:
		_spawn(BALL_TYPES[type_idx], Vector2(x, z), net_id)
		_next_net_id = maxi(_next_net_id, net_id + 1))


func _on_shuffle_requested(count: int) -> void:
	if not multiplayer.is_server() or count <= 0 or not _round_active:
		return
	if shot_in_progress:
		_pending_shuffle += count  # never swap a ball under a live Shot
	else:
		_shuffle(count)


## 03 `ball_type_shuffle_count`: re-roll that many object balls' types in place (same spot), seeded from
## the Round, and tell the clients which id became what.
func _shuffle(count: int) -> void:
	var candidates: Array[Ball] = []
	for b in _balls:
		if not b.is_cue_ball and not b.retired and not b.is_pocketed and not b.ball_type.behaviour_tags.has(&"obstacle"):
			candidates.append(b)
	var pool := RackDropper.reroll_pool(_config)
	if pool.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([_seed, _shot_index, _shuffle_serial])
	_shuffle_serial += 1
	for i in mini(count, candidates.size()):
		var b: Ball = candidates.pop_at(rng.randi_range(0, candidates.size() - 1))
		var t: BallType = pool[rng.randi() % pool.size()]
		var nb := _replace_ball(b, t)
		if not multiplayer.get_peers().is_empty():
			_reroll_rpc.rpc(nb.net_id, BALL_TYPES.find(t), table.sim.after_shot_tick())


func _replace_ball(old: Ball, type: BallType) -> Ball:
	var pos := _local(old)
	var index := old.spawn_index
	_balls.erase(old)
	remove_child(old)
	old.queue_free()
	return _spawn(type, pos, index)


@rpc("authority", "call_remote", "reliable", 3)
func _reroll_rpc(net_id: int, type_idx: int, tick: int) -> void:
	table.sim.at_playback(tick, func() -> void:
		for b in _balls:
			if b.net_id == net_id:
				_replace_ball(b, BALL_TYPES[type_idx])
				return)


## Host, after a Shot fully resolved: work that must not run under a live Shot.
func _after_shot() -> void:
	if _pocket_dirty:
		_refresh_pocket_stats()
	if _pending_shuffle > 0:
		var n := _pending_shuffle
		_pending_shuffle = 0
		_shuffle(n)


## 03 `pocket_radius_mult` / `pocket_oscillation_m` -> Table. Every peer resolves them from the same
## synced Effects, the phase comes from the Round seed: no pocket packets. Deferred past a live Shot.
func _refresh_pocket_stats() -> void:
	if _fx == null or table == null:
		return
	if shot_in_progress:
		_pocket_dirty = true
		return
	_pocket_dirty = false
	table.apply_pocket_stats(_fx.get_stat(&"pocket_radius_mult", EffectManager.ALL_PEERS, 1.0), _fx.get_stat(&"pocket_oscillation_m", EffectManager.ALL_PEERS, 0.0), _seed)
