class_name RoomCutscene
extends Cutscene
## Base of the cutscenes that play IN the bar (docs/plan/09 §3.8, adhoc-1013c F3b): the intro's throw, the failure's red alert, the win's gas.
## They are the same Cutscene as the standalone scenes (own camera, shell, Skip, restore) but `on_stage` is false, and they are handed the
## MainLevel (`opts["level"]`) to work its fixtures: the door, the TV, the mirror, the Trapdoor, the Vent, Gus.
##
## THE CREW. Every peer places EVERY player itself, from the shared timeline: the local walker stops simulating (`_physics_process` off) and the
## puppets stop following the pose stream (`_process` off) while a beat runs, so what each peer sees is a pure function of the seat and the time
## (the owner's stream is ignored for the duration and agrees with it when the beat ends). Throws, pulls and falls are scripted tweens of the
## Player node plus a tilt of its Humanoid about its middle; no ragdoll, no collision (a body flies over the table). `_release_crew()` puts it all back.

const SPOT_R := 0.75  ## the crew stands on the Trapdoor in a ring this wide when it is pulled onto it
const FALL_DELAY := 0.15  ## seconds after the fall starts before the first body drops (the leaves are already swinging away)
const FALL_GRAVITY := 14.0
const THROAT_M := 6.0  ## how far down the monster's throat a body goes before it is gone
const BODY_CENTRE := Vector3(0.0, 0.95, 0.0)  ## a Humanoid tumbles about its middle (feet at its origin, 1.9 m tall)
const LIE_SINK := 0.8  ## a body lying on the floor: its middle is 15 cm up

var level: Node  ## the MainLevel root
var members: Array = []  ## [{player: Player, seat: int, local: bool, home: Vector3}] in seat order

var _fired := {}


func configure(opts: Dictionary) -> void:
	super(opts)
	level = opts.get("level", null) as Node
	on_stage = false
	fade_in = 0.0
	fade_out = 0.0


## Takes the crew out of the game's hands (see above). Subclasses call super() first, or `_collect_crew()` alone when they only watch.
func _build() -> void:
	_collect_crew()
	_take_crew()


func _collect_crew() -> void:
	members = crew_of(level)


func _take_crew() -> void:
	for m: Dictionary in members:
		var p: Player = m.player
		m["home"] = p.global_position
		_stand_down(m)
		if bool(m.local):
			p.set_physics_process(false)
		else:
			p.set_process(false)
		p.humanoid.set_physics_process(false)
		p.velocity = Vector3.ZERO


## Everyone back to the game: the Player nodes where they stand now, upright, hands free, simulating / following the stream again.
func _release_crew() -> void:
	for m: Dictionary in members:
		var p: Player = m.player
		if not is_instance_valid(p):
			continue
		p.visible = true
		p.humanoid.transform = Transform3D.IDENTITY
		p.humanoid.clear_hand(0)
		p.humanoid.clear_hand(1)
		p.humanoid.set_physics_process(true)
		p.velocity = Vector3.ZERO
		if bool(m.local):
			p.set_physics_process(true)
		else:
			p.set_process(true)


## A player who is aiming or sitting when the beat starts is put on their feet first (local walker only; a puppet only needs its pose).
func _stand_down(m: Dictionary) -> void:
	var p: Player = m.player
	if bool(m.local):
		if p.mode == Player.Mode.CUE:
			p.exit_cue(false)
		if p.seated:
			p.stand_up()
	p.humanoid.stance = Humanoid.Stance.STAND
	p.humanoid.clear_cue_rig()


## A fixture of the level by path under the MainLevel root, or null (a probe's bare level).
func _node(path: NodePath) -> Node:
	return level.get_node_or_null(path) if level != null else null


## The local player's own eye (its Head/headCam): where a beat that watches from the player's view starts.
func local_eye() -> Transform3D:
	for m: Dictionary in members:
		if bool(m.local):
			return (m.player as Player).cam.global_transform
	return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0))


