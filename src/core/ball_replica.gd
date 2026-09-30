class_name BallReplica
extends RefCounted

## Client-side (and SimDiff-side) reconstruction of ball motion from event frames (04 §2.4):
## per ball, a tick-sorted list of transmitted states; a sample at tick T dead-reckons the latest
## event ≤ T with `BallMotion.advance`. Interpolation only: nothing past the newest event is ever
## invented beyond the model's own coast, and the caller renders at host − 100 ms so events lead.

const STRIDE := 10  # tick, pos(3), lin(3), ang(3)
const KEEP := 24    # events kept per ball; older ones are dropped once passed
const NOW := 0xFFFF  # tick_offset sentinel: "apply at the playback clock's current tick"

var _data: Array[PackedFloat64Array] = []
var _scratch := BallMotion.State.new()


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
	if dt > 0.0:
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
