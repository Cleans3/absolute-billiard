class_name Stats
extends RefCounted
## The const stat list (docs/plan/03 §2.2). StatMod asserts against ALL at resource load.

const ALL: Array[StringName] = [
	&"cue_power_mult", &"cue_spin_radius_mult", &"cue_aim_wobble_deg", &"shot_clock_sec",
	&"cue_ball_mass_mult", &"cloth_friction_mult", &"cushion_restitution_mult", &"table_tilt_deg",
	&"pocket_radius_mult", &"pocket_oscillation_m", &"ball_type_shuffle_count",
	&"rule_call_pocket",
	&"player_view_light_level", &"player_view_fog_density", &"player_view_shake_amp",
	&"stream_camera_bonus_mult", &"stream_viewer_gain_mult", &"stream_hype_gain_mult",
	&"round_time_add_sec",
	&"player_stumble_per_min",
	&"object_ball_mult",
]

## Value of a stat with no live modifier.
const BASE := {
	&"cue_power_mult": 1.0, &"cue_spin_radius_mult": 1.0, &"cue_aim_wobble_deg": 0.0, &"shot_clock_sec": 0.0,
	&"cue_ball_mass_mult": 1.0, &"cloth_friction_mult": 1.0, &"cushion_restitution_mult": 1.0, &"table_tilt_deg": 0.0,
	&"pocket_radius_mult": 1.0, &"pocket_oscillation_m": 0.0, &"ball_type_shuffle_count": 0.0,
	&"rule_call_pocket": 0.0,
	&"player_view_light_level": 1.0, &"player_view_fog_density": 0.0, &"player_view_shake_amp": 0.0,
	&"stream_camera_bonus_mult": 1.0, &"stream_viewer_gain_mult": 1.0, &"stream_hype_gain_mult": 1.0,
	&"round_time_add_sec": 0.0, &"player_stumble_per_min": 0.0,  # PLAYER target: the host knocks that peer down this often (P15)
	&"object_ball_mult": 1.0,  # TABLE target (Double Ball): the Round's rack holds this many times the object balls, each pot pays 1/this
}

## Post-resolution floors, applied only when at least one modifier touched the stat.
const FLOORS := {&"cue_aim_wobble_deg": 0.0, &"shot_clock_sec": 4.0}

## Pushed to PhysicsSim.set_stat for the current shooter whenever they change (03 §5, contract §5).
const SIM_PUSHED: Array[StringName] = [
	&"cue_ball_mass_mult", &"cloth_friction_mult", &"cushion_restitution_mult", &"table_tilt_deg",
]

## Hooks that cover the whole screen: at most one live (03 §3.8).
const FULLSCREEN_HOOKS: Array[StringName] = [&"blackout", &"shake"]

## Rail ids as PhysicsSim knows them; an Effect's `target_id` on a rail-scoped TABLE Effect is 1 + index here.
const RAILS: Array[StringName] = [&"rail_w", &"rail_e", &"rail_n_w", &"rail_n_e", &"rail_s_w", &"rail_s_e"]
