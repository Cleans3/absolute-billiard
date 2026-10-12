class_name FxCombo
extends RefCounted

## Combo / streak rules of the pot FX (docs/plan/10 §4). Presentation only: counts pots the host already decided, never
## scores them. `n` = pots so far in this Shot + consecutive earlier Shots that potted; the FX escalate with it.

const MAX_LEVEL := 8
const MIN_ANNOUNCE := 2  # "COMBO xN" shows from the second pot of the chain
const MIN_LOST := 2  # a streak this long is mourned when it breaks

var shot_pots := 0
var streak := 0  # completed Shots in a row with at least one pot and no foul


func shot_started() -> void:
	shot_pots = 0


## One scoring ball dropped. {n, level}.
func pot() -> Dictionary:
	shot_pots += 1
	var n := shot_pots + streak
	return {n = n, level = level_for(n)}


## The Shot resolved. Returns the streak that just broke (>= MIN_LOST), else 0.
func shot_ended(foul: bool) -> int:
	var lost := 0
	if foul or shot_pots == 0:
		lost = streak
		streak = 0
	else:
		streak += 1
	shot_pots = 0
	return lost if lost >= MIN_LOST else 0


## 0 for a lone pot, +1 per chained pot, capped.
static func level_for(n: int) -> int:
	return clampi(n - 1, 0, MAX_LEVEL)


## Celebration size 1..4 from a trick's payout multiplier (01 §3: 1.15 Combo ... 1.60 RailRunner).
static func trick_tier(multiplier: float) -> int:
	return clampi(roundi((multiplier - 1.0) / 0.15), 1, 4)
