class_name PhysicsSim
extends Node

## Live-shot bookkeeping (07 §1.3–1.4, §7.2): awake-ball count via sleep signals, contact
## monitoring only during a Shot, physics tick 120 Hz live / 60 Hz at rest. Modifier stack comes later.

signal shot_started(ball: Ball, intent: ShotIntent)
signal all_resting
## Every peer, host included (04 §5 `shot_started` RPC): the network-level start of a Shot.
signal shot_started_net(shot_id: int, shooter_id: int, base_tick: int)
signal shot_rejected(reason: StringName)
## Host: a nudge was applied (RoundDirector logs it as a NUDGE ContactLog entry, 01 §3).
signal nudged(direction: Vector2, strength: float, source_peer_id: int)
## Host: a frame of ball events / heartbeat was flushed (also emitted with no peers when `capture`).
signal frame_flushed(frame: PackedByteArray)
signal heartbeat_flushed(frame: PackedByteArray)

const LIVE_TICK := 120
const REST_TICK := 60

const NUDGE_IMPULSE := 0.06  # N·s per unit strength [tune] (01 §3)
const DIVERGE_M := 0.002  # host re-sends a ball once its model drifts this far from Jolt [tune]
const FLUSH_HZ := 30
const HEARTBEAT_HZ := 2
const HEARTBEAT_SNAP_M := 0.006  # client adopts a heartbeat state only when this far off
const INTERP_DELAY_SEC := 0.1  # client renders this far behind the host (04 §2.4)

## Installed by EffectManager: (stat: StringName, peer_id: int, base: float) -> float. Default = base.
var stat_source: Callable
## Installed by RoundDirector: (peer_id: int, intent: ShotIntent) -> StringName, `&""` = ok else reason.
var shot_validator: Callable

# Resolved table/ball stats, pushed host-side by EffectManager via set_stat. Timers live there, not here.
var cue_ball_mass_mult := 1.0
var cloth_friction_mult := 1.0
var cushion_restitution_mult := 1.0
var table_tilt_deg := 0.0
var tilt_direction := Vector2.ZERO

## Host emits frames for peers; set true by tools (SimDiff) that want them with no peers connected.
var capture := false
@export var cue_spec: CueSpec = preload("res://src/resources/cues/demo_cue.tres")

var awake := 0
var _balls: Array[Ball] = []
var _by_id: Array[Ball] = []
var shot_id := 0
var _shot_live := false
var _base_tick := 0
var _pred: Array[BallMotion.State] = []  # host: state the clients will have reconstructed
var _dirty := PackedByteArray()
var _frame := PackedByteArray()
var _hb := PackedByteArray()
var _scratch := BallMotion.State.new()
var _hb_state := BallMotion.State.new()
var _flush_every := maxi(1, LIVE_TICK / FLUSH_HZ)
var _hb_every := LIVE_TICK / HEARTBEAT_HZ
var _emitted_events := 0
# client
var _replica := BallReplica.new()
var _t0_usec := 0
var _client_base := 0
var _waiting: Array = []  # [tick, Callable], oldest first
var _rail_mult: Dictionary = {}  # rail_id -> float, absent = 1.0


## Resolved value of a per-shot stat (`cue_power_mult`, `cue_spin_radius_mult`) for `peer_id`.
func stat(stat_name: StringName, peer_id: int, base: float) -> float:
	return stat_source.call(stat_name, peer_id, base) if stat_source.is_valid() else base


func set_stat(stat_name: StringName, value: float) -> void:
	match stat_name:
		&"cue_ball_mass_mult":
			cue_ball_mass_mult = value
			for b in _balls:
				if b.is_cue_ball:
					b.apply_mass_mult(value)
		&"cloth_friction_mult":
			cloth_friction_mult = value
			for b in _balls:
				b.motion.friction_mult = value
			_scale_bed_friction(value)
		&"cushion_restitution_mult": cushion_restitution_mult = value
		&"table_tilt_deg": table_tilt_deg = value
		_: push_error("PhysicsSim.set_stat: unknown stat %s" % stat_name)


func set_tilt_direction(dir: Vector2) -> void:
	tilt_direction = dir.normalized()


func set_rail_restitution_mult(rail_id: StringName, mult: float) -> void:
	_rail_mult[rail_id] = mult


func rail_restitution_mult(rail_id: StringName) -> float:
	return cushion_restitution_mult * float(_rail_mult.get(rail_id, 1.0))


## Central impulse to every non-resting ball (01 §3). Host-only.
func nudge(direction: Vector2, strength: float, source_peer_id: int) -> void:
	var j := Vector3(direction.x, 0.0, direction.y).normalized() * strength * NUDGE_IMPULSE
	for b in _balls:
		if not b.is_resting and not b.freeze:
			b.apply_central_impulse(j)
	nudged.emit(direction, strength, source_peer_id)


