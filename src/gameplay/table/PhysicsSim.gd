class_name PhysicsSim
extends Node

## Live-shot bookkeeping (07 §1.3–1.4, §7.2): awake-ball count via sleep signals, contact
## monitoring only during a Shot, physics tick 120 Hz live / 60 Hz at rest. Modifier stack comes later.

signal shot_started(ball: Ball, intent: ShotIntent)
signal all_resting
## Every peer, host included (04 §5 `shot_started` RPC): the network-level start of a Shot.
signal shot_started_net(shot_id: int, shooter_id: int, base_tick: int)
signal shot_rejected(reason: StringName)
## Client: a streamed lifecycle flag (BallEventCodec.Flag) reached its playback tick and was applied.
signal ball_flag_applied(ball: Ball, flag: int)
## Host: a nudge was applied (RoundDirector logs it as a NUDGE ContactLog entry, 01 §3).
signal nudged(direction: Vector2, strength: float, source_peer_id: int)
## Host: a frame of ball events / heartbeat was flushed (also emitted with no peers when `capture`).
signal frame_flushed(frame: PackedByteArray)
signal heartbeat_flushed(frame: PackedByteArray)
## Client: the app returned from the background; the stream was ignored meanwhile, so ask the host for full state.
signal blind_ended

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
@export var active_cue: CueSpec = preload("res://src/resources/cues/demo_cue.tres")

var awake := 0
var _balls: Array[Ball] = []
var _by_id: Array[Ball] = []
var shot_id := 0
var _shot_live := false
var _last_end_off := 0  # tick offset at which the last Shot's stream ended
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
# NetGraph counters: frames sent (host) or received (client)
var net_events := 0
var net_bytes := 0
var net_events_shot := 0
var net_bytes_shot := 0
var _last_event_tick := 0
# client
var _replica := BallReplica.new()
var _t0_usec := 0
var _client_base := 0
var _waiting: Array = []  # [tick, Callable], oldest first
var _rail_mult: Dictionary = {}  # rail_id -> float, absent = 1.0
var _blind := false  # client: backgrounded, event/heartbeat frames are dropped until a snapshot lands
var _pk_ref_t := 0.0  # client: host pocket clock at `_pk_ref_usec`
var _pk_ref_usec := 0


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
			_sync_motion_params()
			_scale_bed_friction(value)
		&"cushion_restitution_mult": cushion_restitution_mult = value
		&"table_tilt_deg":
			table_tilt_deg = value
			_sync_motion_params()
		_: push_error("PhysicsSim.set_stat: unknown stat %s" % stat_name)


func set_tilt_direction(dir: Vector2) -> void:
	tilt_direction = dir.normalized()
	_sync_motion_params()


## Prediction-relevant stats (cloth friction, tilt) into every ball's BallMotion.Params, and — while a
## Shot is live — to clients at this tick, so both sides predict from the same model (04 §2.4).
func _sync_motion_params() -> void:
	var tilt := tilt_direction * float(ProjectSettings.get_setting("physics/3d/default_gravity")) * sin(deg_to_rad(table_tilt_deg))
	for b in _balls:
		b.motion.friction_mult = cloth_friction_mult
		b.motion.tilt = tilt
	if _shot_live and _is_host() and not multiplayer.get_peers().is_empty():
		_motion_stats_rpc.rpc(Engine.get_physics_frames(), _motion_stats())


func _motion_stats() -> PackedFloat32Array:
	return PackedFloat32Array([cloth_friction_mult, table_tilt_deg, tilt_direction.x, tilt_direction.y])


@rpc("authority", "call_remote", "reliable", 1)
func _motion_stats_rpc(tick: int, stats: PackedFloat32Array) -> void:
	at_playback(tick, _apply_motion_stats.bind(stats))


