class_name ShopCatalog
extends RefCounted
## Every Cash sink in one list (docs/plan/02 §3.6): the 16 Upgrades rows as .tres plus one item per 03 Drink.

const ROWS: Array[ShopItem] = [
	preload("res://src/resources/shop/polish_the_set.tres"),
	preload("res://src/resources/shop/tier2_rack.tres"),
	preload("res://src/resources/shop/tier3_rack.tres"),
	preload("res://src/resources/shop/bomb_ball.tres"),
	preload("res://src/resources/shop/split_ball.tres"),
	preload("res://src/resources/shop/joker_ball.tres"),
	preload("res://src/resources/shop/heavy_shaft.tres"),
	preload("res://src/resources/shop/chalk_tin.tres"),
	preload("res://src/resources/shop/jump_cue.tres"),
	preload("res://src/resources/shop/custom_tip.tres"),
	preload("res://src/resources/shop/lens_t2.tres"),
	preload("res://src/resources/shop/lens_t3.tres"),
	preload("res://src/resources/shop/spare_tripod.tres"),
	preload("res://src/resources/shop/magnetic_pockets.tres"),
	preload("res://src/resources/shop/stream_overlay.tres"),
	preload("res://src/resources/shop/fresh_cloth.tres"),
]
const CATEGORIES: Array[StringName] = [&"drink", &"ball", &"cue", &"camera", &"table"]

static var _items: Dictionary = {}  # StringName -> ShopItem
static var _order: Array[ShopItem] = []


static func item(id: StringName) -> ShopItem:
	_build()
	return _items.get(id)


static func all() -> Array[ShopItem]:
	_build()
	return _order


static func in_category(category: StringName) -> Array[ShopItem]:
	var out: Array[ShopItem] = []
	for it in all():
		if it.category == category:
			out.append(it)
	return out


static func _build() -> void:
	if not _items.is_empty():
		return
	for d in FxCatalog.DRINKS:
		var it := ShopItem.new()
		it.id = d.id
		it.display_name = d.display_name
		it.description = d.description
		it.category = &"drink"
		it.cost_cash = d.cost_cash
		it.payload = d
		it.max_owned = 0
		_add(it)
	for it in ROWS:
		_add(it)


static func _add(it: ShopItem) -> void:
	assert(not _items.has(it.id), "duplicate ShopItem id '%s'" % it.id)
	_items[it.id] = it
	_order.append(it)
