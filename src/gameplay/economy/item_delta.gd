class_name ItemDelta
extends Resource
## What a non-drink ShopItem changes (docs/plan/02 §3.6). EconomyManager folds every owned delta.

@export var cue_power_cap_add := 0.0  # CueSpec.power_cap_speed_mps × (1 + Σ)
@export var cue_spin_radius_add := 0.0  # CueSpec.spin_offset_radius × (1 + Σ)
@export var cue_jump := false
@export var cue_masse := false
@export var cue_wobble_reduction := 0.0  # degrees
@export var ball_types: Array[StringName] = []  # BallType ids that enter the drop pool
@export var ball_values: Dictionary = {}  # BallType id -> replacement base_value
@export var camera_tier := 0  # rigs are raised to at least this tier
@export var extra_rigs := 0
@export var effects: Array[Effect] = []  # TABLE Effects, re-applied every Round at duration -1
@export var base_viewers_add := 0
@export var tip_rate_mult := 1.0
