class_name RoundDirector
extends Node

## Shot/scoring brain of a Round (01 §3–§4): seeded rack, one live Shot at a time, contact log,
## foul + kitchen respawn, tricks, table_cleared. Every foul, respawn and trick is resolved on
## PhysicsSim.all_resting, BEFORE `shot_ended`, so consumers see a finished, legal table.
## Balls are its children; shot_id = "<round_id>-s<n>" counted from 1.

signal rack_ready(seed: int)
signal shot_started(shot_id: String, shooter_id: int)
signal ball_potted(ball: Ball, shot_id: String, pocket_id: StringName)
signal trick_detected(trick: TrickShot, shot_id: String)
signal shot_ended(shot_id: String, shooter_id: int, raw_points: int, trick_ids: Array[StringName], foul: bool)
signal table_cleared(round_id: String)
## reason: &"scratch" | &"wedged" | &"off_table" — the cue ball was put back in the kitchen.
signal cue_respawned(reason: StringName)

const CUE_TYPE := preload("res://src/resources/ball_types/cue.tres")
const SHOT_CEILING_SEC := 12.0  # 01 §3: past this every ball is stilled and the shot resolves anyway
const WEDGE_DIRECTIONS := 16
const OFF_TABLE_RADII := 2.0    # past the nose rectangle by this many radii = off the table (A3)

@export var table: Table
@export var cue: Node  # CueController — gets `gate` installed
@export var ball_scene: PackedScene = preload("res://src/gameplay/balls/Ball.tscn")

var shot_in_progress := false

var _round_id := ""
var _seed := 0
var _shot_index := 0
var _round_active := false
var _balls: Array[Ball] = []
var _cue_ball: Ball
var _log := ContactLog.new()
var _shot_id := ""
var _shooter_id := 0
var _shot_time := 0.0
var _potted: Array[Ball] = []
var _off_table: Array[Ball] = []  # left the table this shot and not yet put back
var _rest_pos: Dictionary = {}    # Ball -> Vector2 table-local, taken as the shot opens


func _ready() -> void:
	set_physics_process(false)
	if not table.is_node_ready():
		await table.ready
	table.sim.shot_started.connect(_on_sim_shot_started)
	table.sim.all_resting.connect(_on_all_resting)
	table.ball_dropped.connect(_on_ball_dropped)
	if cue != null:
		cue.set(&"gate", can_strike)


## A strike is legal on the cue ball only, and only between shots.
func can_strike(ball: Ball) -> bool:
	return _round_active and not shot_in_progress and _balls.has(ball) and ball.is_cue_ball


func get_balls() -> Array[Ball]:
	return _balls.duplicate()


func start_round(config: NightConfig, round_index: int, seed: int) -> void:
	assert(not shot_in_progress, "start_round during a live shot")
	_clear_balls()
	_round_id = "n%d-r%d" % [config.night_number, round_index]
	_seed = seed
	_shot_index = 0
	var head: Vector3 = table.layout.spots.head
	_cue_ball = _spawn(CUE_TYPE, Vector2(head.x, head.z), 0)
	var i := 1
	for entry in RackDropper.drop(table.spec, table.layout, config, seed):
		_spawn(entry.type, entry.pos, i)
		i += 1
	_round_active = true
	rack_ready.emit(seed)


## Freezes the table where it stands (visible through Intermission); start_round clears it.
func end_round() -> void:
	assert(not shot_in_progress, "end_round during a live shot")
	_round_active = false
	for b in _balls:
		b.freeze = true


## True when the resting cue ball cannot move in any of 16 sampled directions (01 §3).
func is_cue_wedged() -> bool:
	if _cue_ball == null or _cue_ball.is_pocketed:
		return false
	var step := table.spec.clearance_margin_m
	for i in WEDGE_DIRECTIONS:
		var motion := Vector3.RIGHT.rotated(Vector3.UP, TAU * i / WEDGE_DIRECTIONS) * step
		if not _cue_ball.test_move(_cue_ball.global_transform, motion):
			return false
	return true


func _physics_process(delta: float) -> void:
	_shot_time += delta
	_retire_off_table()
	if _shot_time > SHOT_CEILING_SEC:
		for b in _balls:
			b.linear_velocity = Vector3.ZERO  # Ball._integrate_forces snaps a still ball to rest
			b.angular_velocity = Vector3.ZERO


func _spawn(type: BallType, pos: Vector2, index: int) -> Ball:
	var b: Ball = ball_scene.instantiate()
	b.ball_type = type
	b.spec = table.spec
	b.spawn_index = index
	b.net_id = index  # wire id: cue 0, rack balls 1.. in spawn order, identical on every peer
	b.id = "%s_%d" % [type.id, index]
	add_child(b)
	b.global_position = _world(pos, b)
	table.sim.register(b)
	b.contacted.connect(_on_contacted)
	_balls.append(b)
	return b


func _clear_balls() -> void:
	for b in _balls:
		remove_child(b)  # out of the tree now, so PhysicsSim forgets it this frame
		b.queue_free()
	_balls.clear()
	_cue_ball = null
	_potted.clear()
	_off_table.clear()


