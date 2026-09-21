class_name NightConfig
extends Resource
## One Night's tuning (docs/plan/02 §2). Five .tres under src/resources/nights/; GameLoop iterates them.

@export var night_number := 1
@export var quota := 600
@export var rounds_count := 3
@export var round_time_limit_sec := 120.0
@export var shots_per_round := 10
@export var object_ball_count := 10
@export var base_viewers := 100
@export var hazard_tiers: Array[int] = [0, 1, 2]
@export var unlocked_ball_types: Array[StringName] = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]
