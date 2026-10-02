class_name SkinCatalog
extends RefCounted
## Every CharacterSkin / BarSkin and the local pick (06 P18). Test mode: all free and unlocked, nothing is owned.
## The lists come from `ResourceLoader.list_directory`, which reports the editor's file names in an export too
## (a plain DirAccess would see `.tres.remap`), so dropping a .tres into the folders is the whole "add a skin".

const CHARACTER_DIR := "res://src/resources/skins/characters/"
const BAR_DIR := "res://src/resources/skins/bars/"
const SEAT_IDS: Array[StringName] = [&"seat_red", &"seat_blue", &"seat_yellow", &"seat_green"]
const BARTENDER := &"bartender"  ## the NPC's look; loadable by id, never offered or accepted from a peer
const DEFAULT_BAR := &"classic"

static var _characters: Dictionary = {}  # id -> CharacterSkin, every one in the folder
static var _bars: Dictionary = {}  # id -> BarSkin


## The player-selectable character skins, by display name.
static func characters() -> Array[CharacterSkin]:
	_load()
	var out: Array[CharacterSkin] = []
	for id: StringName in _characters:
		if id != BARTENDER:
			out.append(_characters[id])
	out.sort_custom(func(a: CharacterSkin, b: CharacterSkin) -> bool: return a.display_name < b.display_name)
	return out


## Every bar skin, the default first, the rest by display name.
static func bars() -> Array[BarSkin]:
	_load()
	var out: Array[BarSkin] = []
	for id: StringName in _bars:
		out.append(_bars[id])
	out.sort_custom(func(a: BarSkin, b: BarSkin) -> bool:
		if (a.id == DEFAULT_BAR) != (b.id == DEFAULT_BAR):
			return a.id == DEFAULT_BAR
		return a.display_name < b.display_name)
	return out


## Null when unknown. Finds the bartender too: use `is_selectable_character` for anything a player may pick.
static func character(id: StringName) -> CharacterSkin:
	_load()
	return _characters.get(id)


static func bar(id: StringName) -> BarSkin:
	_load()
	return _bars.get(id)


static func is_selectable_character(id: StringName) -> bool:
	return id != BARTENDER and character(id) != null


## Nothing equipped: the colour of your seat.
static func default_character(seat: int) -> CharacterSkin:
	return character(SEAT_IDS[posmod(seat, SEAT_IDS.size())])


static func default_bar() -> BarSkin:
	return bar(DEFAULT_BAR)


## What an avatar wears: the equipped skin, else the seat's. An unknown or non-selectable id counts as nothing.
static func resolve_character(id: StringName, seat: int) -> CharacterSkin:
	return character(id) if is_selectable_character(id) else default_character(seat)


static func resolve_bar(id: StringName) -> BarSkin:
	return bar(id) if bar(id) != null else default_bar()


# --- the local profile (user://profile.json) ---------------------------------------------------------

## The equipped character id, or &"" when nothing (valid) is equipped: the seat colour then applies.
static func equipped_character_id() -> StringName:
	var id: StringName = SaveManager.load_skins().char_skin
	return id if is_selectable_character(id) else &""


static func equipped_bar_id() -> StringName:
	return resolve_bar(SaveManager.load_skins().bar_skin).id


static func equip_character(id: StringName) -> void:
	if is_selectable_character(id):
		SaveManager.save_skins(id, SaveManager.load_skins().bar_skin)


static func equip_bar(id: StringName) -> void:
	if bar(id) != null:
		SaveManager.save_skins(SaveManager.load_skins().char_skin, id)


## What this peer sends the host at registration (`NetManager`): `{char_skin, bar_skin}`, both validated.
static func local_pick() -> Dictionary:
	return {char_skin = equipped_character_id(), bar_skin = equipped_bar_id()}


static func _load() -> void:
	if not _characters.is_empty():
		return
	_fill(CHARACTER_DIR, _characters)
	_fill(BAR_DIR, _bars)
	assert(_characters.has(BARTENDER) and _bars.has(DEFAULT_BAR) and SEAT_IDS.all(func(id: StringName) -> bool: return _characters.has(id)), "SkinCatalog: a required skin is missing")


static func _fill(dir: String, into: Dictionary) -> void:
	for file in ResourceLoader.list_directory(dir):
		if file.ends_with(".tres"):
			var skin: Resource = load(dir + file)
			into[skin.get(&"id")] = skin
