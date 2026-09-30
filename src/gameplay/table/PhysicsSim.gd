class_name PhysicsSim
extends Node

## Live-shot bookkeeping (07 §1.3–1.4, §7.2): awake-ball count via sleep signals, contact
## monitoring only during a Shot, physics tick 120 Hz live / 60 Hz at rest. Modifier stack comes later.

signal shot_started(ball: Ball, intent: ShotIntent)
signal all_resting

const LIVE_TICK := 120
const REST_TICK := 60

const NUDGE_IMPULSE := 0.06  # N·s per unit strength [tune] (01 §3)

## Installed by EffectManager: (stat: StringName, peer_id: int, base: float) -> float. Default = base.
var stat_source: Callable
## Installed by RoundDirector: (peer_id: int, intent: ShotIntent) -> StringName, `&""` = ok else reason.
var shot_validator: Callable

# Resolved table/ball stats, pushed host-side by EffectManager via set_stat. Timers live there, not here.
var cue_ball_mass_mult := 1.0
var cloth_friction_mult := 1.0
var cushion_restitution_mult := 1.0
var table_tilt_deg := 0.0
var tilt_direction := Vector2.ZERO

var awake := 0
var _balls: Array[Ball] = []
var _rail_mult: Dictionary = {}  # rail_id -> float, absent = 1.0


## Resolved value of a per-shot stat (`cue_power_mult`, `cue_spin_radius_mult`) for `peer_id`.
func stat(stat_name: StringName, peer_id: int, base: float) -> float:
	return stat_source.call(stat_name, peer_id, base) if stat_source.is_valid() else base


func set_stat(stat_name: StringName, value: float) -> void:
	match stat_name:
		&"cue_ball_mass_mult":
			cue_ball_mass_mult = value
			for b in _balls:
				if b.is_cue_ball:
					b.apply_mass_mult(value)
		&"cloth_friction_mult": cloth_friction_mult = value
		&"cushion_restitution_mult": cushion_restitution_mult = value
		&"table_tilt_deg": table_tilt_deg = value
		_: push_error("PhysicsSim.set_stat: unknown stat %s" % stat_name)


func set_tilt_direction(dir: Vector2) -> void:
	tilt_direction = dir.normalized()


func set_rail_restitution_mult(rail_id: StringName, mult: float) -> void:
	_rail_mult[rail_id] = mult


func rail_restitution_mult(rail_id: StringName) -> float:
	return cushion_restitution_mult * float(_rail_mult.get(rail_id, 1.0))


## Central impulse to every non-resting ball (01 §3). Host-only.
func nudge(direction: Vector2, strength: float, _source_peer_id: int) -> void:
	var j := Vector3(direction.x, 0.0, direction.y).normalized() * strength * NUDGE_IMPULSE
	for b in _balls:
		if not b.is_resting and not b.freeze:
			b.apply_central_impulse(j)


func _ready() -> void:
	Performance.add_custom_monitor("Game/AwakeBalls", _get_awake)
	Engine.physics_ticks_per_second = REST_TICK


func _exit_tree() -> void:
	Performance.remove_custom_monitor("Game/AwakeBalls")  # a dangling monitor callable corrupts the heap at quit


func _get_awake() -> int:
	return awake


func get_balls() -> Array[Ball]:
	return _balls.duplicate()


func register(ball: Ball) -> void:
	_balls.append(ball)
	ball.sim = self
	if ball.is_cue_ball:
		ball.apply_mass_mult(cue_ball_mass_mult)
	ball.contact_monitor = false
	ball.struck.connect(_on_struck)
	ball.resting_changed.connect(_recount.unbind(2))
	ball.tree_exiting.connect(func() -> void:
		_balls.erase(ball)
		_recount())
	_recount()


func _on_struck(ball: Ball, intent: ShotIntent) -> void:
	for b in _balls:
		b.contact_monitor = true
	Engine.physics_ticks_per_second = LIVE_TICK
	shot_started.emit(ball, intent)
	# Struck ball's own is_resting already flipped false synchronously (Ball.strike, before this
	# signal fires) — recount now instead of waiting on the deferred resting_changed so `awake`
	# reflects the shot on the same frame it starts, not a lagging frame behind (gamma F3a).
	_recount()


func _recount() -> void:
	var n := 0
	for b in _balls:
		if not b.is_resting and not b.freeze and b.is_inside_tree():
			n += 1
	var was := awake
	awake = n
	if n == 0 and was > 0:
		for b in _balls:
			if b.is_inside_tree():
				b.contact_monitor = false
		Engine.physics_ticks_per_second = REST_TICK  # only ever changed at rest (07 §7.2)
		all_resting.emit()
