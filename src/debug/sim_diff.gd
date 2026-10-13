class_name SimDiff
extends Node

## Offline netcode gate (07 §3, M3): watches a host PhysicsSim, feeds its event frames through a
## simulated link (`latency_ticks`) into a BallReplica, and at every host tick compares the client's
## reconstruction at `playback = host − delay_ticks` with the host's own position history.
## Everything the real client does — decode, sort, dead-reckon — runs; only the transport is faked.

var sim: PhysicsSim
var latency_ticks := 6   # ~50 ms one-way at 120 Hz
var delay_ticks := 12    # 100 ms interp delay (PhysicsSim.INTERP_DELAY_SEC × LIVE_TICK)

var max_err_m := 0.0
var max_err_tick := 0
var max_err_ball := -1
var ticks_compared := 0
var events := 0
var frames := 0
var bytes := 0
var heartbeat_bytes := 0

var _replica := BallReplica.new()
var _pending: Array = []  # [deliver_tick, frame]
var _hist: Dictionary = {}  # tick -> PackedVector3Array by net_id
var _out := BallMotion.State.new()
var _base := -1
var first_bad := ""
var _params: Dictionary = {}  # net_id -> BallMotion.Params, the replica's own (flags land at playback time)
var _flags: Array = []  # [tick, id, flag]
var _retired: Dictionary = {}


func attach(p_sim: PhysicsSim) -> void:
	sim = p_sim
	add_to_group(&"sim_diff")
	sim.capture = true
	sim.frame_flushed.connect(_on_frame)
	sim.heartbeat_flushed.connect(func(f: PackedByteArray) -> void: heartbeat_bytes += f.size())
	sim.shot_started_net.connect(_on_shot_started)


func _on_shot_started(_id: int, _shooter: int, base_tick: int) -> void:
	_base = base_tick
	_hist.clear()
	var s := BallMotion.State.new()
	for b in sim.get_balls():
		s.pos = b.global_position
		_replica.anchor(b.net_id, base_tick, s)


func _on_frame(f: PackedByteArray) -> void:
	events += BallEventCodec.count(f)
	frames += 1
	bytes += f.size()
	_pending.append([Engine.get_physics_frames() + latency_ticks, f.duplicate()])


func _physics_process(_delta: float) -> void:
	if _base < 0:
		return
	var now := Engine.get_physics_frames()
	var arr := PackedVector3Array()
	for b in sim.get_balls():
		while arr.size() <= b.net_id:
			arr.append(Vector3.ZERO)
		arr[b.net_id] = b.global_position
	_hist[now] = arr
	while not _pending.is_empty() and _pending[0][0] <= now:
		_replica.apply_frame(_pending.pop_front()[1], sim.origin(), now, func(id: int, flag: int, tick: int) -> void: _flags.append([tick, id, flag]))
	var t := now - delay_ticks
	if not _hist.has(t):
		return
	for f in _flags.duplicate():
		if f[0] <= t:
			_flags.erase(f)
			var pp := _p(f[1])
			match f[2]:
				BallEventCodec.Flag.POCKETED: pp.floor_y = pp.cup_floor_y
				BallEventCodec.Flag.RETIRED: _retired[f[1]] = true
				BallEventCodec.Flag.RESTORED:
					_retired.erase(f[1])
					pp.floor_y = _rest_floor(f[1])
	var truth: PackedVector3Array = _hist[t]
	_hist.erase(t)
	for b in sim.get_balls():
		if _retired.has(b.net_id) or b.net_id >= truth.size():
			continue
		if not _replica.sample(b.net_id, t, _p(b.net_id), _out):
			continue
		var err := _out.pos.distance_to(truth[b.net_id])
		ticks_compared += 1
		if err > 0.005 and first_bad == "":
			first_bad = "ball %d tick +%d err %.1f mm host %s client %s lin %s" % [b.net_id, t - _base, err * 1000.0, truth[b.net_id], _out.pos, _out.lin]
		if err > max_err_m:
			max_err_m = err
			max_err_tick = t - _base
			max_err_ball = b.net_id


func report() -> String:
	return first_bad + "\n" + "max err %.2f mm (ball %d, tick +%d) | %d ticks compared | %d events in %d frames, %d B (+%d B heartbeat)" % [
		max_err_m * 1000.0, max_err_ball, max_err_tick, ticks_compared, events, frames, bytes, heartbeat_bytes]


func _p(id: int) -> BallMotion.Params:
	if not _params.has(id):
		var b := sim._by_id[id]
		var pp := BallMotion.make_params(b.spec, b.radius)
		pp.friction_mult = sim.cloth_friction_mult  # the client mirrors these at shot start (04 §5)
		pp.tilt = b.motion.tilt
		pp.hazard = b.motion.hazard  # the pins / shoreline are the same object on every peer (EffectManager.begin_event)
		_params[id] = pp
	return _params[id]


func _rest_floor(id: int) -> float:
	var b := sim._by_id[id]
	return b.spec.bed_height_m + b.radius
