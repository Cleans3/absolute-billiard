class_name TableSpec
extends Resource

## Table geometry and cloth feel (01 §2, plan.md contract). Every geometric value is
## `REG_* × scale`; nothing writes this at runtime. Feel values below are tuned directly and do
## not scale. `bed_height_m` is player-relative, not scale-relative (intent.md: real bed height
## × scale reads chest-high on a real-height player).

## regulation reference, 9-ft WPA table, metres/degrees
const REG_LENGTH := 2.54
const REG_WIDTH := 1.27
const REG_BALL_RADIUS := 0.028575
## Mouth = the tip-to-tip gap between the two cushion noses at a pocket, what a player sees (06 P30). Past
## regulation on purpose (reg. corner ~2.06 D, side ~2.27 D): both 2.8 D here, floors are corner 2.5 D / side 2.7 D.
const REG_CORNER_MOUTH := 0.160
const REG_SIDE_MOUTH := 0.160
const REG_CUSHION_NOSE_H := 0.036
const REG_RAIL_WIDTH := 0.178
const REG_RAIL_TOP_H := 0.042
const REG_APRON_H := 0.18
const REG_JAW_RADIUS := 0.012
const REG_CORNER_SHELF := 0.04
const REG_SIDE_SHELF := 0.005
const REG_CORNER_FACING_DEG := 142.0
const REG_SIDE_FACING_DEG := 103.0
const REG_CUE_REACH := 1.75
## Pocket cups (06 P30): the bed is cut open at every pocket and a cup hangs below the cut.
const CUP_DEPTH_RADII := 5.0   # cup floor below the cloth, in ball radii (>= 2 D)
const POT_DEPTH_RADII := 1.5   # a ball is potted once its centre is this far below the cloth top, inside a cup
const REG_BED_THICKNESS := 0.01

@export var scale := 2.0

## player-relative: eye 1.8 m -> 0.9 m above the cloth, like a real table under a real person.
@export var bed_height_m := 0.9

@export var cushion_restitution := 0.86       # e0: soft hits
@export var cushion_restitution_min := 0.26   # e at cushion_hard_speed_mps and above
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
@export var clearance_margin_m := 0.003
@export var jaw_restitution := 0.55
## scale-invariant ceiling matching CueSpec.power_cap_speed_mps (01 §3 default 10.0) — thin static
## colliders (jaw facings, cushions) are floored against this ÷ PhysicsSim.LIVE_TICK so a
## full-power shot can never cross one in a single physics step, at any scale (loop-1 T4.8: CCD
## alone does not stop a bad contact when the swept collider is smaller than the step — Jolt's own
## ghost-collision mitigation only applies within one body, not at the seam between two separate
## StaticBody3D, which is exactly where cushion meets facing).
@export var max_ball_speed_mps := 10.0

## derived — names kept so existing callers do not change
## Object balls get CCD only above the speed where one physics step covers CCD_STEP_RADII of a ball radius:
## discrete detection stops catching cushion/ball contacts cleanly when a step approaches R (07 §1.2). Probed at
## scale 2.0 / 120 Hz: CCD off above 5 m/s (~0.7 R per step) is fine, above 7 m/s (~1.0 R) the round probe's bank
## shot loses its rail contact. The old flat 3.0 m/s was tuned at scale 1.0, where this formula gives 2.7.
const CCD_STEP_RADII := 0.8
var ccd_speed_mps: float:
	get: return CCD_STEP_RADII * ball_radius_m * PhysicsSim.LIVE_TICK
var length_m: float:
	get: return REG_LENGTH * scale
var width_m: float:
	get: return REG_WIDTH * scale
var ball_radius_m: float:
	get: return REG_BALL_RADIUS * scale
var corner_mouth_m: float:
	get: return REG_CORNER_MOUTH * scale
var side_mouth_m: float:
	get: return REG_SIDE_MOUTH * scale
var jaw_radius_m: float:
	get: return REG_JAW_RADIUS * scale
var kitchen_line_x: float:
	get: return -length_m / 4.0
var rail_height_m: float:
	get: return REG_RAIL_TOP_H * scale

## derived — new
var cushion_nose_h_m: float:
	get: return REG_CUSHION_NOSE_H * scale
var rail_width_m: float:
	get: return REG_RAIL_WIDTH * scale
var apron_h_m: float:
	get: return REG_APRON_H * scale
var corner_shelf_m: float:
	get: return REG_CORNER_SHELF * scale
var side_shelf_m: float:
	get: return REG_SIDE_SHELF * scale
var foot_spot_x: float:
	get: return length_m / 4.0
var cue_reach_m: float:
	get: return REG_CUE_REACH * scale
var cup_depth_m: float:
	get: return CUP_DEPTH_RADII * ball_radius_m
var pot_depth_m: float:
	get: return POT_DEPTH_RADII * ball_radius_m
var bed_thickness_m: float:
	get: return REG_BED_THICKNESS * scale


## 01 §3 "Cushions": restitution falls with normal impact speed so hard hits rebound flatter.
func cushion_restitution_at(normal_speed: float) -> float:
	var t := clampf((normal_speed - cushion_soft_speed_mps) / (cushion_hard_speed_mps - cushion_soft_speed_mps), 0.0, 1.0)
	return lerpf(cushion_restitution, cushion_restitution_min, t)
