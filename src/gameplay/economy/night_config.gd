class_name NightConfig
extends Resource
## One Night's tuning (docs/plan/02 §2). Three .tres under src/resources/nights/ (the Campaign); GameLoop iterates them
## and generates Endless Nights 4+ from the last one. Every number below is one field: calibration edits the .tres.

@export var night_number := 1
@export var quota := 400  # PROVISIONAL (02 §3.4)
@export var rounds_count := 3
@export var round_time_limit_sec := 300.0  # PROVISIONAL, never under ROUND_TIME_MIN_SEC (02 §3.1)
@export var fine_rate := 0.04  # scratch fine = this share of `quota` (EconomyManager.fine_for, 02 §3.8); PROVISIONAL
@export var shots_per_round := 10
@export var object_ball_count := 10
@export var base_viewers := 100
@export var hazard_tiers: Array[int] = [0, 1, 2]
@export var unlocked_ball_types: Array[StringName] = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]  # the .tres Nights start at tier 1 + penalty; the Shop adds the rest
@export var story: StoryNight  # the Night's cards, phone call, Gus lines and ending text (09); presentation only
## Hand-authored racks by Round (index = round - 1); a missing entry falls back to the seeded drop.
@export var authored_racks: Array[RackLayout] = []
## The Campaign's last Night plays these instead (GameLoop._start_round, the Buyout Night); Endless never does.
@export var finale_racks: Array[RackLayout] = []


const ENDLESS_QUOTA_MULT := 1.6  # strictly above the campaign's ×1.5 (02 §3.4)
const ENDLESS_VIEWERS_STEP := 300
const ENDLESS_FINE_RATE := 0.10  # Endless Nights fine at the full rate (02 §3.8)
const ENDLESS_TIME_STEP_SEC := 15.0  # each Endless Night's Rounds are this much shorter ...
const ROUND_TIME_MIN_SEC := 120.0  # ... down to the floor
const ENDLESS_STORY := preload("res://src/resources/story/endless.tres")


## Endless Night 4+: Night `night_number` generated from the last authored Night's plain (non-finale) numbers. Hazard
## tiers become 1 / 2 / 3, racks are seeded drops, the fine is the full rate, Rounds shorten to the floor.
static func endless(last: NightConfig, night_number: int) -> NightConfig:
	var steps := night_number - last.night_number
	var c: NightConfig = last.duplicate()
	c.night_number = night_number
	c.quota = roundi(last.quota * pow(ENDLESS_QUOTA_MULT, steps))
	c.base_viewers = last.base_viewers + ENDLESS_VIEWERS_STEP * steps
	c.hazard_tiers = [1, 2, 3]
	c.fine_rate = ENDLESS_FINE_RATE
	c.round_time_limit_sec = maxf(ROUND_TIME_MIN_SEC, last.round_time_limit_sec - ENDLESS_TIME_STEP_SEC * steps)
	c.authored_racks = []
	c.finale_racks = []
	c.story = ENDLESS_STORY  # every Endless Night shares one story resource (09 §2.3)
	return c
