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
@export var unlocked_ball_types: Array[StringName] = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]  # the .tres Nights start at tier 1 + penalty; the Shop adds the rest


const ENDLESS_QUOTA_MULT := 1.6  # strictly above the campaign's ×1.5 (02 §3.4)
const ENDLESS_VIEWERS_STEP := 300


## Night 6+: Night `night_number` generated from the last authored Night. Hazard tiers become 1 / 2 / 3.
static func endless(last: NightConfig, night_number: int) -> NightConfig:
	var steps := night_number - last.night_number
	var c: NightConfig = last.duplicate()
	c.night_number = night_number
	c.quota = roundi(last.quota * pow(ENDLESS_QUOTA_MULT, steps))
	c.base_viewers = last.base_viewers + ENDLESS_VIEWERS_STEP * steps
	c.hazard_tiers = [1, 2, 3]
	return c
## Hand-authored racks by Round (index = round - 1); a missing entry falls back to the seeded drop.
@export var authored_racks: Array[RackLayout] = []
