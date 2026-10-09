class_name Bartender
extends Node3D
## The NPC behind the counter (06 P17 — the menu itself is the counter props'). The `Humanoid` body in its barkeep
## quirk (06 P24); idle life: breathing (Humanoid), the head follows the nearest player within LOOK_RANGE_M, and every
## few seconds the right hand wipes the counter. He also talks unprompted (`BartenderChat`): a speech bubble, gibberish
## blips and an arm gesture per line. Faces -Z like every Humanoid: place him with his back to the wall.

const LOOK_RANGE_M := 4.0
const WIPE_EVERY := Vector2(6.0, 12.0)  ## seconds between wipes, min / max
const WIPE_SEC := 3.0
const COUNTER_Y := 1.08                 ## top of the counter
const GESTURE_MAX_SEC := 2.8
const WIPE_AT := Vector3(0.18, COUNTER_Y, -0.58)  ## centre of the circle, in this node's space

@export var skin: CharacterSkin

var _look := Vector2.ZERO
var _wipe_in := 4.0
var _wipe_t := -1.0
var _gesture := &""
var _gesture_t := 0.0
var _talk_left := 0.0

@onready var _humanoid: Humanoid = $Humanoid
@onready var chat: BartenderChat = $Chat
@onready var bubble: SpeechBubble = $Bubble
@onready var voice: BartenderVoice = $Voice


func _ready() -> void:
	if skin != null:
		_humanoid.apply_skin(skin)
	_humanoid.set_quirk(Humanoid.QUIRK_BARKEEP)
	chat.said.connect(_on_said)
	chat.bind(owner if owner != null else get_tree().current_scene)


func _on_said(text: String, pool: StringName) -> void:
	var seconds := BartenderChat.line_seconds(text)
	bubble.show_line(text, seconds)
	voice.speak(text)
	_gesture = BartenderLines.GESTURE.get(pool, &"cheer")
	_gesture_t = 0.0
	_talk_left = minf(seconds, GESTURE_MAX_SEC)
	_wipe_t = -1.0
	_humanoid.clear_hand(0)
	_humanoid.clear_hand(1)


func _process(delta: float) -> void:
	var goal := Vector2.ZERO
	var near := LOOK_RANGE_M
	for p: Node3D in get_tree().get_nodes_in_group(&"players"):
		var d := Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()
		if d <= near:
			near = d
			goal = _humanoid.look_angles(p.global_position + Vector3(0.0, 1.5, 0.0))
	_look = _look.lerp(goal, 1.0 - exp(-4.0 * delta))
	if _talk_left > 0.0:
		_talk_left -= delta
		_gesture_t += delta
		_humanoid.set_look(_look.x + 0.10 * sin(_gesture_t * 5.5), _look.y + 0.07 * sin(_gesture_t * 8.3))
		_step_gesture()
		if _talk_left <= 0.0:
			_gesture = &""
			_humanoid.clear_hand(0)
			_humanoid.clear_hand(1)
			_wipe_in = randf_range(WIPE_EVERY.x, WIPE_EVERY.y)
		return
	_humanoid.set_look(_look.x, _look.y)
	if _wipe_t >= 0.0:
		_wipe_t += delta
		if _wipe_t >= WIPE_SEC:
			_wipe_t = -1.0
			_wipe_in = randf_range(WIPE_EVERY.x, WIPE_EVERY.y)
			_humanoid.clear_hand(0)
		else:
			var a := _wipe_t * TAU * 1.2
			_humanoid.set_hand(0, WIPE_AT + Vector3(cos(a) * 0.09, 0.0, sin(a) * 0.07))
	else:
		_wipe_in -= delta
		if _wipe_in <= 0.0:
			_wipe_t = 0.0


## The arm programs behind each line (BartenderLines.GESTURE). Targets are in the humanoid's space; he faces -Z.
func _step_gesture() -> void:
	var t := _gesture_t
	match _gesture:
		&"cheer":  # both arms up, shaking
			_humanoid.set_hand(0, Vector3(0.30, 1.88 + 0.07 * sin(t * 9.0), -0.15))
			_humanoid.set_hand(1, Vector3(-0.30, 1.88 + 0.07 * sin(t * 9.0 + 1.6), -0.15))
		&"flourish":  # the right hand circles over the hat, the left on the hip
			var a := t * 7.0
			_humanoid.set_hand(0, Vector3(0.22 + 0.16 * cos(a), 1.95 + 0.10 * sin(a), -0.12))
			_humanoid.set_hand(1, Vector3(-0.27, 0.99, -0.02))
		&"sweep":  # a presenting arm across the counter
			var k := smoothstep(0.0, 1.0, fmod(t * 0.6, 1.0))
			_humanoid.set_hand(0, Vector3(lerpf(-0.30, 0.65, k), 1.40, -0.48))
			_humanoid.set_hand(1, Vector3(-0.40, 1.25, -0.30))
		&"shrug":  # palms out, shoulders going
			_humanoid.set_hand(0, Vector3(0.55, 1.20 + 0.05 * sin(t * 6.0), -0.30))
			_humanoid.set_hand(1, Vector3(-0.55, 1.20 + 0.05 * sin(t * 6.0), -0.30))
		_:  # &"hip": hands on hips, head doing the talking
			_humanoid.set_hand(0, Vector3(0.27, 0.99, -0.02))
			_humanoid.set_hand(1, Vector3(-0.27, 0.99, -0.02))
