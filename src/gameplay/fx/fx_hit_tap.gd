class_name FxHitTap
extends RefCounted

## Presentation-only contact classifier (docs/plan/10 §2). A client has no contacts, only the host's event stream
## (04 §2.4), so this rebuilds them: an event whose velocity jumps against what the previous event predicts is an impact;
## a neighbour with an event on the same tick makes it ball-ball, a cushion nearby makes it a rail, else it is a kick
## (cue strike, nudge, blast). Pure: no nodes, no signals. ImpactFx schedules what comes out on the playback clock.

enum Kind { BALL, RAIL, KICK }

const MIN_DV := 0.35  # m/s: smaller velocity jumps are the host's divergence re-sends, not impacts
const PAIR_SLACK := 0.012  # m past 2R still counted as touching
const PAIR_TRAVEL_TICKS := 3.0  # events land 1-2 ticks after the contact: balls have drawn apart by that much relative travel
const RAIL_BAND_RADII := 4.0  # a rail impact is seen up to this many radii off the cushion (the event trails the bounce)
const POCKET_REACH_RADII := 4.0  # past the pocket's half mouth: where a bounce is a jaw's
const ECHO_TICKS := 4  # the host rescales a rebound one tick after the bounce (Ball._rail_rebound): that re-send is not a second hit

var radius := 0.05715
var origin := Vector3.ZERO  # Table.global_position: the codec's frame origin and the table-local zero
var half_length := 2.54  # table-local playing surface half extents
var half_width := 1.27
var params_for: Callable  # (net_id: int) -> BallMotion.Params; null / invalid = no coast prediction
var strike_id := -1  # the cue ball's net_id: only it can be kicked (a cue strike); any other lone jump is a stray re-send
var pockets: Array[Vector2] = []  # table-local XZ of each pocket: jaws there bounce balls the host never reports as cushion hits
var pocket_reach := 0.0  # m around a pocket where a lone bounce is a jaw, not a cushion

var _tick := {}  # net_id -> tick of the newest event seen
var _state := {}  # net_id -> BallMotion.State of that event
var _gone := {}  # net_id -> true while pocketed: a ball bouncing in its cup is no hit
var _rail := {}  # net_id -> {tick, n} of its last cushion hit


## A Shot starts with every ball at rest: forget the last Shot's history.
func reset() -> void:
	_tick.clear()
	_state.clear()
	_gone.clear()
	_rail.clear()


## Pocket centres (table-local XZ) and the widest mouth, for the jaw zone.
func set_pockets(centres: Array[Vector2], widest_mouth: float) -> void:
	pockets = centres
	pocket_reach = widest_mouth * 0.5 + radius * POCKET_REACH_RADII


## Hits found in `frame` (host `BallEventCodec` layout), earliest first: {kind, tick, pos, normal, strength}.
## `now_tick` resolves apply-now lifecycle events; those only refresh the history.
func process(frame: PackedByteArray, now_tick: int) -> Array[Dictionary]:
	var base := BallEventCodec.base_tick(frame)
	var evs: Array[Dictionary] = []
	for i in BallEventCodec.count(frame):
		var off := BallEventCodec.tick_offset(frame, i)
		var id := BallEventCodec.ball_id(frame, i)
		var post := BallMotion.State.new()
		BallEventCodec.read_state(frame, i, origin, post)
		var flag := BallEventCodec.flag(frame, i)
		var life := off == BallReplica.NOW or flag != BallEventCodec.Flag.NONE
		if flag == BallEventCodec.Flag.POCKETED:
			_gone[id] = true
		elif flag == BallEventCodec.Flag.RESTORED:
			_gone.erase(id)
		var tick := now_tick if off == BallReplica.NOW else base + off
		var pre := _predict(id, tick)
		_remember(id, tick, post)
		if not life and not _gone.has(id):
			evs.append({id = id, tick = tick, post = post, pre = pre})
	var out: Array[Dictionary] = []
	var paired := {}
	for e in evs:
		var dv: Vector3 = e.post.lin - e.pre
		dv.y = 0.0
		var partner := _partner(evs, e)
		if partner.is_empty():
			var solo := _solo(e, dv) if dv.length() >= MIN_DV else {}
			if not solo.is_empty():
				out.append(solo)
			continue
		var key: int = e.tick * 4096 + mini(e.id, partner.id) * 64 + maxi(e.id, partner.id)
		if paired.has(key):
			continue
		paired[key] = true
		var strength := ((e.pre as Vector3) - (partner.pre as Vector3)).length()
		if strength >= MIN_DV:
			var a: Vector3 = e.post.pos
			var b: Vector3 = partner.post.pos
			out.append({kind = Kind.BALL, tick = e.tick, pos = (a + b) * 0.5, normal = (b - a).normalized(), strength = strength})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.tick < y.tick)
	return out


## A ball with no touching neighbour: a cushion if one is close, else a cue strike (cue ball only), else {}.
func _solo(e: Dictionary, dv: Vector3) -> Dictionary:
	var n := dv.normalized()  # leaves the surface it hit
	var lp: Vector3 = e.post.pos - origin
	var band := radius * RAIL_BAND_RADII
	if absf(lp.x) > half_length - band or absf(lp.z) > half_width - band:
		for p in pockets:
			if Vector2(lp.x, lp.z).distance_to(p) < pocket_reach:
				return {}
		var approach := -(e.pre as Vector3).dot(n)
		if approach < MIN_DV:
			return {}
		var prev: Dictionary = _rail.get(e.id, {})
		_rail[e.id] = {tick = e.tick, n = n}
		if not prev.is_empty() and e.tick - int(prev.tick) <= ECHO_TICKS and n.dot(prev.n as Vector3) < -0.5:
			return {}
		return {kind = Kind.RAIL, tick = e.tick, pos = e.post.pos - n * radius, normal = n, strength = approach}
	if e.id != strike_id:
		return {}
	return {kind = Kind.KICK, tick = e.tick, pos = e.post.pos, normal = n, strength = dv.length()}


## Another ball with an event on the same tick and close enough to be touching, or {}.
func _partner(evs: Array[Dictionary], e: Dictionary) -> Dictionary:
	var reach := 2.0 * radius + PAIR_SLACK
	for o in evs:
		if o.id != e.id and o.tick == e.tick:
			var d: Vector3 = o.post.pos - e.post.pos
			d.y = 0.0
			var apart: float = ((o.post.lin as Vector3) - (e.post.lin as Vector3)).length() * PAIR_TRAVEL_TICKS / float(PhysicsSim.LIVE_TICK)
			if d.length() <= reach + apart:
				return o
	return {}


## The ball's velocity at `tick`: its newest event coasted forward; rest when it has none.
func _predict(id: int, tick: int) -> Vector3:
	var s: BallMotion.State = _state.get(id)
	if s == null:
		return Vector3.ZERO
	var out := BallMotion.State.new()
	out.copy_from(s)
	var dt := float(tick - int(_tick[id])) / float(PhysicsSim.LIVE_TICK)
	var p: BallMotion.Params = params_for.call(id) if params_for.is_valid() else null
	if dt > 0.0 and p != null:
		BallMotion.advance(out, dt, p)
	return out.lin


func _remember(id: int, tick: int, s: BallMotion.State) -> void:
	var keep := BallMotion.State.new()
	keep.copy_from(s)
	_state[id] = keep
	_tick[id] = tick
