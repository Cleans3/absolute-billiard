class_name EconomyManager
extends Node
## Cash ledger and the Night reckoning (docs/plan/02 §3.2, §3.4). Every Cash change goes through add_cash().

signal cash_changed(new_balance: int, delta: int, reason: StringName)  # reason: shot | tip | quota
signal quota_evaluated(paid: int, demand: int, is_game_over: bool)

const POINT_TO_CASH_RATE := 0.3
const BUYOUT_MULT := 1.5  # final Night's demand replaces its quota (02 §3.4)

@export var stream: StreamManager

var cash := 0


## Shot_Cash = Raw_Points × Trick_Mult × Camera_Mult × Event_Mult × Viewer_Scalar × Rate, integer Cash.
## Caller passes 0 / [] on a foul. Must run before StreamManager.on_shot_ended (Viewer_Scalar is pre-shot).
func award_shot_reward(raw_points: int, trick_ids: Array[StringName], _pocket_id: StringName) -> int:
	var trick_mult := TrickShot.multiplier_for(trick_ids[0]) if not trick_ids.is_empty() else 1.0
	# ponytail: Camera_Mult stays literal 1.0 until M5 (cameras) exists; pocket_id feeds M5.
	var camera_mult := 1.0
	var fx := get_node_or_null(^"../EffectManager")  # duck-typed: the economy probe runs without one
	var event_mult: float = fx.get_reward_multiplier() * fx.pot_bonus() if fx != null else 1.0
	var scalar := stream.viewer_scalar() if stream != null else 1.0
	var reward := roundi(raw_points * trick_mult * camera_mult * event_mult * scalar * POINT_TO_CASH_RATE)
	add_cash(reward, &"shot")
	return reward


## False (nothing spent) when Cash does not cover it. WorldInteractions costs go through here (03 §3.4).
func try_spend_cash(amount: int, reason: StringName) -> bool:
	if amount > cash:
		return false
	add_cash(-amount, reason)
	return true


func add_cash(amount: int, reason: StringName) -> void:
	if amount == 0:
		return
	cash += amount
	cash_changed.emit(cash, amount, reason)


func demand_for(config: NightConfig, is_final := false) -> int:
	return roundi(config.quota * BUYOUT_MULT) if is_final else config.quota


## Pays the demand out of Cash when covered (overpay stays in Cash, so it banks); a miss ends the run.
func evaluate_quota(config: NightConfig, is_final := false) -> bool:
	var demand := demand_for(config, is_final)
	var passed := cash >= demand
	if passed:
		add_cash(-demand, &"quota")
	quota_evaluated.emit(demand if passed else 0, demand, not passed)
	return passed
