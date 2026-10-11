class_name WaitText
extends RefCounted
## What a refusal or a wait says (docs/plan/08 §2.8, rule: a wait names what it waits for and shows a time or a count).
## One table per source so the HUD, the Player and the probes read the same sentences.

const SHOT := {
	no_cue_ball = "No cue ball on the table",
	no_round = "No Round is live yet: press GO LIVE at the table",
	bad_power = "Pull the power slider back first",
	bad_aim = "Aim at the table first",
	call_pocket = "Call a pocket first (1-6)",
}

const INTERACTION := {
	unknown_kind = "Nothing happens here",
	bad_payload = "That order isn't valid",
	intermission_only = "That is only served between Rounds",
	not_intermission = "GO LIVE only works between Rounds",
	not_ringing = "The phone isn't ringing",
	already_answered = "Somebody already picked up",
	hostile_off = "Hostile moves are off in this lobby",
	hostile_friends_only = "Only the host's friends can do that",
	shooter_cant_grief = "The shooter can't heckle their own shot",
	not_live = "That only works while a Round is live",
	once_per_round = "Already used this Round",
	no_prop = "Nothing to use here",
	no_position = "The host can't see you yet",
	too_far = "Too far away: step closer",
	hostile_cap = "Two hostile moves per turn is the limit",
	cant_afford = "Can't afford that",
	sold_out = "Sold out",
	not_stocked = "Not on tonight's shelf",
	unknown_item = "Not on the menu",
}


## `moving` = balls still in motion, `shooter` = who is up.
static func shot(reason: StringName, shooter := "", moving := 0) -> String:
	match reason:
		&"balls_moving":
			return "Balls still moving (%d)" % moving if moving > 0 else "Balls still moving"
		&"not_your_turn":
			return "Not your turn: %s is shooting" % shooter if shooter != "" else "Not your turn"
	return SHOT.get(reason, _sentence(reason))


## `wait_sec` > 0 only for `cooldown` (the host's remaining seconds).
static func interaction(kind: StringName, reason: StringName, wait_sec := 0.0) -> String:
	if reason == &"cooldown":
		return cooling(kind, wait_sec)
	return INTERACTION.get(reason, _sentence(reason))


static func cooling(kind: StringName, wait_sec: float) -> String:
	return "%s is cooling down: %d s left" % [_sentence(kind), ceili(wait_sec)]


## "chalk_the_cue" -> "Chalk the cue"
static func _sentence(id: StringName) -> String:
	var words := String(id).replace("_", " ")
	return words.substr(0, 1).to_upper() + words.substr(1)
