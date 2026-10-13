class_name BallReplica
extends RefCounted

## Client-side (and SimDiff-side) reconstruction of ball motion from event frames (04 §2.4):
## per ball, a tick-sorted list of transmitted states; a sample at tick T dead-reckons the latest
## event ≤ T with `BallMotion.advance`. Interpolation only: nothing past the newest event is ever
## invented beyond the model's own coast, and the caller renders at host − 100 ms so events lead.

const STRIDE := 10  # tick, pos(3), lin(3), ang(3)
const KEEP := 24    # events kept per ball; older ones are dropped once passed
const NOW := 0xFFFF  # tick_offset sentinel: "apply at the playback clock's current tick"
const BLEND_TICKS := 12  # 100 ms at LIVE_TICK (= PhysicsSim.INTERP_DELAY_SEC): an authoritative correction is spread over this long
const BLEND_MIN_M := 0.001  # a smaller correction is just taken (06 P49)


## The part of an authoritative correction not yet shown: added to the sampled position, shrinking linearly to zero.
class Blend extends RefCounted:
	var start := 0.0
	var offset := Vector3.ZERO


var _data: Array[PackedFloat64Array] = []
var _scratch := BallMotion.State.new()
var _shown := BallMotion.State.new()
var _blend: Dictionary = {}  # net_id -> Blend


func _ensure(id: int) -> PackedFloat64Array:
	while _data.size() <= id:
		_data.append(PackedFloat64Array())
	return _data[id]


## One event per ball at `tick`; everything older is discarded.
func anchor(id: int, tick: int, s: BallMotion.State) -> void:
	_ensure(id)
	var d := PackedFloat64Array()
	_push(d, tick, s)
	_data[id] = d


## An authoritative state (the host's word for where the ball is, 06 P49): inserted like `insert`, but never older than the
## newest event of that ball (it is the newest information, whatever tick it was stamped), and the jump it makes in what is
## on screen at `now` (or at its own tick, if later) is spread over BLEND_TICKS instead of shown as a pop.
func insert_blended(id: int, tick: int, s: BallMotion.State, now: float, p: BallMotion.Params) -> void:
	tick = maxi(tick, newest_tick(id))
	var t_ref := maxf(now, float(tick))
	var had := sample(id, t_ref, p, _shown)
	var before := _shown.pos + blend_offset(id, t_ref) if had else Vector3.ZERO
	insert(id, tick, s)
	if not had:
		return
	sample(id, t_ref, p, _shown)
	var err := before - _shown.pos
	if err.length() <= BLEND_MIN_M:
		_blend.erase(id)
		return
	set_blend(id, t_ref, err)


## Added to `sample`'s position to get what is drawn at tick `t`.
func blend_offset(id: int, t: float) -> Vector3:
	var bl: Blend = _blend.get(id)
	if bl == null or t < bl.start:
		return Vector3.ZERO
	var k := (t - bl.start) / BLEND_TICKS
	return bl.offset * (1.0 - k) if k < 1.0 else Vector3.ZERO


## Ball `id` is drawn `offset` off from tick `start` on, closing over BLEND_TICKS.
func set_blend(id: int, start: float, offset: Vector3) -> void:
	var bl := Blend.new()
	bl.start = start
	bl.offset = offset
	_blend[id] = bl


func clear_blend(id: int) -> void:
	_blend.erase(id)


func clear_blends() -> void:
	_blend.clear()


func newest_tick(id: int) -> int:
	if not has_ball(id):
		return 0
	var d := _data[id]
	return int(d[d.size() - STRIDE])


func insert(id: int, tick: int, s: BallMotion.State) -> void:
	var d := _ensure(id)
	var n := d.size() / STRIDE
	var i := n
	while i > 0 and d[(i - 1) * STRIDE] > tick:
		i -= 1
	if i > 0 and d[(i - 1) * STRIDE] == tick:
		_write(d, i - 1, tick, s)  # a later state for the same tick wins
	else:
		d.resize(d.size() + STRIDE)
		for j in range(n * STRIDE - 1, i * STRIDE - 1, -1):
			d[j + STRIDE] = d[j]
		_write(d, i, tick, s)
	_data[id] = d


## Applies every event of `frame`; `now_tick` resolves NOW-sentinel offsets. `on_flag(id, flag, tick)`
## is called for events carrying a non-NONE flag (after their state is stored).
func apply_frame(frame: PackedByteArray, origin: Vector3, now_tick: int, on_flag: Callable = Callable()) -> void:
	var base := BallEventCodec.base_tick(frame)
	for i in BallEventCodec.count(frame):
		var off := BallEventCodec.tick_offset(frame, i)
		var tick := now_tick if off == NOW else base + off
		var id := BallEventCodec.ball_id(frame, i)
		BallEventCodec.read_state(frame, i, origin, _scratch)
		insert(id, tick, _scratch)
		var flag := BallEventCodec.flag(frame, i)
		if flag != BallEventCodec.Flag.NONE and on_flag.is_valid():
			on_flag.call(id, flag, tick)


func has_ball(id: int) -> bool:
	return id < _data.size() and _data[id].size() > 0


## State of ball `id` at fractional `tick`; false when the ball has no events yet.
func sample(id: int, tick: float, p: BallMotion.Params, out: BallMotion.State) -> bool:
	if not has_ball(id):
		return false
	var d := _data[id]
	var n := d.size() / STRIDE
	var i := n - 1
	while i > 0 and d[i * STRIDE] > tick:
		i -= 1
	var o := i * STRIDE
	out.pos = Vector3(d[o + 1], d[o + 2], d[o + 3])
	out.lin = Vector3(d[o + 4], d[o + 5], d[o + 6])
	out.ang = Vector3(d[o + 7], d[o + 8], d[o + 9])
	var dt := (tick - d[o]) / float(PhysicsSim.LIVE_TICK)
	if dt > 0.0 and not BallMotion.is_at_rest(out):  # no motion at all = the host has the ball frozen here (a rest), not "released": it stays (06 P49)
		BallMotion.advance(out, dt, p)
	if i > KEEP:  # bounded memory: drop events the playback clock has long passed
		_data[id] = d.slice((i - KEEP / 2) * STRIDE)
	return true


static func _push(d: PackedFloat64Array, tick: int, s: BallMotion.State) -> void:
	d.resize(d.size() + STRIDE)
	_write(d, d.size() / STRIDE - 1, tick, s)


static func _write(d: PackedFloat64Array, i: int, tick: int, s: BallMotion.State) -> void:
	var o := i * STRIDE
	d[o] = tick
	d[o + 1] = s.pos.x
	d[o + 2] = s.pos.y
	d[o + 3] = s.pos.z
	d[o + 4] = s.lin.x
	d[o + 5] = s.lin.y
	d[o + 6] = s.lin.z
	d[o + 7] = s.ang.x
	d[o + 8] = s.ang.y
	d[o + 9] = s.ang.z
