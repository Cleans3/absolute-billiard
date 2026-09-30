class_name WorldInteraction
extends Resource
## Docs/plan/03 §2.6.

@export var id: StringName
@export var prop: StringName  # table camera stool jukebox lights rail bar crowd
@export var hostile := false
@export var cost: PoolDelta
@export var payoffs: Array[PoolDelta] = []
@export var effect: Effect
@export var cooldown_sec := 0.0  # per interactor
@export var once_per_round := false
@export var requires_live_shot := false
