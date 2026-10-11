class_name SaveManager
extends RefCounted
## Static save I/O (docs/plan/04 §2.6, 02 §3.7): Round checkpoints every peer keeps, plus the run-surviving
## persistent-unlock file. Not an autoload. `root` is swappable so probes never touch the real user dir.

const SAVE_VERSION := 2
const KEEP_CHECKPOINTS := 10  # newest files kept; an older campaign falls off the Resume list  # v1 = the 04 sketch (no owned_items / viewers / hype); v2 adds them

static var root := "user://"
static var last_error := &""  # why the last decode() refused
static var pending_resume: SaveProfile  # the Lobby sets it; MainLevel hands it to GameLoop.resume_from


static func take_resume() -> SaveProfile:
	var p := pending_resume
	pending_resume = null
	return p


## Checkpoint file name: the Noray lobby code, else "solo", else a LAN session named by its seed.
static func checkpoint_key(lobby_code: String, roster_size: int, session_seed: int) -> String:
	if not lobby_code.is_empty():
		return lobby_code
	return "solo" if roster_size <= 1 else "lan-%d" % session_seed


static func checkpoint_dir() -> String:
	return root.path_join("checkpoints")


static func checkpoint_path(key: String) -> String:
	return checkpoint_dir().path_join("%s.json" % (key if not key.is_empty() else "solo"))


static func encode(p: SaveProfile) -> PackedByteArray:
	return JSON.stringify(p.to_dict()).to_utf8_buffer()


## Null (and `last_error`) when the blob is unreadable or from a newer build; older versions are migrated.
static func decode(blob: PackedByteArray) -> SaveProfile:
	last_error = &""
	var json := JSON.new()
	if json.parse(blob.get_string_from_utf8()) != OK or not json.data is Dictionary:
		last_error = &"corrupt"
		return null
	var d: Dictionary = json.data
	if int(d.get("save_version", 0)) > SAVE_VERSION:
		last_error = &"newer_version"
		push_warning("SaveManager: save_version %s is newer than %d; refusing" % [d.get("save_version"), SAVE_VERSION])
		return null
	return SaveProfile.from_dict(migrate(d))


## Steps a profile dictionary up to SAVE_VERSION, one version at a time.
static func migrate(d: Dictionary) -> Dictionary:
	var v := int(d.get("save_version", 1))
	if v < 2:  # v1 listed shop ids per category; the flat owned_items map replaces them
		var owned := {}
		for group: Array in d.get("unlocked", {}).values():
			for id: String in group:
				owned[id] = 1
		d["owned_items"] = owned
		d["viewers"] = -1
		d["hype"] = 0.0
		d["save_version"] = 2
	return d


## A client's copy of the host's checkpoint (NetManager.push_save_checkpoint lands here).
static func receive_checkpoint(lobby_code: String, roster_size: int, session_seed: int, save_version: int, blob: PackedByteArray) -> void:
	if blob.is_empty():
		delete_checkpoint(checkpoint_key(lobby_code, roster_size, session_seed))
	elif save_version <= SAVE_VERSION:
		write_checkpoint(checkpoint_key(lobby_code, roster_size, session_seed), blob)
	else:
		push_warning("SaveManager: checkpoint v%d is newer than this build (v%d); not stored" % [save_version, SAVE_VERSION])


static func write_checkpoint(key: String, blob: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(checkpoint_dir())
	var f := FileAccess.open(checkpoint_path(key), FileAccess.WRITE)
	if f == null:
		push_error("SaveManager: cannot write %s (%s)" % [checkpoint_path(key), error_string(FileAccess.get_open_error())])
		return false
	f.store_buffer(blob)
	f.close()
	prune(checkpoint_path(key))
	return true


## A finished campaign leaves no checkpoint (host deletes its own; clients get an empty blob).
static func delete_checkpoint(key: String) -> void:
	DirAccess.remove_absolute(checkpoint_path(key))


## Keeps the KEEP_CHECKPOINTS newest files. `just_written` always survives: mtimes have 1 s resolution,
## so a same-second tie must never evict the checkpoint this call exists to keep.
static func prune(just_written := "") -> void:
	var files: Array[Dictionary] = []
	for file in DirAccess.get_files_at(checkpoint_dir()):
		var path := checkpoint_dir().path_join(file)
		files.append({path = path, modified = INF if path == just_written else float(FileAccess.get_modified_time(path))})
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.modified > b.modified)
	for i in range(KEEP_CHECKPOINTS, files.size()):
		DirAccess.remove_absolute(files[i].path)


static func load_checkpoint(path: String) -> SaveProfile:
	if not FileAccess.file_exists(path):
		last_error = &"missing"
		return null
	return decode(FileAccess.get_file_as_bytes(path))