## Ball–cloth contact friction is the bed body's material (Jolt), on top of the rolling-resistance term.
func _scale_bed_friction(mult: float) -> void:
	var table := get_parent() as Table
	var bed := table.get_node_or_null("Bed") as StaticBody3D if table != null else null
	if bed != null:
		bed.physics_material_override.friction = table.spec.cloth_friction * mult


func _ready() -> void:
	Performance.add_custom_monitor("Game/AwakeBalls", _get_awake)
	Engine.physics_ticks_per_second = REST_TICK
	set_physics_process(false)
	set_process(false)
	_frame.resize(BallEventCodec.HEADER_SIZE)


func _exit_tree() -> void:
	Performance.remove_custom_monitor("Game/AwakeBalls")  # a dangling monitor callable corrupts the heap at quit


func _get_awake() -> int:
	return awake


func get_balls() -> Array[Ball]:
	return _balls.duplicate()


func register(ball: Ball) -> void:
	_balls.append(ball)
	ball.sim = self
	if ball.is_cue_ball:
		ball.apply_mass_mult(cue_ball_mass_mult)
	if ball.net_id < 0:  # tools/tests; RoundDirector assigns explicit ids so every peer agrees
		ball.net_id = _by_id.find(null)
		if ball.net_id < 0:
			ball.net_id = _by_id.size()
	assert(ball.net_id < BallEventCodec.MAX_BALLS, "Ball.net_id must be < 64")
	ball.motion = BallMotion.make_params(ball.spec, ball.radius)
	ball.motion.friction_mult = cloth_friction_mult
	while _by_id.size() <= ball.net_id:
		_by_id.append(null)
		_pred.append(BallMotion.State.new())
		_dirty.append(0)
	_by_id[ball.net_id] = ball
	ball.net_flag.connect(_on_net_flag)
	ball.contacted.connect(_on_ball_contact)
	if not _is_host():
		ball.set_client_mode()
		set_process(true)
		_anchor_now(ball)
	ball.contact_monitor = false
	ball.struck.connect(_on_struck)
	ball.resting_changed.connect(_recount.unbind(2))
	ball.tree_exiting.connect(func() -> void:
		_balls.erase(ball)
		if ball.net_id < _by_id.size() and _by_id[ball.net_id] == ball:
			_by_id[ball.net_id] = null
		_recount())
	_recount()


func _on_struck(ball: Ball, intent: ShotIntent) -> void:
	for b in _balls:
		b.contact_monitor = true
	Engine.physics_ticks_per_second = LIVE_TICK
	_begin_shot_stream(intent.shooter_id)
	shot_started.emit(ball, intent)
	# Struck ball's own is_resting already flipped false synchronously (Ball.strike, before this
	# signal fires) — recount now instead of waiting on the deferred resting_changed so `awake`
	# reflects the shot on the same frame it starts, not a lagging frame behind (gamma F3a).
	_recount()


func _recount() -> void:
	var n := 0
	for b in _balls:
		if not b.is_resting and not b.freeze and b.is_inside_tree():
			n += 1
	var was := awake
	awake = n
	if n == 0 and was > 0:
		for b in _balls:
			if b.is_inside_tree():
				b.contact_monitor = false
		_end_shot_stream()
		Engine.physics_ticks_per_second = REST_TICK  # only ever changed at rest (07 §7.2)
		all_resting.emit()


# ---------------------------------------------------------------- shot request (04 §5)

func _is_host() -> bool:
	return multiplayer.is_server()


func origin() -> Vector3:
	return (get_parent() as Node3D).global_position


## Any peer: ask the host to strike the cue ball. Solo = host = direct call.
func request_shot(intent: ShotIntent) -> void:
	if _is_host():
		_host_shot(multiplayer.get_unique_id(), intent)
		return
	var b := PackedByteArray()
	b.resize(24)
	b.encode_float(0, intent.aim_dir.x)
	b.encode_float(4, intent.aim_dir.y)
	b.encode_float(8, intent.power)
	b.encode_float(12, intent.spin_offset.x)
	b.encode_float(16, intent.spin_offset.y)
	b.encode_float(20, intent.elevation_deg)
	_request_shot_rpc.rpc_id(1, b)


@rpc("any_peer", "call_remote", "reliable", 1)
func _request_shot_rpc(b: PackedByteArray) -> void:
	if not _is_host() or b.size() != 24:
		return
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(b.decode_float(0), b.decode_float(4))
	intent.power = b.decode_float(8)
	intent.spin_offset = Vector2(b.decode_float(12), b.decode_float(16))
	intent.elevation_deg = b.decode_float(20)
	_host_shot(multiplayer.get_remote_sender_id(), intent)