func _apply_motion_stats(stats: PackedFloat32Array) -> void:
	cloth_friction_mult = stats[0]
	table_tilt_deg = stats[1]
	tilt_direction = Vector2(stats[2], stats[3])
	_sync_motion_params()


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
	var nm := get_node_or_null(^"/root/NetManager")  # absent in `-s` probes
	if nm != null:
		nm.app_paused.connect(_on_app_paused)
		nm.app_resumed.connect(_on_app_resumed)
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
	ball.motion.tilt = tilt_direction * float(ProjectSettings.get_setting("physics/3d/default_gravity")) * sin(deg_to_rad(table_tilt_deg))
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
	if _blind:
		return  # a backgrounded phone sends nothing (04 §6)
	var b := PackedByteArray()
	b.resize(25)
	b.encode_float(0, intent.aim_dir.x)
	b.encode_float(4, intent.aim_dir.y)
	b.encode_float(8, intent.power)
	b.encode_float(12, intent.spin_offset.x)
	b.encode_float(16, intent.spin_offset.y)
	b.encode_float(20, intent.elevation_deg)
	b[24] = _pocket_ids().find(intent.called_pocket) + 1  # 0 = none
	_request_shot_rpc.rpc_id(1, b)


@rpc("any_peer", "call_remote", "reliable", 1)
func _request_shot_rpc(b: PackedByteArray) -> void:
	if not _is_host() or b.size() != 25:
		return
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(b.decode_float(0), b.decode_float(4))
	intent.power = b.decode_float(8)
	intent.spin_offset = Vector2(b.decode_float(12), b.decode_float(16))
	intent.elevation_deg = b.decode_float(20)
	var ids := _pocket_ids()
	intent.called_pocket = ids[b[24] - 1] if b[24] >= 1 and b[24] <= ids.size() else &""
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
	cue_ball.strike(intent, active_cue)


@rpc("authority", "call_remote", "reliable", 1)
func _shot_rejected_rpc(reason: StringName) -> void:
	shot_rejected.emit(reason)


## Pocket ids in layout order, identical on every peer: the wire index for `called_pocket`.
func _pocket_ids() -> Array:
	return (get_parent() as Table).pockets.keys()


## Tick just past the last Shot's stream: what clients queue post-shot spawns / re-rolls against.
func after_shot_tick() -> int:
	return _base_tick + _last_end_off + 1


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
	net_events_shot = 0
	net_bytes_shot = 0
	for b in _balls:
		_seed_pred(b)
	_dirty.fill(0)
	BallEventCodec.begin(_frame, shot_id, _base_tick)
	set_physics_process(_peers_listening())
	_shot_started_rpc.rpc(shot_id, shooter_id, _base_tick, _motion_stats(), pocket_time())


@rpc("authority", "call_local", "reliable", 1)
func _shot_started_rpc(id: int, shooter_id: int, base_tick: int, stats: PackedFloat32Array, host_pocket_t: float) -> void:
	if not _is_host():
		_apply_motion_stats(stats)
		_rebase_client(base_tick)
		sync_pocket_clock(host_pocket_t)
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
	_count_frame(_frame)
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
	_last_end_off = off
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
	# Right after a shot (kitchen respawn, off-table restore): stamped just past the shot's last tick so
	# the client orders it after the pot/retire flags it may still have queued at playback.
	BallEventCodec.begin(_frame, shot_id, _base_tick)
	_emit_event(ball, flag, _last_end_off + 1)
	_flush()


@rpc("authority", "call_remote", "reliable", 1)
func _push_events_rpc(_id: int, _base: int, frame: PackedByteArray) -> void:
	if not _blind:
		apply_frame(frame)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _push_heartbeat_rpc(tick: int, frame: PackedByteArray) -> void:
	# Corrective only: the host's predictions assume the clients follow the event stream, so a
	# heartbeat state is adopted just when the client is provably off (lost packet, late join).
	if _blind:
		return
	var o := origin()
	for i in BallEventCodec.count(frame):
		var id := BallEventCodec.ball_id(frame, i)
		var b := _by_id[id] if id < _by_id.size() else null
		if b == null or b.retired:
			continue
		BallEventCodec.read_state(frame, i, o, _hb_state)
		if not _replica.sample(id, tick, b.motion, _scratch) or _scratch.pos.distance_to(_hb_state.pos) > HEARTBEAT_SNAP_M:
			_replica.insert(id, tick, _hb_state)


# ---------------------------------------------------------------- pocket clock