## Newest first: [{path, key, modified, night, round_index, cash, crew}] for the Lobby's "Resume" list.
static func list_checkpoints() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for file in DirAccess.get_files_at(checkpoint_dir()):
		var path := checkpoint_dir().path_join(file)
		var p := load_checkpoint(path)
		if p != null:
			out.append({path = path, key = file.get_basename(), modified = FileAccess.get_modified_time(path),
				night = p.current_night, round_index = p.round_index, cash = p.crew_cash, crew = p.crew_size})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.modified > b.modified)
	return out


## The whole of user://profile.json; {} when absent, unreadable or from a newer build. Every writer merges into it.
static func _read_profile() -> Dictionary:
	var path := root.path_join("profile.json")
	if FileAccess.file_exists(path):
		var json := JSON.new()  # not parse_string: a hand-mangled file must not log an engine error every read
		if json.parse(FileAccess.get_file_as_string(path)) == OK and json.data is Dictionary and int(json.data.get("save_version", 0)) <= SAVE_VERSION:
			return json.data
	return {}


static func _write_profile(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(root.path_join("profile.json"), FileAccess.WRITE)
	if f != null:
		d["save_version"] = SAVE_VERSION
		f.store_string(JSON.stringify(d))


static func load_persistent() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: String in _read_profile().get("persistent_unlocks", []):
		out.append(StringName(id))
	return out


static func save_persistent(ids: Array[StringName]) -> void:
	var strings: Array[String] = []
	for id in ids:
		strings.append(String(id))
	var d := _read_profile()
	d["persistent_unlocks"] = strings
	_write_profile(d)


## The equipped skin ids (06 P18), &"" when the profile has none. SkinCatalog validates them; this only stores.
static func load_skins() -> Dictionary:
	var d := _read_profile()
	return {char_skin = StringName(str(d.get("char_skin", ""))), bar_skin = StringName(str(d.get("bar_skin", "")))}


static func save_skins(char_skin: StringName, bar_skin: StringName) -> void:
	var d := _read_profile()
	d["char_skin"] = String(char_skin)
	d["bar_skin"] = String(bar_skin)
	_write_profile(d)


# --- story (09 §2.3, 06 P29): per player, keyed by campaign, never in SaveProfile (the host's blob overwrites every peer's) -----

## The Nights whose intro cards this player already opened in `campaign` (GameLoop.campaign_seed).
static func story_seen(campaign: int) -> Array[int]:
	var out: Array[int] = []
	for n: Variant in _story_get("story_seen", campaign):
		out.append(int(n))
	return out


static func save_story_seen(campaign: int, nights: Array[int]) -> void:
	_story_put("story_seen", campaign, nights)


## The Nights whose phone call this player already heard in `campaign`, so a Resume of a Night-start checkpoint stays quiet.
static func story_called(campaign: int) -> Array[int]:
	var out: Array[int] = []
	for n: Variant in _story_get("story_called", campaign):
		out.append(int(n))
	return out


static func save_story_called(campaign: int, nights: Array[int]) -> void:
	_story_put("story_called", campaign, nights)


## The Gus story lines this player already heard in `campaign`, by their text.
static func story_said(campaign: int) -> Array[String]:
	var out: Array[String] = []
	for l: Variant in _story_get("story_said", campaign):
		out.append(str(l))
	return out


static func save_story_said(campaign: int, lines: Array[String]) -> void:
	_story_put("story_said", campaign, lines)


## The campaigns that can still be resumed (their checkpoint exists), as profile keys.
static func checkpoint_campaigns() -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(checkpoint_dir()):
		return out
	for file in DirAccess.get_files_at(checkpoint_dir()):
		var p := load_checkpoint(checkpoint_dir().path_join(file))
		if p != null:
			out.append(str(p.campaign_seed))
	return out


static func _story_get(key: String, campaign: int) -> Array:
	var by_campaign: Variant = _read_profile().get(key, {})
	return by_campaign.get(str(campaign), []) if by_campaign is Dictionary else []


## Writes one campaign's list and drops the campaigns that no longer have a checkpoint (KEEP_CHECKPOINTS), keeping this one.
static func _story_put(key: String, campaign: int, values: Array) -> void:
	var d := _read_profile()
	var by_campaign: Dictionary = d.get(key, {}) if d.get(key, {}) is Dictionary else {}
	by_campaign[str(campaign)] = values.duplicate()
	var alive := checkpoint_campaigns()
	for c: String in by_campaign.keys():
		if c != str(campaign) and not alive.has(c):
			by_campaign.erase(c)
	d[key] = by_campaign
	_write_profile(d)