func _host_shot(peer_id: int, intent: ShotIntent) -> void:
	intent.shooter_id = peer_id  # never trust the wire
	var reason := &""
	var cue_ball := _find_cue_ball()
	if cue_ball == null:
		reason = &"no_cue_ball"
	elif _shot_live or awake > 0:
		reason = &"balls_moving"
	elif shot_validator.is_valid():
		reason = shot_validator.call(peer_id, intent)
	if reason != &"":
		if peer_id == multiplayer.get_unique_id():
			shot_rejected.emit(reason)
		else:
			_shot_rejected_rpc.rpc_id(peer_id, reason)
		return
	cue_ball.strike(intent, cue_spec)


@rpc("authority", "call_remote", "reliable", 1)
func _shot_rejected_rpc(reason: StringName) -> void:
	shot_rejected.emit(reason)


func _find_cue_ball() -> Ball:
	for b in _balls:
		if b.is_cue_ball and not b.is_pocketed and b.is_inside_tree():
			return b
	return null


# ---------------------------------------------------------------- host stream

func _peers_listening() -> bool:
	return capture or not multiplayer.get_peers().is_empty()


func _begin_shot_stream(shooter_id: int) -> void:
	if not _is_host():
		return
	shot_id = (shot_id + 1) & 0xFFFF
	_base_tick = Engine.get_physics_frames()
	_shot_live = true
	_emitted_events = 0
	for b in _balls:
		_seed_pred(b)
	_dirty.fill(0)
	BallEventCodec.begin(_frame, shot_id, _base_tick)
	set_physics_process(_peers_listening())
	_shot_started_rpc.rpc(shot_id, shooter_id, _base_tick)


@rpc("authority", "call_local", "reliable", 1)
func _shot_started_rpc(id: int, shooter_id: int, base_tick: int) -> void:
	if not _is_host():
		_rebase_client(base_tick)
	shot_started_net.emit(id, shooter_id, base_tick)


func _seed_pred(b: Ball) -> void:
	var p := _pred[b.net_id]
	p.pos = b.global_position
	p.lin = Vector3.ZERO
	p.ang = Vector3.ZERO
	BallEventCodec.quantize(p, origin())


func _physics_process(_delta: float) -> void:
	if not _shot_live:
		return
	var off := Engine.get_physics_frames() - _base_tick
	var dt := 1.0 / LIVE_TICK
	for b in _balls:
		if b.retired or b.freeze or not b.is_inside_tree():
			continue
		var id := b.net_id
		var pred := _pred[id]
		BallMotion.advance(pred, dt, b.motion)
		var rest := b.is_resting
		var send := _dirty[id] != 0 \
			or pred.pos.distance_squared_to(b.global_position) > DIVERGE_M * DIVERGE_M \
			or (rest and not BallMotion.is_at_rest(pred))
		if send:
			_dirty[id] = 0
			_emit_event(b, BallEventCodec.Flag.NONE, off)
	if off % _flush_every == 0:
		_flush()
	if off % _hb_every == 0:
		_send_heartbeat(off)


## Current Jolt state of `b` -> quantized -> `pred` and the frame. Rest snaps velocities to zero.
func _emit_event(b: Ball, flag: int, off: int) -> void:
	var s := _scratch
	s.pos = b.global_position
	if b.is_resting or b.freeze:
		s.lin = Vector3.ZERO
		s.ang = Vector3.ZERO
	else:
		s.lin = b.linear_velocity
		s.ang = b.angular_velocity
	BallEventCodec.quantize(s, origin())
	_pred[b.net_id].copy_from(s)
	if not BallEventCodec.append(_frame, b.net_id, flag, off, s, origin()):
		_flush()
		BallEventCodec.append(_frame, b.net_id, flag, off, s, origin())
	_emitted_events += 1


func _flush() -> void:
	if BallEventCodec.count(_frame) == 0:
		return
	if not multiplayer.get_peers().is_empty():
		_push_events_rpc.rpc(shot_id, BallEventCodec.base_tick(_frame), _frame)
	frame_flushed.emit(_frame)
	BallEventCodec.begin(_frame, shot_id, BallEventCodec.base_tick(_frame))


func _send_heartbeat(off: int) -> void:
	BallEventCodec.begin(_hb, shot_id, _base_tick)
	for b in _balls:
		if b.retired or b.freeze or not b.is_inside_tree():
			continue
		_scratch.pos = b.global_position
		_scratch.lin = Vector3.ZERO if b.is_resting else b.linear_velocity
		_scratch.ang = Vector3.ZERO if b.is_resting else b.angular_velocity
		BallEventCodec.append(_hb, b.net_id, BallEventCodec.Flag.NONE, off, _scratch, origin())
	if not multiplayer.get_peers().is_empty():
		_push_heartbeat_rpc.rpc(_base_tick + off, _hb)
	heartbeat_flushed.emit(_hb)


