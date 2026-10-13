class_name RunStats
extends RefCounted
## One run's tally for the end-of-run card and its grade (docs/plan/02 §3.11). The host writes it from rule signals
## (GameLoop hooks them); clients adopt the host's snapshot (`GameLoop.run_state`). Nothing in the rules reads it.

const GRADES: Array[String] = ["D", "C", "B", "A", "S", "S+"]
## Score needed for each grade, same order as GRADES. PROVISIONAL: the playtest bot recalibrates these (02 §3.11).
const GRADE_FLOORS: Array[int] = [0, 200, 400, 600, 850, 1100]
const PTS_NIGHT := 100  # per Night cleared
const PTS_POT := 4
const PTS_COMBO := 10  # per link of the best combo
const PTS_TRICK := 15
const PTS_FOUL := -8  # a scratch is a foul too
const PTS_PER_CASH := 0.02  # earned Cash, $50 per point
## The integer counters, in the order to_dict() writes them.
const COUNTERS: Array[StringName] = [&"pots", &"scratches", &"fouls", &"fines_paid", &"best_combo", &"trick_shots",
		&"shots", &"best_shot", &"cash_earned", &"nights_cleared"]

var pots := 0  # scoring balls potted (base value above 0; a penalty ball or the cue ball is not a pot)
var scratches := 0  # cue ball pocketed or off the table (the Shots that cost a fine)
var fouls := 0  # Shots settled as a foul: scratches, whiffs, clock fouls, penalty pots
var fines_paid := 0  # Cash lost to scratch fines
var best_combo := 0  # the longest FxCombo chain (pots in a Shot + earlier Shots that potted) ever reached
var trick_shots := 0
var shots := 0
var best_shot := 0  # the largest single-Shot payout
var cash_earned := 0  # Shot payouts and tips; the Shop, fines and the Quota do not subtract
var nights_cleared := 0
var play_time := 0.0  # seconds since the run began, resumed runs included

var _combo := FxCombo.new()  # the same chain rules the pot FX shows, so the card agrees with the "COMBO xN" banners


func on_pot() -> void:
	pots += 1
	best_combo = maxi(best_combo, int(_combo.pot().n))


func on_scratch() -> void:
	scratches += 1


func on_fine(amount: int) -> void:
	fines_paid += amount


func on_tip(amount: int) -> void:
	cash_earned += amount


## One Shot settled: `cash` is the payout GameLoop just banked, `trick_id` the paid trick (&"" for none).
func on_shot(cash: int, trick_id: StringName, foul: bool) -> void:
	shots += 1
	if foul:
		fouls += 1
	elif trick_id != &"":
		trick_shots += 1
	if cash > 0:
		cash_earned += cash
		best_shot = maxi(best_shot, cash)
	_combo.shot_ended(foul)


func on_night_cleared() -> void:
	nights_cleared += 1


func score() -> int:
	return nights_cleared * PTS_NIGHT + pots * PTS_POT + best_combo * PTS_COMBO + trick_shots * PTS_TRICK \
			+ fouls * PTS_FOUL + floori(cash_earned * PTS_PER_CASH)


## D, C, B, A, S or S+: the highest grade whose floor the score reaches.
func grade() -> String:
	var s := score()
	var out := GRADES[0]
	for i in GRADES.size():
		if s >= GRADE_FLOORS[i]:
			out = GRADES[i]
	return out


func to_dict() -> Dictionary:
	var d := {}
	for f in COUNTERS:
		d[String(f)] = get(f)
	d["play_time"] = snappedf(play_time, 0.1)
	return d


## Adopts a snapshot (a missing key is 0). In place, so whoever holds this RunStats keeps seeing it.
func apply(d: Dictionary) -> void:
	for f in COUNTERS:
		set(f, int(d.get(String(f), 0)))
	play_time = float(d.get("play_time", 0.0))
	_combo = FxCombo.new()


static func from_dict(d: Dictionary) -> RunStats:
	var s := RunStats.new()
	s.apply(d)
	return s


## Grade of a snapshot, for a card that only has the dictionary.
static func grade_of(d: Dictionary) -> String:
	return from_dict(d).grade()
