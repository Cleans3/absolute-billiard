class_name SaveProfile
extends RefCounted
## The crew's campaign state at a Round boundary (docs/plan/04 §2.6). JSON under 1 KB; SaveManager reads and writes it.

var save_version := SaveManager.SAVE_VERSION
var crew_cash := 0
var current_night := 1  # NightConfig.night_number
var round_index := 0  # Rounds finished this Night; 0 = Night start
var quota_target := 0
var viewers := -1  # -1 = start from the Night's base_viewers
var hype := 0.0
var owned_items: Dictionary = {}  # item id -> count
var persistent_unlocks: Array[StringName] = []
var campaign_seed := 0
var stock_key := -1  # GameLoop.stock_key() the Bartender's shelf was rolled for; -1 = none yet
var stock_ids: Array[StringName] = []  # the Drinks shelf at this boundary, parallel to stock_left
var stock_left: Array[int] = []
var crew_size := 0  # peers in the lobby when it was written (0 = unknown); informational, resume never seat-locks


func to_dict() -> Dictionary:
	var ball_types: Array[String] = []
	var cameras: Array[String] = []
	var cue: Array[String] = []
	var owned := {}
	var persistent: Array[String] = []
	var stock: Array[String] = []
	for id in stock_ids:
		stock.append(String(id))
	for id: StringName in owned_items:
		owned[String(id)] = owned_items[id]
		var it := ShopCatalog.item(id)
		match it.category if it != null else &"":
			&"ball":
				ball_types.append(id)
			&"camera":
				cameras.append(id)
			&"cue":
				cue.append(id)
	for id in persistent_unlocks:
		persistent.append(String(id))
	return {
		"save_version": save_version,
		"crew_cash": crew_cash,
		"current_night": current_night,
		"round_index": round_index,
		"quota_target": quota_target,
		"viewers": viewers,
		"hype": snappedf(hype, 0.001),
		"unlocked": {"ball_types": ball_types, "cameras": cameras, "cue": cue},  # read-only view of owned_items
		"owned_items": owned,
		"persistent_unlocks": persistent,
		"seed": campaign_seed,
		"crew_size": crew_size,
		"bar_stock": {"key": stock_key, "ids": stock, "left": stock_left},
	}


static func from_dict(d: Dictionary) -> SaveProfile:
	var p := SaveProfile.new()
	p.save_version = int(d.get("save_version", 0))
	p.crew_cash = int(d.get("crew_cash", 0))
	p.current_night = int(d.get("current_night", 1))
	p.round_index = int(d.get("round_index", 0))
	p.quota_target = int(d.get("quota_target", 0))
	p.viewers = int(d.get("viewers", -1))
	p.hype = float(d.get("hype", 0.0))
	for id: String in d.get("owned_items", {}):
		p.owned_items[StringName(id)] = int(d["owned_items"][id])
	for id: String in d.get("persistent_unlocks", []):
		p.persistent_unlocks.append(StringName(id))
	p.campaign_seed = int(d.get("seed", 0))
	p.crew_size = int(d.get("crew_size", 0))
	var bar: Dictionary = d.get("bar_stock", {})
	p.stock_key = int(bar.get("key", -1))
	var ids: Array = bar.get("ids", [])
	var left: Array = bar.get("left", [])
	if ids.size() == left.size():  # a torn pair means a hand-edited file: ignore the shelf, a fresh one is rolled
		for i in ids.size():
			p.stock_ids.append(StringName(ids[i]))
			p.stock_left.append(int(left[i]))
	return p
