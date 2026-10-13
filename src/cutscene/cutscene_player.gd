class_name CutscenePlayer
extends Node
## The one helper MainLevel / StoryDirector call to play a cutscene or a chain of them (docs/plan/09 §4.4). Every peer runs its own
## copy: playing is local, `played(id, skipped)` is the ack that F3b sends to the host (A9). The host's wait is `max_wait_sec(id)`: the
## sequence's length plus ACK_MARGIN_SEC, whichever comes first with every peer's ack. A peer that was away skips straight to the end
## state with `play(id, {"instant": true})`: no scene, only the ack.
##
## Options (`play(id, opts)`; each scene reads the keys it knows): "seed" (campaign_seed: who wears what), "crew_size", "skins"
## (Array[CharacterSkin], seat order), "skippable" (default: true, except the intro until this player has watched it once), "manual"
## (probes: only Cutscene.step advances), "parent" (Node to hang the scene on, default this), "instant"; TruckOutro: "stats",
## "captions"; FallCam: "mouth", "drop_height", "caption", "on_update"; the in-room beats (IntroRoom, FailRoom, WinRoom): "level" (the
## MainLevel root). See each scene's `configure`.

signal started(id: StringName)
signal played(id: StringName, skipped: bool)  ## once per play(): the last part ended, was skipped, or the whole thing was aborted

const ACK_MARGIN_SEC := 5.0
const FIRST_WATCH_IDS: Array[StringName] = [&"intro"]  ## skippable only after this player has seen them once (D13)
const SCENES := {
	&"intro_van": {"scene": "res://src/cutscene/IntroVan.tscn", "sec": IntroVan.LENGTH_SEC},
	&"intro_cabin": {"scene": "res://src/cutscene/IntroCabin.tscn", "sec": IntroCabin.LENGTH_SEC},
	&"truck_outro": {"scene": "res://src/cutscene/TruckOutro.tscn", "sec": 0.0},  # open-ended: loops until the player continues
	&"fall": {"scene": "res://src/cutscene/FallCam.tscn", "sec": FallCam.LENGTH_SEC},
	&"intro_room": {"scene": "res://src/cutscene/IntroRoom.tscn", "sec": IntroRoom.LENGTH_SEC},  # IN the bar: the throw, the slam, the lock
	&"fail_room": {"scene": "res://src/cutscene/FailRoom.tscn", "sec": FailRoom.LENGTH_SEC},  # IN the bar: red alert, black screens, blood, the pull
	&"win_room": {"scene": "res://src/cutscene/WinRoom.tscn", "sec": WinRoom.LENGTH_SEC},  # IN the bar: green light, Gus cheers, the gas
}
const SEQUENCES := {
	&"intro": [&"intro_van", &"intro_cabin", &"intro_room"],
	&"fail": [&"fail_room", &"fall"],
	&"win": [&"win_room", &"truck_outro"],
}
## Sequences whose last part must play even when an earlier one is skipped: the win's truck is the payoff and carries the stats card.
const SKIP_KEEPS_LAST: Array[StringName] = [&"win"]

var current: Cutscene  ## the part on screen now, null between plays
var playing_id := &""

var _queue: Array[StringName] = []
var _opts := {}
var _skipped := false


static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k: StringName in SEQUENCES:
		out.append(k)
	for k: StringName in SCENES:
		out.append(k)
	return out


static func parts_of(id: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	if SEQUENCES.has(id):
		for p: StringName in SEQUENCES[id]:
			out.append(p)
	elif SCENES.has(id):
		out.append(id)
	return out


## Seconds the scripted part of `id` lasts (the sum of its parts). 0 = open-ended (TruckOutro).
static func length_sec(id: StringName) -> float:
	var total := 0.0
	for p in parts_of(id):
		total += float(SCENES[p]["sec"])
	return total


## A sequence that ends on a button (the truck's Continue): nothing scripted ends it, so the host has no length to wait for.
static func is_open_ended(id: StringName) -> bool:
	var parts := parts_of(id)
	return not parts.is_empty() and float(SCENES[parts[-1]]["sec"]) <= 0.0


## A9: how long the host waits for every peer's ack before it acts anyway. 0 = it does not wait (nothing follows an open-ended one).
static func max_wait_sec(id: StringName) -> float:
	var total := length_sec(id)
	return total + ACK_MARGIN_SEC if total > 0.0 and not is_open_ended(id) else 0.0


func is_playing() -> bool:
	return playing_id != &""


## Starts `id` (a scene or a sequence). False when it is unknown or something is already playing.
func play(id: StringName, opts := {}) -> bool:
	var parts := parts_of(id)
	if parts.is_empty():
		push_error("CutscenePlayer: unknown cutscene '%s'" % id)
		return false
	if is_playing():
		push_warning("CutscenePlayer: '%s' is still playing" % playing_id)
		return false
	_opts = opts.duplicate()
	if not _opts.has("skippable") and FIRST_WATCH_IDS.has(id):
		_opts["skippable"] = SaveManager.cutscene_seen(id)
	playing_id = id
	_queue = parts
	_skipped = false
	started.emit(id)
	if bool(_opts.get("instant", false)):
		_finish.call_deferred(true)  # deferred, so `play(...)` then `await played` still sees it
		return true
	_next_part()
	return true


## Skips the whole thing (every part still to come too).
func skip() -> void:
	if current != null:
		current.skip()


## Ends the whole thing now, skippable or not; the ack still fires.
func abort() -> void:
	_queue.clear()
	_skipped = true
	if current != null:
		current.abort()
	elif is_playing():
		_finish(true)


func _next_part() -> void:
	if _queue.is_empty():
		_finish(_skipped)
		return
	var part: StringName = _queue.pop_front()
	var packed := load(str(SCENES[part]["scene"])) as PackedScene
	var cs := packed.instantiate() as Cutscene
	cs.configure(_opts)
	var host := _opts.get("parent", self) as Node
	host.add_child(cs)
	if cs.on_stage:
		cs.global_position = Cutscene.STAGE_ORIGIN
	current = cs
	cs.finished.connect(_on_part_finished.bind(cs))
	cs.play()


func _on_part_finished(skipped: bool, cs: Cutscene) -> void:
	cs.queue_free()
	if current == cs:
		current = null
	if skipped:
		if SKIP_KEEPS_LAST.has(playing_id) and not _queue.is_empty():
			while _queue.size() > 1:
				_queue.pop_front()
		else:
			_skipped = true
			_queue.clear()
	_next_part()


func _finish(skipped: bool) -> void:
	var id := playing_id
	playing_id = &""
	_queue.clear()
	if FIRST_WATCH_IDS.has(id) and not skipped:
		SaveManager.mark_cutscene_seen(id)
	played.emit(id, skipped)
