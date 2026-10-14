class_name ReplayPlan
extends RefCounted
## The instant replay's timeline and camera (docs/plan/10 §3.7), pure: a recorded Shot (frame times, every ball's drawn position and
## visibility) and its key pot in; the clip window, the slow-motion time warp and the camera out. No node and no clock: ReplayCut asks
## for the picture at screen time `tau`, so a step of any size or a seek gives the same frame. Times called `s` are recorded seconds
## since the strike, `tau` is screen seconds since the replay began.

const LEAD_SEC := 2.0      ## recorded seconds shown before the key pot
const TAIL_SEC := 0.8      ## and after it
const SLOW := 0.3          ## playback speed in the slow window
const SLOW_BEFORE := 0.6   ## the slow window around the key pot, recorded seconds before / after it
const SLOW_AFTER := 0.3
const RAMP := 0.2          ## recorded seconds to ease 1 -> SLOW at the window's start and back at its end
const CLOSE_IN := 0.45     ## recorded seconds, ending where the slow window starts, over which the camera flies to the close shot
const WIDE_MIN := 0.6      ## recorded seconds of wide shot before it flies (half the run-up when the pot comes sooner)
const STEP := 1.0 / 240.0  ## screen-time step of the warp table
## Camera, in table half-widths (the table is 2x regulation: everything is a fraction of it, no metre literal).
const WIDE_OUT := 0.7      ## past the long rail
const WIDE_UP := 1.2       ## over the cloth
const WIDE_LOOK := 0.55    ## the wide shot looks this far from the table's centre toward the key ball
const CLOSE_BACK := 0.75   ## behind the key ball's approach to the pocket
const CLOSE_SIDE := 0.35   ## beside it, toward the table's centre
const CLOSE_UP := 0.33
const APPROACH_SEC := 0.25 ## recorded seconds before the pot over which the key ball's approach direction is read

var times := PackedFloat32Array()        ## frame times, ascending, recorded seconds
var tracks: Array[PackedVector3Array] = []  ## per ball: global position per frame
var shown: Array[PackedByteArray] = []   ## per ball: 1 = drawn at that frame
var key_index := -1                      ## the key pot's ball in `tracks`
var key_time := 0.0
var key_pocket := Vector3.ZERO           ## global, at cloth height
var table_xf := Transform3D.IDENTITY     ## the table's frame, origin at the cloth's centre: x = length, z = width
var half_w := 1.0

var t0 := 0.0  ## clip start, recorded seconds
var t1 := 0.0  ## clip end
var _src := PackedFloat32Array()  # recorded time at screen time k * STEP


## Fills the plan in and builds its time warp. `key_time` must lie inside the recording.
static func make(p_times: PackedFloat32Array, p_tracks: Array[PackedVector3Array], p_shown: Array[PackedByteArray], p_key_index: int,
		p_key_time: float, p_key_pocket: Vector3, p_table_xf: Transform3D, p_half_w: float) -> ReplayPlan:
	var p := ReplayPlan.new()
	p.times = p_times
	p.tracks = p_tracks
	p.shown = p_shown
	p.key_index = p_key_index
	p.key_time = p_key_time
	p.key_pocket = p_key_pocket
	p.table_xf = p_table_xf
	p.half_w = maxf(p_half_w, 0.01)
	p._build()
	return p


func _build() -> void:
	var last := times[times.size() - 1] if not times.is_empty() else 0.0
	t0 = clampf(key_time - LEAD_SEC, 0.0, last)
	t1 = clampf(key_time + TAIL_SEC, t0, last)
	_src.clear()
	var s := t0
	_src.append(s)
	while s < t1:
		s = minf(s + speed_at(s) * STEP, t1)
		_src.append(s)


## Screen seconds the clip lasts.
func length() -> float:
	return maxf(float(_src.size() - 1), 0.0) * STEP


## Playback speed at recorded time `s`: 1, eased down to SLOW around the key pot and back.
func speed_at(s: float) -> float:
	var a := key_time - SLOW_BEFORE
	var b := key_time + SLOW_AFTER
	var w := smoothstep(a - RAMP, a, s) * (1.0 - smoothstep(b, b + RAMP, s))
	return lerpf(1.0, SLOW, w)