func local_fov() -> float:
	for m: Dictionary in members:
		if bool(m.local):
			return (m.player as Player).cam.fov
	return 70.0


## True the first time it is asked for `key`: a sound or a switch that must happen once however big the clock's steps are.
func _once(key: StringName) -> bool:
	if _fired.has(key):
		return false
	_fired[key] = true
	return true


## The Player of every slot in `level_root`, with its seat, in seat order. Empty when there is no level.
static func crew_of(level_root: Node) -> Array:
	var out: Array = []
	if level_root == null:
		return out
	var slots := level_root.get_node_or_null(^"PlayerSlots")
	if slots == null:
		return out
	var seats := {}
	var net := level_root.get_node_or_null(^"/root/NetManager")  # by path: `-s` probes compile this before the autoload exists
	if net != null:
		for e: Dictionary in net.call(&"get_roster"):
			seats[int(e.peer_id)] = int(e.seat)
	for s in slots.get_children():
		var slot := s as PlayerSlot
		if slot == null or slot.player == null:
			continue
		out.append({"player": slot.player, "seat": int(seats.get(slot.peer_id, out.size())), "local": slot.is_local(), "home": slot.player.global_position})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seat) < int(b.seat))
	return out


## Seat `i` of `n` when the crew stands on the Trapdoor: the floor of the hole's middle, a ring round it (the one body at the middle).
static func pull_spot(i: int, n: int) -> Vector3:
	if n <= 1:
		return Trapdoor.HOLE_CENTER
	var a := TAU * float(i) / float(n) + PI * 0.25
	return Trapdoor.HOLE_CENTER + Vector3(cos(a), 0.0, sin(a)) * SPOT_R


## Tilts a Humanoid about its middle: `lean` radians about X (positive: head toward +Z, i.e. falling backwards when it faces -Z), `roll`
## about Z, and `lie` 0..1 sinks it onto the floor so a body lying down rests on it instead of hovering half a metre above it.
static func tilt(h: Humanoid, lean: float, lie: float, roll := 0.0) -> void:
	var b := Basis.from_euler(Vector3(lean, 0.0, roll))
	h.transform = Transform3D(b, BODY_CENTRE - b * BODY_CENTRE + Vector3(0.0, -LIE_SINK * lie, 0.0))


## Both arms flung up and shaking (the Humanoid's two-bone IK reaches the points).
static func flail(h: Humanoid, time: float, phase: float) -> void:
	h.set_hand(0, Vector3(0.36, 1.85 + 0.2 * sin(time * 9.0 + phase), -0.15))
	h.set_hand(1, Vector3(-0.36, 1.85 + 0.2 * sin(time * 9.0 + phase + 1.7), -0.15))


## Member `i` of `n` `time` seconds into the fall: free fall from its spot through the open floor, down the monster's throat (it narrows,
## so the ring closes in), tumbling with its arms up. A pure function of `time`: the director calls it for every body from FallCam's clock.
static func drop_member(m: Dictionary, i: int, n: int, time: float) -> void:
	var p: Player = m.player
	var spot := pull_spot(i, n)
	var fall_t := maxf(time - FALL_DELAY - 0.04 * float(i), 0.0)
	var depth := minf(0.5 * FALL_GRAVITY * fall_t * fall_t, Trapdoor.SHAFT_DEPTH + THROAT_M)
	var squeeze := 1.0 - 0.8 * clampf((depth - Trapdoor.SHAFT_DEPTH) / THROAT_M, 0.0, 1.0)
	var c := Trapdoor.HOLE_CENTER
	p.global_position = Vector3(c.x + (spot.x - c.x) * squeeze, -depth, c.z + (spot.z - c.z) * squeeze)
	p.velocity = Vector3.ZERO
	tilt(p.humanoid, time * (1.0 + 0.5 * float(i)), 0.0, time * (0.5 + 0.4 * float(i)))
	flail(p.humanoid, time, 1.9 * float(i))
