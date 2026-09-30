class_name ShopItem
extends Resource
## One catalog row (docs/plan/02 §2, §3.6). Drinks are synthesised from the 03 catalog by ShopCatalog.

@export var id: StringName
@export var category: StringName  # drink | ball | cue | camera | table
@export var cost_cash := 0
@export var payload: Resource  # Drink for drinks, ItemDelta otherwise
@export var min_night := 1
@export var one_per_night := false
@export var persistent := false  # survives a wipe into the next run (§3.7)
@export var max_owned := 1  # 0 = repeatable (drinks); spare_tripod stacks to the rig cap
