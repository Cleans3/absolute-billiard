class_name StatText
extends RefCounted
## StatMod / Drink → the lines a Bartender card prints, each tagged as a buff (helps), debuff (costs) or neutral.
## Every Stats.ALL entry needs a row in INFO (stat_text probe), so a new stat cannot ship unlabelled.

enum Kind { BUFF, DEBUFF, NEUTRAL }

const BUFF_COLOUR := Color("5ACB7C")
const DEBUFF_COLOUR := Color("FF6B6B")

## stat -> [label, good_dir (+1 higher is better, -1 lower is better), unit shown on ADD]
const INFO := {
	&"cue_power_mult": ["Cue power", 1, ""],
	&"cue_spin_radius_mult": ["English", 1, ""],
	&"cue_aim_wobble_deg": ["Aim wobble", -1, "°"],
	&"shot_clock_sec": ["Shot clock", -1, " s"],
	&"cue_ball_mass_mult": ["Cue ball weight", -1, ""],
	&"cloth_friction_mult": ["Cloth drag", -1, ""],
	&"cushion_restitution_mult": ["Rail bounce", -1, ""],
	&"table_tilt_deg": ["Table tilt", -1, "°"],
	&"pocket_radius_mult": ["Pocket size", 1, ""],
	&"pocket_oscillation_m": ["Pocket drift", -1, " m"],
	&"ball_type_shuffle_count": ["Ball swaps", -1, ""],
	&"rule_call_pocket": ["Call your pocket", -1, ""],
	&"player_view_light_level": ["Screen light", 1, ""],
	&"player_view_fog_density": ["Screen fog", -1, ""],
	&"player_view_shake_amp": ["Screen shake", -1, ""],
	&"stream_camera_bonus_mult": ["Camera bonus", 1, ""],
	&"stream_viewer_gain_mult": ["Viewer gains", 1, ""],
	&"stream_hype_gain_mult": ["Hype gains", 1, ""],
	&"round_time_add_sec": ["Round time", 1, " s"],
	&"player_stumble_per_min": ["Stumbles", -1, "/min"],
	&"object_ball_mult": ["Object balls", 0, ""],
}


## {text, kind} for one modifier.
static func line(m: StatMod) -> Dictionary:
	var info: Array = INFO[m.stat]
	var label: String = info[0]
	var text := ""
	var dir := 0  # which way the number moves the stat
	if m.op == StatMod.Op.MUL:
		dir = 0 if is_equal_approx(m.value, 1.0) else (1 if m.value > 1.0 else -1)
		text = "%s: none" % label if is_zero_approx(m.value) else "%s %+d%%" % [label, roundi((m.value - 1.0) * 100.0)]
	else:
		dir = 1 if m.value > 0.0 else (-1 if m.value < 0.0 else 0)
		if m.stat == &"rule_call_pocket":
			text = label
		elif m.stat == &"shot_clock_sec":
			text = "%s: %s s" % [label, String.num(m.value, 1).trim_suffix(".0")]  # base 0 = no clock, so ADD is the clock
		elif (m.stat as String).ends_with("_mult"):
			text = "%s %+d%%" % [label, roundi(m.value * 100.0)]
		else:
			text = "%s %s%s%s" % [label, "+" if m.value > 0.0 else "", String.num(m.value, 2).trim_suffix(".0").trim_suffix(".00"), info[2]]
	return {text = text, kind = _kind(dir * int(info[1]))}


## Every line a Drink card shows: reward, each effect's modifiers, then the rule notes.
static func lines(d: Drink) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_equal_approx(d.reward_mult, 1.0):
		out.append({text = "Reward x%.2f" % d.reward_mult, kind = _kind(1 if d.reward_mult > 1.0 else -1)})
	for e in d.effects:
		if e.clears_tag != &"":
			out.append({text = "Ends %s effects" % e.clears_tag, kind = Kind.BUFF})
		for m in e.stat_modifiers:
			out.append(line(m))
	if not is_equal_approx(d.neighbour_reward_mult, 1.0):
		out.append({text = "Left neighbour earns x%.2f" % d.neighbour_reward_mult, kind = Kind.NEUTRAL})
	if d.night_limit > 0:
		out.append({text = "Limit %d per Night" % d.night_limit, kind = Kind.NEUTRAL})
	return out


static func count(d: Drink, kind: Kind) -> int:
	var n := 0
	for l in lines(d):
		if l.kind == kind:
			n += 1
	return n


static func _kind(signed_good: int) -> Kind:
	return Kind.BUFF if signed_good > 0 else (Kind.DEBUFF if signed_good < 0 else Kind.NEUTRAL)