## Recorded time shown at screen time `tau`.
func source_time(tau: float) -> float:
	if _src.is_empty():
		return t0
	var f := clampf(tau / STEP, 0.0, float(_src.size() - 1))
	var k := mini(floori(f), _src.size() - 1)
	if k >= _src.size() - 1:
		return _src[_src.size() - 1]
	return lerpf(_src[k], _src[k + 1], f - k)


## True while the picture is slowed (the SLOW-MO tag).
func is_slow(s: float) -> bool:
	return speed_at(s) < (1.0 + SLOW) * 0.5


## Ball `i`'s position at recorded time `s`, linear between frames.
func position(i: int, s: float) -> Vector3:
	var tr := tracks[i]
	if tr.is_empty():
		return Vector3.ZERO
	var k := _frame(s)
	if k >= times.size() - 1:
		return tr[tr.size() - 1]
	var span := times[k + 1] - times[k]
	var f := clampf((s - times[k]) / span, 0.0, 1.0) if span > 0.0 else 0.0
	return tr[k].lerp(tr[k + 1], f)


## Whether ball `i` is drawn at recorded time `s` (the frame at or before it).
func visible(i: int, s: float) -> bool:
	var sh := shown[i]
	if sh.is_empty():
		return false
	return sh[mini(_frame(s), sh.size() - 1)] != 0


## Index of the last frame at or before `s`.
func _frame(s: float) -> int:
	return clampi(times.bsearch(s, false) - 1, 0, maxi(times.size() - 1, 0))


## The camera at recorded time `s`: the wide shot, flown to the close shot as the slow window opens.
func camera(s: float) -> Transform3D:
	var fly := close_window()
	var w := smoothstep(fly.x, fly.y, s)
	var wide := wide_pose(s)
	var close := close_pose()
	var eye: Vector3 = wide[0].lerp(close[0], w)
	var look: Vector3 = wide[1].lerp(close[1], w)
	return Transform3D(Basis.looking_at(look - eye, table_xf.basis.y.normalized()), eye)


## Recorded [start, end] of the camera's flight to the close shot: it lands as the slow window opens, but never before the clip has
## shown WIDE_MIN of wide shot (a pot early in the Shot flies later and faster, landing by the pot at the latest).
func close_window() -> Vector2:
	var b := key_time - SLOW_BEFORE
	var a := b - CLOSE_IN
	var lo := t0 + minf(WIDE_MIN, (key_time - t0) * 0.5)
	if a < lo:
		a = lo
		b = minf(maxf(b, a + CLOSE_IN * 0.5), key_time)
	return Vector2(a, maxf(b, a + 0.01))


## [eye, look] of the wide shot: over the long rail on the key pocket's side, following the key ball.
func wide_pose(s: float) -> Array[Vector3]:
	var b := table_xf.basis
	var up := b.y.normalized()
	var along := b.x.normalized()
	var across := b.z.normalized()
	var pl := table_xf.affine_inverse() * key_pocket
	var side := 1.0 if pl.z >= 0.0 else -1.0
	var eye := table_xf.origin + along * pl.x * 0.35 + across * side * half_w * (1.0 + WIDE_OUT) + up * half_w * WIDE_UP
	var look := table_xf.origin.lerp(position(key_index, s), WIDE_LOOK)
	return [eye, look]


## [eye, look] of the close shot: low, behind and beside the key ball's run into the pocket, over the cloth.
func close_pose() -> Array[Vector3]:
	var up := table_xf.basis.y.normalized()
	var d := approach_dir()
	var toward := table_xf.origin - key_pocket
	toward -= up * toward.dot(up)
	var perp := up.cross(d).normalized()
	if perp.dot(toward) < 0.0:
		perp = -perp
	var eye := key_pocket - d * half_w * CLOSE_BACK + perp * half_w * CLOSE_SIDE + up * half_w * CLOSE_UP
	return [eye, key_pocket]


## Horizontal direction the key ball travelled into its pocket; the table's centre to the pocket when it barely moved.
func approach_dir() -> Vector3:
	var up := table_xf.basis.y.normalized()
	var d := position(key_index, key_time) - position(key_index, key_time - APPROACH_SEC)
	d -= up * d.dot(up)
	if d.length() < half_w * 0.02:
		d = key_pocket - table_xf.origin
		d -= up * d.dot(up)
	return d.normalized() if d.length() > 0.0 else table_xf.basis.x.normalized()
