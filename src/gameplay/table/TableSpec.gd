class_name TableSpec
extends Resource

## Table geometry and cloth feel (01 §2). Every value is [tune]; nothing writes this at runtime.
## Geometry is regulation × 1.5 so the table reads big in first person; mass follows radius (Ball.gd).

@export var length_m := 3.81
@export var width_m := 1.905
@export var ball_radius_m := 0.0429
@export var rail_height_m := 0.135
@export var cushion_restitution := 0.86       # e0: soft hits
@export var cushion_restitution_min := 0.20   # e at cushion_hard_speed_mps and above
@export var cushion_soft_speed_mps := 3.0     # normal speed below which e = e0
@export var cushion_hard_speed_mps := 7.5     # normal speed at which e = e_min
@export var cushion_friction := 0.18
@export var cloth_friction := 0.20
@export var ball_friction := 0.06             # ball–ball; cloth/rails are `rough` so theirs wins
@export var ball_restitution := 0.95          # ball–ball; cloth/rails are `absorbent`: e = this − theirs
@export var rolling_resistance := 0.035
@export var spin_decay := 0.55
@export var rest_speed_mps := 0.02
@export var rest_time_sec := 0.30
@export var ccd_speed_mps := 3.0              # object balls get CCD only above this (07 §1.2)
@export var clearance_margin_m := 0.003
@export var kitchen_line_x := -0.9525
@export var jaw_radius_m := 0.018
@export var jaw_restitution := 0.55
@export var corner_mouth_m := 0.171
@export var side_mouth_m := 0.19
@export var bed_height_m := 1.5               # 75% of the 2.0 m player capsule


## 01 §3 "Cushions": restitution falls with normal impact speed so hard hits rebound flatter.
func cushion_restitution_at(normal_speed: float) -> float:
	var t := clampf((normal_speed - cushion_soft_speed_mps) / (cushion_hard_speed_mps - cushion_soft_speed_mps), 0.0, 1.0)
	return lerpf(cushion_restitution, cushion_restitution_min, t)
