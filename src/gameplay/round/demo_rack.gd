extends Node3D

## Demo-only rack: triangle of 10 object balls on the foot spot, cue ball in the kitchen.
## ponytail: hand-placed; RoundDirector + PoissonDrop replace this in the Round milestone.

@export var table: Table
@export var ball_scene: PackedScene = preload("res://src/gameplay/balls/Ball.tscn")

const TYPES := {
	cue = preload("res://src/resources/ball_types/cue.tres"),
	red = preload("res://src/resources/ball_types/red_basic.tres"),
	blue = preload("res://src/resources/ball_types/blue_mid.tres"),
	gold = preload("res://src/resources/ball_types/gold_prize.tres"),
	black = preload("res://src/resources/ball_types/black_penalty.tres"),
}
const RACK: Array[String] = ["red", "blue", "red", "red", "gold", "blue", "red", "black", "red", "blue"]


func _ready() -> void:
	spawn()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		spawn()


func spawn() -> void:
	for c in get_children():
		c.queue_free()
	var s := table.spec
	var r := s.ball_radius_m
	var y := table.global_position.y + s.bed_height_m + r + 0.002
	var gap := r * 2.0 + 0.001
	var foot := Vector3(table.global_position.x + s.length_m * 0.25, y, table.global_position.z)
	var i := 0
	for row in range(4):
		for k in range(row + 1):
			if i >= RACK.size():
				break
			var pos := foot + Vector3(row * gap * 0.866, 0.0, (k - row * 0.5) * gap)
			_spawn(TYPES[RACK[i]], pos, i + 1)
			i += 1
	_spawn(TYPES.cue, Vector3(table.global_position.x - s.length_m * 0.25, y, table.global_position.z), 0)


func _spawn(type: BallType, pos: Vector3, index: int) -> void:
	var b: Ball = ball_scene.instantiate()
	b.ball_type = type
	b.spec = table.spec
	b.spawn_index = index
	b.id = "%s_%d" % [type.id, index]
	add_child(b)
	b.global_position = pos
