class_name CueSpec
extends Resource

## J = m × speed_at(power) (01 §3); a speed, so it is scale-invariant. 20 = about twice a real break (8-12 m/s) on a table that is 2x regulation.
@export var power_cap_speed_mps := 20.0
## Share of the cap carried by the cubic term of the power curve: 0 = linear, 0.5 keeps the low half of the slider at the old
## 10 m/s feel and spends the extra range on the top (a half-charge shot is no faster than before, a full charge is twice as fast).
@export_range(0.0, 1.0, 0.01) var power_top_boost := 0.5
@export var spin_offset_radius := 0.35
@export var jump_unlocked := false
@export var masse_unlocked := false
@export var wobble_reduction := 0.0
@export var miscue_threshold := 0.92


## Launch speed (m/s) of a strike at slider `power`; a stat can push `power` past 1 (TableSpec.max_ball_speed_mps is the ceiling).
func speed_at(power: float) -> float:
	var p := maxf(power, 0.0)
	return power_cap_speed_mps * lerpf(p, p * p * p, power_top_boost)
