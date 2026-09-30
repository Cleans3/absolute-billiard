class_name Drink
extends Resource
## Docs/plan/03 §2.4. Content only: 02's ShopItem owns price and unlock gating.

enum ServeTarget { SELF, NAMED_PLAYER }

@export var id: StringName
@export var effects: Array[Effect] = []
@export var reward_mult := 1.0
@export var serve_target: ServeTarget = ServeTarget.NAMED_PLAYER
@export var mid_round := false
@export var roll_on_use := false
@export var roll_table: Array[Resource] = []  # roll_on_use: Drink outcomes (Array[Drink] would make the script self-referential and leak at exit)
@export var roll_weights := PackedFloat32Array()
@export var neighbour_reward_mult := 1.0  # != 1.0: the seat-left player gets this factor for the Round
@export var night_limit := 0  # 0 = unlimited; per player per Night
@export var cost_cash := 0  # catalog price [tune]; throw_drink spends it
