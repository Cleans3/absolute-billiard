class_name FailRoom
extends RoomCutscene
## Quota failure, part 1, IN the bar (docs/plan/09 §3.8.2, 06 P39 U17: "a red alert light appear in the middle of the room spinning flashing the
## room in red, all the screen goes black, and the mirror turns bloody; after 5 seconds the floor opens"). It runs from the local player's own
## eye: an AlertLight in the middle of the ceiling sweeps the room red (one realtime spot + a red wash on the screen), the wall TV and the slot
## machine go black, the mirror bleeds (`Mirror.set_blood` 0 -> 1), and the crew is pulled onto the Trapdoor. At 5 s it ends: the Trapdoor opens,
## the MonsterMouth in its Pit is revealed, and FallCam (the next part, same clock, same camera pose) drops through. It does not release the crew:
## the director drops the bodies (RoomCutscene.drop_member) from FallCam's clock. Skip ends it with none of that (the run is over anyway).
## Options: "mouth" (the MonsterMouth in the Pit), "drop_height" (as FallCam's).

const LENGTH_SEC := 5.0
const T_TV_OFF := 1.2
const T_SLOT_OFF := 1.7
const T_BLOOD_FROM := 1.4
const T_BLOOD_TO := 3.8
const T_PULL_FROM := 3.0
const T_PULL_TO := 4.85
const SPIN_HZ := 1.15
const RED := Color(1.0, 0.04, 0.03)

var mouth: MonsterMouth
var drop_height := Trapdoor.SHAFT_DEPTH + Player.EYE_M

var _alert: AlertLight
var _siren: AudioStreamPlayer
var _tv: StreamTv
var _mirror: Mirror
var _trapdoor: Trapdoor
var _cut: CutScreen
var _slots: Array[SlotMachine] = []
var _eye0 := Transform3D.IDENTITY
var _fov0 := 70.0


func id() -> StringName:
	return &"fail_room"


func length_sec() -> float:
	return LENGTH_SEC


func configure(opts: Dictionary) -> void:
	super(opts)
	mouth = opts.get("mouth", null) as MonsterMouth
	drop_height = float(opts.get("drop_height", drop_height))


func _build() -> void:
	super()
	_eye0 = local_eye()
	_fov0 = local_fov()
	_tv = _node(^"Tv") as StreamTv
	_mirror = _node(^"Mirror") as Mirror
	_trapdoor = _node(^"Trapdoor") as Trapdoor
	_cut = _node(^"UILayer/CutScreen") as CutScreen
	for n in get_tree().get_nodes_in_group(&"slot_machine"):
		var sm := n as SlotMachine
		if sm != null:
			_slots.append(sm)
	_alert = AlertLight.new()
	_alert.position = AlertLight.MOUNT
	add_child(_alert)
	_siren = CutsceneSfx.play(self, CutsceneSfx.Kind.ALARM, -10.0)


## S6 (adhoc-1014b): the beacon and its spot, and the red wash's screen pass, parked under `level` so that the first shown frame of the beat
## compiles nothing. Touches nothing of the world. The caller draws the returned node for two frames, then hides it and KEEPS it (freeing it
## frees the shaders and their pipelines). Null when there is no level.
static func prewarm(level: Node) -> Node:
	var warm := RoomPrewarm.make(level, &"FailPrewarm", RED, false)
	return warm.finish() if warm != null else null


func _update(time: float, _dt: float) -> void:
	var power := smoothstep(0.0, 0.4, time)
	_alert.pose(time, RED, power, SPIN_HZ)
	if _cut != null:
		var pulse := 0.5 + 0.5 * sin(TAU * SPIN_HZ * 2.0 * time)
		_cut.set_wash(RED, power * (0.12 + 0.3 * pulse))
	if time >= T_TV_OFF and _once(&"tv") and _tv != null:
		_tv.set_feeds_on(false)
	if time >= T_SLOT_OFF and _once(&"slots"):
		for sm in _slots:
			sm.set_power(false)
	if _mirror != null:
		_mirror.set_blood(smoothstep(T_BLOOD_FROM, T_BLOOD_TO, time))
	for i in members.size():
		var m: Dictionary = members[i]
		var p: Player = m.player
		var w := smoothstep(T_PULL_FROM + 0.12 * float(i), T_PULL_TO, time)
		var start: Vector3 = m.home
		var pos := start.lerp(RoomCutscene.pull_spot(i, members.size()), w)
		pos.y += 0.3 * sin(w * PI)  # dragged up a little off the boards
		p.global_position = pos
		p.velocity = Vector3.ZERO
		if w > 0.0:
			flail(p.humanoid, time, 1.9 * float(i))
	_camera(time, power)


## The player's eye, shaking with the alarm, until the pull; then it travels to where FallCam's first frame stands (above the hole, looking down).
func _camera(time: float, power: float) -> void:
	var w := smoothstep(T_PULL_FROM, T_PULL_TO, time)
	var end_pose := _eye0
	if mouth != null:
		end_pose = FallCam.camera_pose(mouth.global_transform, drop_height, 0.0)
	var xf := _eye0.interpolate_with(end_pose, w)
	xf.origin += Vector3(0.0, 0.012 * sin(time * 23.0) * power, 0.0)
	camera.global_transform = xf
	camera.fov = lerpf(_fov0, FallCam.fov_at(0.0), w)


func _on_end(skipped: bool) -> void:
	if _siren != null:
		_siren.stop()
	if _cut != null:
		_cut.clear()
	if skipped:
		return
	if _trapdoor != null:
		_trapdoor.open()
	if mouth != null:
		mouth.visible = true
