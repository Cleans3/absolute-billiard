class_name Bartender
extends Node3D
## The NPC behind the counter (06 P17 — the menu itself is the counter props'). Same `Humanoid` body as the
## players; idle life: breathing (Humanoid), the head follows the nearest player within LOOK_RANGE_M, and every
## few seconds the right hand wipes the counter. Faces -Z like every Humanoid: place him with his back to the wall.

const LOOK_RANGE_M := 4.0
const WIPE_EVERY := Vector2(6.0, 12.0)  ## seconds between wipes, min / max
const WIPE_SEC := 3.0
const COUNTER_Y := 1.08                 ## top of the counter
const WIPE_AT := Vector3(0.18, COUNTER_Y, -0.58)  ## centre of the circle, in this node's space

@export var skin: CharacterSkin

var _look := Vector2.ZERO
var _wipe_in := 4.0
var _wipe_t := -1.0

@onready var _humanoid: Humanoid = $Humanoid


func _ready() -> void:
	if skin != null:
		_humanoid.apply_skin(skin)


func _process(delta: float) -> void:
	var goal := Vector2.ZERO
	var near := LOOK_RANGE_M
	for p: Node3D in get_tree().get_nodes_in_group(&"players"):
		var d := Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()
		if d <= near:
			near = d
			goal = _humanoid.look_angles(p.global_position + Vector3(0.0, 1.5, 0.0))
	_look = _look.lerp(goal, 1.0 - exp(-4.0 * delta))
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