func _world(p: Vector2, ball: Ball) -> Vector3:
	return table.to_global(Vector3(p.x, table.cloth_y() + ball.radius + table.spec.clearance_margin_m, p.y))


func _local(ball: Ball) -> Vector2:
	var p := table.to_local(ball.global_position)
	return Vector2(p.x, p.z)


func _on_sim_shot_started(_ball: Ball, intent: ShotIntent) -> void:
	if shot_in_progress or not _round_active:
		return  # a strike that got past the gate opens no second shot
	shot_in_progress = true
	_shot_index += 1
	_shot_id = "%s-s%d" % [_round_id, _shot_index]
	_shooter_id = intent.shooter_id
	_shot_time = 0.0
	_log.clear()
	_potted.clear()
	_off_table.clear()
	_rest_pos.clear()
	for b in _balls:
		if not b.is_pocketed:
			_rest_pos[b] = _local(b)
	set_physics_process(true)
	shot_started.emit(_shot_id, _shooter_id)


func _on_contacted(ball: Ball, other: Node, kind: StringName) -> void:
	if not shot_in_progress:
		return
	if kind == ContactLog.RAIL:
		_log.add_rail(ball, other.get_meta(&"rail_id", &""))
	elif other is Ball:
		_log.add_ball(ball, other)


func _on_ball_dropped(ball: Ball, pocket_id: StringName) -> void:
	if not shot_in_progress or not _balls.has(ball):
		return
	_log.add_pocket(ball, pocket_id)
	if not ball.is_cue_ball:
		_potted.append(ball)
		ball_potted.emit(ball, _shot_id, pocket_id)


func _is_off_table(ball: Ball) -> bool:
	var s := table.spec
	var p := table.to_local(ball.global_position)
	var margin := OFF_TABLE_RADII * s.ball_radius_m
	return absf(p.x) > s.length_m * 0.5 + margin \
		or absf(p.z) > s.width_m * 0.5 + margin \
		or p.y < table.cloth_y() - s.ball_radius_m


## Out-of-bounds balls are logged and retired the moment they leave, so the shot can settle.
func _retire_off_table() -> void:
	for b in _balls:
		if not b.is_pocketed and not _off_table.has(b) and _is_off_table(b):
			_off_table.append(b)
			_log.add_off_table(b)
			b.retire()


func _on_all_resting() -> void:
	if not shot_in_progress:
		return
	_retire_off_table()
	var scratched := false
	var whiffed := true
	for e in _log.entries:
		if e.kind == ContactLog.POCKET and e.a == _cue_ball:
			scratched = true
		elif e.kind == ContactLog.BALL and e.a == _cue_ball:
			whiffed = false
	var foul := whiffed or scratched or not _off_table.is_empty()

	var cue_reason := &"scratch" if scratched else &""
	for b in _off_table.duplicate():
		if b.is_cue_ball:
			cue_reason = &"off_table"
		else:
			_respawn_object(b)
	if cue_reason == &"" and is_cue_wedged():
		cue_reason = &"wedged"  # no foul, no shot cost — just freed
	if cue_reason != &"":
		_respawn_cue(cue_reason)

	var raw_points := 0
	var trick_ids: Array[StringName] = []
	if not foul:
		for b in _potted:
			raw_points += b.ball_type.base_value
		for t in TrickDetector.detect(_log, _cue_ball, _shot_id):
			trick_ids.append(t.id)
			trick_detected.emit(t, _shot_id)

	var cleared := is_table_cleared()
	var round_id := _round_id
	var shot_id := _shot_id
	var shooter_id := _shooter_id
	shot_in_progress = false
	set_physics_process(false)
	shot_ended.emit(shot_id, shooter_id, raw_points, trick_ids, foul)
	if cleared:
		table_cleared.emit(round_id)


## No ball that counts for clear and is worth points is still on the table (01 §3).
func is_table_cleared() -> bool:
	for b in _balls:
		if b.ball_type.counts_for_clear and b.ball_type.base_value > 0 and not b.is_pocketed:
			return false
	return true


## Table-local positions of every ball still on the cloth except `skip`.
func _positions_except(skip: Ball) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for b in _balls:
		if b != skip and not b.is_pocketed and not _off_table.has(b):
			out.append(_local(b))
	return out


func _respawn_seed(ball: Ball) -> int:
	return hash([_seed, _shot_index, ball.spawn_index])


## Back at its last resting spot, or the nearest clear one if another ball has settled there.
func _respawn_object(ball: Ball) -> void:
	var spot := RackDropper.place_near(table.spec, table.layout, _rest_pos[ball], RackDropper.interior(table.spec), _positions_except(ball), _respawn_seed(ball))
	_off_table.erase(ball)
	ball.restore(_world(spot, ball))


func _respawn_cue(reason: StringName) -> void:
	var head: Vector3 = table.layout.spots.head
	var spot := RackDropper.place_near(table.spec, table.layout, Vector2(head.x, head.z), RackDropper.kitchen(table.spec), _positions_except(_cue_ball), _respawn_seed(_cue_ball))
	_off_table.erase(_cue_ball)
	_cue_ball.restore(_world(spot, _cue_ball))
	cue_respawned.emit(reason)
