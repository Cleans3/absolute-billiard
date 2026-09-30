class_name PoolDelta
extends Resource
## One crew-pool movement: a WorldInteraction cost, or a payoff paid back on `condition`.
## `amount` is a positive magnitude; whether it is spent or gained is decided by where it sits.

enum Kind { HYPE, VIEWERS, CASH }

@export var kind: Kind = Kind.VIEWERS
@export var amount := 0.0
@export var condition := &"always"  # payoffs only: always | shot_potted | shot_missed
