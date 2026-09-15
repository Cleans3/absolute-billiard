class_name PhysicsSim
extends Node

## Live-shot bookkeeping (07 §1.3–1.4, §7.2): awake-ball count via sleep signals, contact
## monitoring only during a Shot, physics tick 120 Hz live / 60 Hz at rest. Modifier stack comes later.

signal shot_started(ball: Ball, intent: ShotIntent)
signal all_resting

const LIVE_TICK := 120
const REST_TICK := 60

var awake := 0
var _balls: Array[Ball] = []


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
