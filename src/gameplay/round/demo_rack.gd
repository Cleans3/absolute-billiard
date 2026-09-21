extends Node3D

## Demo-only rack: triangle of 10 object balls on the foot spot, cue ball in the kitchen.
## ponytail: hand-placed; RoundDirector + PoissonDrop replace this in the Round milestone.

signal spawned

@export var table: Table
@export var enabled := true  # off in MainLevel: RoundDirector owns the balls; debug presets still call spawn_layout()
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
	if enabled:
		spawn_layout(default_rack())


func _unhandled_input(event: InputEvent) -> void:
	if enabled and event.is_action_pressed("reset"):
		spawn_layout(default_rack())


func spawn() -> void:
	spawn_layout(default_rack())


## Standard 10-ball triangle on the foot spot, cue ball on the head spot. Table-local metres.
func default_rack() -> Array[Dictionary]:
	var s := table.spec
	var gap := s.ball_radius_m * 2.0 + s.clearance_margin_m
	var entries: Array[Dictionary] = []
	var i := 0
	for row in range(4):
		for k in range(row + 1):
			if i >= RACK.size():
				break
			entries.append({
				type = StringName(RACK[i]),
				x = s.foot_spot_x + row * gap * 0.866,
				z = (k - row * 0.5) * gap,
				index = i + 1,
			})
			i += 1
	entries.append({type = &"cue", x = s.kitchen_line_x, z = 0.0, index = 0})
	return entries


## entry = {type: StringName (BallType id in TYPES), x: float, z: float}, table-local metres,
## optional index: int.
func spawn_layout(entries: Array[Dictionary]) -> void:
	for c in get_children():
		c.queue_free()
	var s := table.spec
	var y := table.global_position.y + s.bed_height_m + s.ball_radius_m + s.clearance_margin_m
	for entry in entries:
		var type: BallType = TYPES[String(entry.type)]
		var pos := Vector3(table.global_position.x + entry.x, y, table.global_position.z + entry.z)
		_spawn(type, pos, entry.get("index", 0))
	spawned.emit()


func _spawn(type: BallType, pos: Vector3, index: int) -> void:
	var b: Ball = ball_scene.instantiate()
	b.ball_type = type
	b.spec = table.spec
	b.spawn_index = index
	b.id = "%s_%d" % [type.id, index]
	add_child(b)
	b.global_position = pos
	table.sim.register(b)
