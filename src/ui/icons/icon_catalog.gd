class_name IconCatalog
extends RefCounted
## One icon per Drink, Event (hazard) and ShopItem (docs/plan/03 §2.6, 08 §2.8). The SVGs are drawn by src/tools/ui_art.py
## into assets/ui/{drink,hazard,upgrade}/<id>.svg. Never null: an id with no file of its own gets that kind's `unknown`
## icon, and tests/ui/shop_probe.gd fails on it, so a new catalog row cannot ship without its art.

const DIR := "res://assets/ui/"

static var _cache: Dictionary = {}  # path -> Texture2D


## `kind` is drink | hazard | upgrade; the file a row's icon is expected at.
static func path(kind: StringName, id: StringName) -> String:
	return "%s%s/%s.svg" % [DIR, kind, id]


static func drink(d: Drink) -> Texture2D:
	return _load(&"drink", d.id)


static func hazard(e: Event) -> Texture2D:
	return _load(&"hazard", e.id)


## An Upgrade row's icon; a Drink's ShopItem (category drink) gets its glass.
static func upgrade(item: ShopItem) -> Texture2D:
	if item.category == &"drink":
		return _load(&"drink", item.id)
	return _load(&"upgrade", item.id)


static func _load(kind: StringName, id: StringName) -> Texture2D:
	var p := path(kind, id)
	if not _cache.has(p):
		_cache[p] = load(p if ResourceLoader.exists(p) else path(kind, &"unknown"))
	return _cache[p]
