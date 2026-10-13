class_name IntroRoom
extends RoomCutscene
## Intro, part 3, IN the bar (docs/plan/09 §3.8.1, 06 P39 U17: "they throw all 4 people into the middle of the bar then shut the door behind
## them locking it"). Cut from the cabin's open door to the bar's: the bolt draws, the door bursts inward, and the crew is thrown through it one
## after another over the table to where they spawn, landing on their backs; the last one is in, the door slams and the bolt shoots with a clunk,
## a beat of silence, then the cut back to the local player's own eye as they get to their feet. All scripted tweens of the Player nodes (no
## ragdoll, no collision), at most two bodies limp (tilted past 60 degrees, in the air or on the floor) at any moment. Camera: a wide shot from the south end looking at the door, a close-up of the
## door for the slam and the lock, then the player's eye. A pure function of the time and the seats; the end state (everyone home, the door shut
## and bolted) is also what Skip leaves.

const LENGTH_SEC := 6.5
const T_UNLOCK := 0.05  ## the bolt draws back (over BOLT_SEC)
const T_OPEN := 0.3  ## the door bursts open (over OPEN_SEC)
const OPEN_SEC := 0.3
const THROW_AT := 0.55  ## seat 0 leaves the doorway
const THROW_GAP := 0.95  ## ... and each next seat this much later: with LIMP_LEAD_SEC and the floor time, at most two are limp at once
const FLIGHT_SEC := 1.0
const STILL_SEC := 0.75  ## a body lies still this long after it lands, then gets up over GET_UP_SEC
const GET_UP_SEC := 0.55
const LIMP_LEAD_SEC := 0.5  ## the last half second of a flight is already past 60 degrees of lean
const T_CUT := 3.5  ## cut to the close-up of the door
const T_SLAM := 3.7
const SLAM_SEC := 0.22
const T_BOLT := 4.4  ## the bolt shoots (over BOLT_SEC)
const BOLT_SEC := 0.25
const T_BACK := 5.85  ## cut back to the local player's own eye
const ARC_M := 1.5  ## the flight's rise over a straight line between the doorway and home
const DOOR_OUT_Z := -7.4  ## where a body starts: outside, behind the doorway quad, hidden
const FLIGHT_FROM_Y := 0.6

var _door: EntranceDoor
var _rigs: Array[Node3D] = []  ## the tripod models hidden for the beat (the base tripod stands against the north wall, dead in front of the door)


func id() -> StringName:
	return &"intro_room"


func length_sec() -> float:
	return LENGTH_SEC


## How many bodies are limp (tilted past 60 degrees: the end of the flight, lying, getting up) at `time` for a crew of `n`: the budget is 2 (07 §1).
static func limp_at(n: int, time: float) -> int:
	var count := 0
	for i in n:
		var landed := THROW_AT + THROW_GAP * float(i) + FLIGHT_SEC
		if time >= landed - LIMP_LEAD_SEC and time < landed + STILL_SEC + GET_UP_SEC:
			count += 1
	return count


func _build() -> void:
	super()
	_door = _node(^"EntranceDoor") as EntranceDoor
	for m: Dictionary in members:
		(m.player as Player).visible = false  # they are outside until thrown
	if _door != null:
		_door.set_openness(0.0)
		_door.set_bolt(1.0)
	_hide_rigs()


## The base tripod (CameraRigs.SPOTS[0]) stands in front of the door and in the bodies' way: its model is hidden for the beat (not moved: its
## spot is the camera lane's) and shown again at the cut back to the player's eye, under the dip to black.
func _hide_rigs() -> void:
	var cams := _node(^"Cameras")
	if cams == null:
		return
	for c in cams.get_children():
		var model: Node3D = null
		if c is CameraRig:
			model = c.get_node_or_null(^"Model") as Node3D
		if model != null and model.visible:
			model.visible = false
			_rigs.append(model)


func _show_rigs() -> void:
	for model in _rigs:
		if is_instance_valid(model):
			model.visible = true
	_rigs.clear()


func _fade_at(time: float) -> float:
	var a := 1.0 - clampf(time / 0.3, 0.0, 1.0)  # up from the cabin's black
	a = maxf(a, _dip(time, T_CUT))
	return maxf(a, _dip(time, T_BACK))


static func _dip(time: float, at: float) -> float:
	return 1.0 - smoothstep(0.0, 0.12, absf(time - at))