## Seconds on the pocket-oscillation clock (`Table.pocket_offset` input). Host: its own monotonic clock,
## the one its drop-chute Areas capture against. Client: that clock as of the last sync, minus the playback
## delay, so a pocket is drawn where it was when the host's Jolt would have captured a ball you now see.
func pocket_time() -> float:
	if _is_host():
		return Time.get_ticks_usec() / 1e6
	return _pk_ref_t + (Time.get_ticks_usec() - _pk_ref_usec) / 1e6 - INTERP_DELAY_SEC


## Client: adopt the host's clock (sent with every shot start and full state; zero packets in between).
func sync_pocket_clock(host_t: float) -> void:
	_pk_ref_t = host_t
	_pk_ref_usec = Time.get_ticks_usec()


# ---------------------------------------------------------------- background / full state (04 §6)

func _on_app_paused() -> void:
	if not _is_host():
		_blind = true


func _on_app_resumed() -> void:
	if _blind:
		blind_ended.emit()  # stays blind until the snapshot arrives: old stream frames must not land on it


## Host: every ball's state right now as one codec frame (`tick` = this host tick, every event at offset 0).
## Lifecycle flags ride the event flags, so pocketed/retired balls need no second format.
func snapshot_frame() -> PackedByteArray:
	var f := PackedByteArray()
	BallEventCodec.begin(f, shot_id, Engine.get_physics_frames())
	for b in _balls:
		if not b.is_inside_tree():
			continue
		_scratch.pos = b.global_position
		var still := b.is_resting or b.freeze
		_scratch.lin = Vector3.ZERO if still else b.linear_velocity
		_scratch.ang = Vector3.ZERO if still else b.angular_velocity
		var flag := BallEventCodec.Flag.RETIRED if b.retired else (BallEventCodec.Flag.POCKETED if b.is_pocketed else BallEventCodec.Flag.NONE)
		BallEventCodec.append(f, b.net_id, flag, 0, _scratch, origin())
	return f


## Client: replace every ball's history with the snapshot and put the playback clock on it.
## Balls must already exist (RoundDirector respawned them from the rack blob).
func apply_snapshot(frame: PackedByteArray, host_pocket_t: float) -> void:
	_waiting.clear()
	var tick := BallEventCodec.base_tick(frame)
	_client_base = tick
	_t0_usec = Time.get_ticks_usec() - int(INTERP_DELAY_SEC * 1e6)  # playback = `tick` right now
	sync_pocket_clock(host_pocket_t)
	for i in BallEventCodec.count(frame):
		var id := BallEventCodec.ball_id(frame, i)
		var b := _by_id[id] if id < _by_id.size() else null
		if b == null:
			continue
		BallEventCodec.read_state(frame, i, origin(), _scratch)
		_replica.anchor(id, tick, _scratch)
		var flag := BallEventCodec.flag(frame, i)
		if flag != BallEventCodec.Flag.NONE:
			_apply_flag(b, flag)
		b.global_position = _scratch.pos
	_blind = false


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


func _count_frame(frame: PackedByteArray) -> void:
	net_events += BallEventCodec.count(frame)
	net_bytes += frame.size()
	net_events_shot += BallEventCodec.count(frame)
	net_bytes_shot += frame.size()


## Client: how far past the playback clock the newest received event lies.
func event_lead_ms() -> float:
	return (_last_event_tick - playback_tick_f()) * 1000.0 / LIVE_TICK


func apply_frame(frame: PackedByteArray) -> void:
	_count_frame(frame)
	if BallEventCodec.count(frame) > 0:
		_last_event_tick = maxi(_last_event_tick, BallEventCodec.base_tick(frame) + BallEventCodec.tick_offset(frame, BallEventCodec.count(frame) - 1))
	_replica.apply_frame(frame, origin(), playback_tick(), _on_replica_flag)


func _rebase_client(base_tick: int) -> void:
	net_events_shot = 0
	net_bytes_shot = 0
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
	at_playback(tick, _apply_flag.bind(b, flag))


func _apply_flag(b: Ball, flag: int) -> void:
	b.net_apply_flag(flag)
	ball_flag_applied.emit(b, flag)


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
