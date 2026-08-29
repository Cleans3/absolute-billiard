class_name TableSpec
extends Resource

## Table geometry and cloth feel (01 §2). Every value is [tune]; nothing writes this at runtime.

@export var length_m := 2.54
@export var width_m := 1.27
@export var ball_radius_m := 0.0286
@export var rail_height_m := 0.09
@export var cushion_restitution := 0.86
@export var cushion_friction := 0.18
@export var cloth_friction := 0.20
@export var rolling_resistance := 0.020
@export var spin_decay := 0.55
@export var rest_speed_mps := 0.02
@export var rest_time_sec := 0.30
@export var clearance_margin_m := 0.002
@export var kitchen_line_x := -0.635
@export var jaw_radius_m := 0.012
@export var jaw_restitution := 0.55
@export var corner_mouth_m := 0.114
@export var side_mouth_m := 0.127
@export var bed_height_m := 0.80