func _update(time: float, _dt: float) -> void:
	if time >= T_BACK:
		_show_rigs()
	_door_beat(time)
	for i in members.size():
		_pose_member(i, time)
		if time >= THROW_AT + THROW_GAP * float(i) + FLIGHT_SEC and _once(StringName("land%d" % i)):
			CutsceneSfx.play(self, CutsceneSfx.Kind.THUD, -6.0)
	_camera(time)


func _door_beat(time: float) -> void:
	var opened := smoothstep(T_OPEN, T_OPEN + OPEN_SEC, time)
	var slammed := smoothstep(T_SLAM, T_SLAM + SLAM_SEC, time)
	var bolt := 1.0 - smoothstep(T_UNLOCK, T_UNLOCK + BOLT_SEC, time) + smoothstep(T_BOLT, T_BOLT + BOLT_SEC, time)
	if _door != null:
		_door.set_openness(opened * (1.0 - slammed))
		_door.set_bolt(bolt)
	if time >= T_UNLOCK + BOLT_SEC and _once(&"unlock"):
		CutsceneSfx.play(self, CutsceneSfx.Kind.CLUNK, -6.0)
	if time >= T_OPEN and _once(&"bang"):
		CutsceneSfx.play(self, CutsceneSfx.Kind.SLAM, -8.0)
	if time >= T_SLAM + SLAM_SEC * 0.8 and _once(&"slam"):
		CutsceneSfx.play(self, CutsceneSfx.Kind.SLAM, -2.0)
	if time >= T_BOLT + BOLT_SEC and _once(&"lock"):
		CutsceneSfx.play(self, CutsceneSfx.Kind.CLUNK, -2.0)


## Seat `i`: outside until its turn, then a flight over the table to its spawn spot (tumbling, arms flailing), landing on its back, still for a
## moment, then up. The Player node is the position; the Humanoid is tilted about its middle.
func _pose_member(i: int, time: float) -> void:
	var m: Dictionary = members[i]
	var p: Player = m.player
	var home: Vector3 = m.home
	var t0 := THROW_AT + THROW_GAP * float(i)
	var start := Vector3(clampf(home.x * 0.35, -0.6, 0.6), FLIGHT_FROM_Y, DOOR_OUT_Z)
	if time < t0:
		p.visible = false
		p.global_position = start
		return
	p.visible = true
	var u := clampf((time - t0) / FLIGHT_SEC, 0.0, 1.0)
	var pos := start.lerp(home, u)
	pos.y = lerpf(start.y, home.y, u) + 4.0 * ARC_M * u * (1.0 - u)
	p.global_position = pos
	p.velocity = Vector3.ZERO
	var since := time - (t0 + FLIGHT_SEC)
	if since < 0.0:
		tilt(p.humanoid, lerpf(0.25, PI * 0.5, smoothstep(0.0, 0.95, u)), smoothstep(0.8, 1.0, u), (0.2 + 0.1 * float(i)) * sin(u * TAU))
		flail(p.humanoid, time, 1.9 * float(i))
	else:
		var up := smoothstep(STILL_SEC, STILL_SEC + GET_UP_SEC, since)
		tilt(p.humanoid, lerpf(PI * 0.5, 0.0, up), 1.0 - up)
		p.humanoid.clear_hand(0)
		p.humanoid.clear_hand(1)


func _camera(time: float) -> void:
	if time >= T_BACK:
		camera.global_transform = local_eye()
		camera.fov = local_fov()
	elif time >= T_CUT:
		var k := (time - T_CUT) / (T_BACK - T_CUT)
		var eye := Vector3(0.3 + 0.03 * sin(time * 1.1), 1.5, -4.9 - 0.4 * k)
		camera.global_transform = CutsceneKit.look_from(eye, Vector3(0.35, 1.3, -6.85))
		camera.fov = 68.0 - 8.0 * smoothstep(0.0, 1.0, k)
	else:
		var sway := Vector3(0.05 * sin(time * 1.3), 0.03 * sin(time * 1.9 + 1.0), -0.12 * time)
		camera.global_transform = CutsceneKit.look_from(Vector3(0.0, 1.6, 5.4) + sway, Vector3(0.0, 1.4, -6.6))
		camera.fov = 66.0


func _on_end(_skipped: bool) -> void:
	_show_rigs()
	if _door != null:
		_door.set_openness(0.0)
		_door.set_bolt(1.0)
	for m: Dictionary in members:
		var p: Player = m.player
		if is_instance_valid(p):
			p.global_position = m.home
	_release_crew()
