class_name Drink
extends Resource
## Docs/plan/03 §2.4. Content only: 02's ShopItem owns price and unlock gating.

enum ServeTarget { SELF, NAMED_PLAYER }

@export var id: StringName
@export var display_name := ""
@export_multiline var description := ""  # one flavour line on the Bartender card
@export var tier: DrinkTier.Tier = DrinkTier.Tier.COMMON  # rarity at the Bartender (06 P17); MYSTERY = shown buff + debuff gamble
@export var effects: Array[Effect] = []
@export var reward_mult := 1.0
@export var serve_target: ServeTarget = ServeTarget.NAMED_PLAYER
@export var mid_round := false
@export var neighbour_reward_mult := 1.0  # != 1.0: the seat-left player gets this factor for the Round
@export var night_limit := 0  # 0 = unlimited; per player per Night
@export var cost_cash := 0  # catalog price [tune]; throw_drink spends it
