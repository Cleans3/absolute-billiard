class_name SaveManager
extends RefCounted
## Static save I/O (docs/plan/04 §2.6, 02 §3.7): Round checkpoints every peer keeps, plus the run-surviving
## persistent-unlock file. Not an autoload. `root` is swappable so probes never touch the real user dir.

const SAVE_VERSION := 2  # v1 = the 04 sketch (no owned_items / viewers / hype); v2 adds them

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
	var parsed: Variant = JSON.parse_string(blob.get_string_from_utf8())
	if not parsed is Dictionary:
		last_error = &"corrupt"
		return null
	var d: Dictionary = parsed
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
	if save_version <= SAVE_VERSION:
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
	return true


static func load_checkpoint(path: String) -> SaveProfile:
	if not FileAccess.file_exists(path):
		last_error = &"missing"
		return null
	return decode(FileAccess.get_file_as_bytes(path))


## Newest first: [{path, key, modified, night, round_index, cash}] for the Lobby's "Resume" list.
static func list_checkpoints() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for file in DirAccess.get_files_at(checkpoint_dir()):
		var path := checkpoint_dir().path_join(file)
		var p := load_checkpoint(path)
		if p != null:
			out.append({path = path, key = file.get_basename(), modified = FileAccess.get_modified_time(path),
				night = p.current_night, round_index = p.round_index, cash = p.crew_cash})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.modified > b.modified)
	return out


static func load_persistent() -> Array[StringName]:
	var out: Array[StringName] = []
	var path := root.path_join("profile.json")
	if FileAccess.file_exists(path):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if d is Dictionary and int(d.get("save_version", 0)) <= SAVE_VERSION:
			for id: String in d.get("persistent_unlocks", []):
				out.append(StringName(id))
	return out


static func save_persistent(ids: Array[StringName]) -> void:
	var f := FileAccess.open(root.path_join("profile.json"), FileAccess.WRITE)
	if f != null:
		var strings: Array[String] = []
		for id in ids:
			strings.append(String(id))
		f.store_string(JSON.stringify({"save_version": SAVE_VERSION, "persistent_unlocks": strings}))