func _end_shot_stream() -> void:
	if not _is_host() or not _shot_live:
		return
	var off := Engine.get_physics_frames() - _base_tick
	for b in _balls:
		if b.retired or b.freeze or not b.is_inside_tree():
			continue
		var pred := _pred[b.net_id]
		if pred.pos.distance_squared_to(b.global_position) > DIVERGE_M * DIVERGE_M or not BallMotion.is_at_rest(pred):
			_emit_event(b, BallEventCodec.Flag.NONE, off)
	_flush()
	_shot_live = false
	set_physics_process(false)


## Contacts are the events the client must not miss (04 §2.4): both balls re-sent next tick, post-solve.
func _on_ball_contact(ball: Ball, other: Node, _kind: StringName) -> void:
	if not _shot_live:
		return
	_dirty[ball.net_id] = 1
	if other is Ball:
		_dirty[(other as Ball).net_id] = 1


## Lifecycle changes (pocketed / retired / restored) ride the same stream, also between shots.
func _on_net_flag(ball: Ball, flag: int) -> void:
	if not _is_host() or not _peers_listening():
		return
	if _shot_live:
		_emit_event(ball, flag, Engine.get_physics_frames() - _base_tick)
		return
	BallEventCodec.begin(_frame, shot_id, Engine.get_physics_frames())
	_emit_event(ball, flag, BallReplica.NOW)
	_flush()


@rpc("authority", "call_remote", "reliable", 1)
func _push_events_rpc(_id: int, _base: int, frame: PackedByteArray) -> void:
	apply_frame(frame)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _push_heartbeat_rpc(tick: int, frame: PackedByteArray) -> void:
	# Corrective only: the host's predictions assume the clients follow the event stream, so a
	# heartbeat state is adopted just when the client is provably off (lost packet, late join).
	var o := origin()
	for i in BallEventCodec.count(frame):
		var id := BallEventCodec.ball_id(frame, i)
		var b := _by_id[id] if id < _by_id.size() else null
		if b == null or b.retired:
			continue
		BallEventCodec.read_state(frame, i, o, _hb_state)
		if not _replica.sample(id, tick, b.motion, _scratch) or _scratch.pos.distance_to(_hb_state.pos) > HEARTBEAT_SNAP_M:
			_replica.insert(id, tick, _hb_state)


# ---------------------------------------------------------------- client

## Host tick the client currently presents (04 §2.4): shot start + elapsed − interp delay.
func playback_tick_f() -> float:
	if _is_host():
		return float(Engine.get_physics_frames())
	var el := (Time.get_ticks_usec() - _t0_usec) / 1e6 - INTERP_DELAY_SEC
	return _client_base + el * LIVE_TICK


func playback_tick() -> int:
	return floori(playback_tick_f())


## Host: runs `fn` now. Client: when the playback clock passes `tick`.
func at_playback(tick: int, fn: Callable) -> void:
	if _is_host() or playback_tick() >= tick:
		fn.call()
		return
	var i := _waiting.size()
	while i > 0 and _waiting[i - 1][0] > tick:
		i -= 1
	_waiting.insert(i, [tick, fn])


func apply_frame(frame: PackedByteArray) -> void:
	_replica.apply_frame(frame, origin(), playback_tick(), _on_replica_flag)


func _rebase_client(base_tick: int) -> void:
	var now := playback_tick_f()
	for b in _balls:  # freeze every ball where it is on screen; the shot's events anchor from there
		if _replica.sample(b.net_id, now, b.motion, _scratch):
			_scratch.lin = Vector3.ZERO
			_scratch.ang = Vector3.ZERO
			_replica.anchor(b.net_id, base_tick, _scratch)
	_client_base = base_tick
	_t0_usec = Time.get_ticks_usec()  # playback = base − delay right now: the rest state, until events arrive


func _anchor_now(b: Ball) -> void:
	_scratch.pos = b.global_position
	_scratch.lin = Vector3.ZERO
	_scratch.ang = Vector3.ZERO
	_replica.anchor(b.net_id, playback_tick(), _scratch)


func _on_replica_flag(id: int, flag: int, tick: int) -> void:
	var b := _by_id[id] if id < _by_id.size() else null
	if b == null:
		return
	at_playback(tick, b.net_apply_flag.bind(flag))


func _process(delta: float) -> void:
	if _is_host():
		set_process(false)
		return
	var t := playback_tick_f()
	for b in _balls:
		if b.retired:
			continue
		if _replica.sample(b.net_id, t, b.motion, _scratch):
			b.global_position = _scratch.pos
			var w := _scratch.ang.length()
			if w > 0.0:
				b.global_basis = Basis(_scratch.ang / w, w * delta) * b.global_basis
	while not _waiting.is_empty() and _waiting[0][0] <= int(t):
		_waiting.pop_front()[1].call()
