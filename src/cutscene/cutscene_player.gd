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
##
## PREPARE (adhoc-1014b C3). A STAGE part (van, cabin, truck: far from the room, nothing of the bar in it) is built and drawn twice under
## black BEFORE it is shown, so its first shown frame builds and compiles nothing. When one is due and not ready, the player raises a black
## cover (a CutsceneShell on fade 1, which also holds the game's input), waits until that black is on screen, lets a fresh level's bar draw
## from every side under it (BAR_VIEWS: its pipelines compile now), waits for the Mirror's capture, then builds each part (one per frame),
## draws each at a few moments of its timeline (Cutscene.warm_times: a light that comes on later is lit once under the black), and plays. At the intro's start that covers the van and the cabin together; at the end of the win's room it covers the
## truck. Room parts build at their own start (they work the level's fixtures: no undo, remote players may not exist yet). A skip, an abort or
## a stall (PREPARE_STALL_SEC without a step finishing) during it frees what was built and still acks once. A `manual` play (probes, the
## preview tools) prepares and plays in the one call, as it always did: nothing is drawn, so nothing is covered.

signal started(id: StringName)
signal played(id: StringName, skipped: bool)  ## once per play(): the last part ended, was skipped, or the whole thing was aborted

const PREPARE_MAX_SEC := 4.0  ## the worst the black prepare is allowed to take (a slow phone); the host's ack wait grows by it
const ACK_MARGIN_SEC := 5.0 + PREPARE_MAX_SEC
const PREPARE_STALL_SEC := 6.0  ## a prepare step that takes this long is stuck (a window that draws nothing): play unprepared instead
## Where the bar is drawn from under the first black, once per run of the app: from the middle of the room all the way round, up and down, with a
## camera that culls nothing (a first-person camera never draws the local player's head, a cutscene's camera does). Every instance the room
## cutscenes will show is in one of these frustums, so none builds its surface cache or compiles its draw while the cutscene is on screen.
const BAR_VIEWS: Array[Transform3D] = [
	Transform3D(Basis(Vector3.UP, 0.0), Vector3(0.0, 1.6, 0.0)),
	Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.0, 1.6, 0.0)),
	Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 1.6, 0.0)),
	Transform3D(Basis(Vector3.UP, PI * 1.5), Vector3(0.0, 1.6, 0.0)),
	Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 1.6, 0.0)),
	Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 1.6, 0.0)),
]
const BAR_FOV := 100.0
## The room beat's own shots at the door (IntroRoom._camera: the wide shot from the south end, the close-up from inside), as [eye, target, fov]: drawn with the
## door flung open and the crew in view, so what the door reveals (the doorway's black quad, the leaf and the bolt mid-swing) and the first body through it
## compile under the black and not at T_OPEN. The numbers are IntroRoom's; keep them in step.
const DOOR_VIEWS: Array[Array] = [
	[Vector3(0.0, 1.6, 5.4), Vector3(0.0, 1.4, -6.6), 66.0],
	[Vector3(0.3, 1.5, -4.9), Vector3(0.35, 1.3, -6.85), 68.0],
]
const WARM_FRAMES := 2  ## frames each prepared part is drawn under black: the first uploads and compiles, the second proves it
const MIRROR_WAIT_SEC := 1.5  ## how long the prepare waits for the Mirror's cube capture (seam S5)
const FIRST_WATCH_IDS: Array[StringName] = [&"intro"]  ## skippable only after this player has seen them once (D13)
## "stage": it plays far from the room (Cutscene.on_stage), so it can be prepared under black ahead of its turn.
const SCENES := {
	&"intro_van": {"scene": preload("res://src/cutscene/IntroVan.tscn"), "sec": IntroVan.LENGTH_SEC, "stage": true},
	&"intro_cabin": {"scene": preload("res://src/cutscene/IntroCabin.tscn"), "sec": IntroCabin.LENGTH_SEC, "stage": true},
	&"truck_outro": {"scene": preload("res://src/cutscene/TruckOutro.tscn"), "sec": 0.0, "stage": true},  # open-ended: loops until the player continues
	&"fall": {"scene": preload("res://src/cutscene/FallCam.tscn"), "sec": FallCam.LENGTH_SEC, "stage": false},
	&"intro_room": {"scene": preload("res://src/cutscene/IntroRoom.tscn"), "sec": IntroRoom.LENGTH_SEC, "stage": false},  # IN the bar: the throw, the slam, the lock
	&"fail_room": {"scene": preload("res://src/cutscene/FailRoom.tscn"), "sec": FailRoom.LENGTH_SEC, "stage": false},  # IN the bar: red alert, black screens, blood, the pull
	&"win_room": {"scene": preload("res://src/cutscene/WinRoom.tscn"), "sec": WinRoom.LENGTH_SEC, "stage": false},  # IN the bar: green light, Gus cheers, the gas
}
const SEQUENCES := {
	&"intro": [&"intro_van", &"intro_cabin", &"intro_room"],
	&"fail": [&"fail_room", &"fall"],
	&"win": [&"win_room", &"truck_outro"],
}
## Sequences whose last part must play even when an earlier one is skipped: the win's truck is the payoff and carries the stats card.
const SKIP_KEEPS_LAST: Array[StringName] = [&"win"]

## True once the bar has drawn under the intro's black prepare (its pipelines are compiled): a later level in the same run of the app skips it.
static var bar_warmed := false

var current: Cutscene  ## the part on screen now, null between plays
var playing_id := &""
var warm_extras: Array[Dictionary] = []  ## [{node: Node3D, view: Transform3D}] drawn once under the next black prepare (CutsceneDirector: the monster's mouth)

var _queue: Array[StringName] = []
var _opts := {}
var _skipped := false
var _gen := 0  # bumped by whatever ends or abandons a prepare: the coroutine that finds it moved on stops where it is
var _preparing := false
var _ready_parts := {}  # StringName -> Cutscene: built, hidden, drawn twice, waiting for its turn
var _cover: CutsceneShell
var _cover_layer: CanvasLayer
var _held := false  # the prepare's own count in Cutscene.holding
var _warm_holder: Node3D  # what a warm draw shows right now: a prepared part or an extra's node
var _warm_cam: Camera3D  # its camera, current while it is drawn
var _undo: Array[Callable] = []  # what the sweep changed in the level for its shots (the door open, the crew shown): put back by _leave_warm
var _warm_own_cam := false  # the camera is a throwaway of ours (an extra's)
var _warm_prev: Camera3D  # the camera to give back
var _kick := 0  # ticks of the last finished prepare step
var _dog: Timer


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


## A node (a prop that is hidden in the level) drawn once under the next black prepare, so its pipelines are compiled before the
## cutscene that shows it. `view` is the warm camera's transform in the node's own space.
func add_warm(node: Node3D, view: Transform3D) -> void:
	warm_extras.append({"node": node, "view": view})


## Skips the whole thing (every part still to come too).
func skip() -> void:
	if current != null:
		current.skip()
	elif _preparing and _prepare_skippable():
		_cancel_prepare()
		_after_part(true)


## Ends the whole thing now, skippable or not; the ack still fires.
func abort() -> void:
	_queue.clear()
	_skipped = true
	if current != null:
		current.abort()
	elif is_playing():
		_cancel_prepare()
		_finish(true)


func _exit_tree() -> void:
	_gen += 1
	_undo_sweep()
	_set_hold(false)


func _next_part() -> void:
	if _queue.is_empty():
		_finish(_skipped)
		return
	if _needs_prepare():
		_prepare_then_play()  # a coroutine: it plays the part when it is done
		return
	_start_part(_queue.pop_front())


## True when the part that is next draws something it has not drawn yet: a stage part nobody prepared, or an extra still waiting for its first draw.
func _needs_prepare() -> bool:
	if bool(_opts.get("manual", false)):
		return false
	var next: StringName = _queue[0]
	return (bool(SCENES[next]["stage"]) and not _ready_parts.has(next)) or not warm_extras.is_empty()


func _make(part: StringName) -> Cutscene:
	var cs := (SCENES[part]["scene"] as PackedScene).instantiate() as Cutscene
	cs.configure(_opts)
	var host := _opts.get("parent", self) as Node
	host.add_child(cs)
	if cs.on_stage:
		cs.global_position = Cutscene.STAGE_ORIGIN
	cs.finished.connect(_on_part_finished.bind(cs))
	return cs


func _start_part(part: StringName) -> void:
	var cs: Cutscene = _ready_parts.get(part)
	_ready_parts.erase(part)
	if cs == null:
		cs = _make(part)
	_drop_cover()  # in the same frame as the part's own shell opening: the game's input never gets a gap
	current = cs
	cs.play()


func _on_part_finished(skipped: bool, cs: Cutscene) -> void:
	cs.queue_free()
	if current == cs:
		current = null
	_after_part(skipped)


## A part ended (or the prepare for it was skipped): a skip ends the chain, except that the win's last part still plays.
func _after_part(skipped: bool) -> void:
	if skipped:
		if SKIP_KEEPS_LAST.has(playing_id) and not _queue.is_empty():
			while _queue.size() > 1:
				_queue.pop_front()
		else:
			_skipped = true
			_queue.clear()
	_next_part()


# --- prepare (adhoc-1014b C3) -------------------------------------------------------------------------------------------------------

func _prepare_then_play() -> void:
	var gen := _gen
	var run: Array[StringName] = []  # the stage parts from here to the next room part: they are all built in this one black
	for part: StringName in _queue:
		if not bool(SCENES[part]["stage"]):
			break
		run.append(part)
	_preparing = true
	_kick = Time.get_ticks_msec()
	_start_dog()
	await _black_prepare(run, gen)
	if gen != _gen:
		return  # skipped, aborted or given up while it ran: whoever did it already cleaned up
	_preparing = false
	_stop_dog()
	_start_part(_queue.pop_front())


func _black_prepare(run: Array[StringName], gen: int) -> void:
	_raise_cover()
	await _drawn()  # the black is on screen before anything below can stall a frame
	if gen != _gen:
		return
	if not bar_warmed and playing_id == &"intro":  # a fresh level's bar has never been drawn: it does now, under the black, not in the first room beat
		await _sweep_bar(gen)
		if gen != _gen:
			return
		bar_warmed = true
	await _mirror_captured(gen)
	if gen != _gen:
		return
	_set_hold(true)  # builds and camera swaps from here on: no QualityManager sampling, no glare walk
	for part in run:
		if not _ready_parts.has(part):
			var cs := _make(part)
			cs.prepare()
			_ready_parts[part] = cs
			await _stepped()  # one build per frame
			if gen != _gen:
				return
	_warm_prev = get_viewport().get_camera_3d()
	for part in run:
		var cs := _ready_parts[part] as Cutscene
		await _warm(cs, cs.camera, false, cs, gen)
		if gen != _gen:
			return
	var extras := warm_extras.duplicate()
	warm_extras.clear()
	for e: Dictionary in extras:
		var holder := e.node as Node3D
		if is_instance_valid(holder):
			var cam := Camera3D.new()
			cam.name = &"CutsceneCamera"  # the hold's watchdog looks for this name (QualityManager.CUTSCENE_CAMERA)
			holder.add_child(cam)
			cam.transform = e.view
			await _warm(holder, cam, true, null, gen)
			if gen != _gen:
				return
	_set_hold(false)


## The bar from every side (BAR_VIEWS), one drawn frame each, then each render target of the level once (Cutscene.WARM_GROUP), then the game's camera back.
func _sweep_bar(gen: int) -> void:
	_warm_prev = get_viewport().get_camera_3d()
	_warm_cam = Camera3D.new()
	_warm_cam.fov = BAR_FOV
	_warm_own_cam = true
	add_child(_warm_cam)
	for v in BAR_VIEWS:
		_warm_cam.global_transform = v
		_warm_cam.make_current()
		await _drawn()
		if gen != _gen:
			return
	for n in get_tree().get_nodes_in_group(Cutscene.WARM_GROUP):  # the level's own render targets (the mirror's window pass, the TV's feeds): their passes compile too
		if bool(n.call(&"warm")):
			await _drawn()
			if gen != _gen:
				return
	await _sweep_door(gen)
	_leave_warm()


## The door's two shots with the door open and the crew shown (undone by `_leave_warm`, so a skip or an abort puts them back too). Nothing without a level.
func _sweep_door(gen: int) -> void:
	var level := _opts.get("level") as Node
	var door := level.get_node_or_null(^"EntranceDoor") as EntranceDoor if level != null else null
	if door == null:
		return
	_undo.append(door.set_bolt.bind(door.bolt))
	_undo.append(door.set_openness.bind(door.openness))
	door.set_openness(1.0)
	for m: Dictionary in RoomCutscene.crew_of(level):
		var p: Player = m.player
		_undo.append(p.set_visible.bind(p.visible))
		p.visible = true
	for v in DOOR_VIEWS:
		_warm_cam.global_transform = CutsceneKit.look_from(v[0], v[1])
		_warm_cam.fov = v[2]
		await _drawn()
		if gen != _gen:
			return


func _undo_sweep() -> void:
	for u in _undo:
		if u.is_valid():
			u.call()
	_undo.clear()


## Draws `holder` with `cam` current, under the black: a prepared `part` at each of its warm times (the first for WARM_FRAMES frames, the
## others for one), an extra once.
func _warm(holder: Node3D, cam: Camera3D, own_cam: bool, part: Cutscene, gen: int) -> void:
	_warm_holder = holder
	_warm_cam = cam
	_warm_own_cam = own_cam
	holder.visible = true
	if part == null:
		for p: CPUParticles3D in holder.find_children("*", "CPUParticles3D", true, false):
			p.restart()  # a one-shot burst parked at level load is long over by the black: it bursts again for the warm frames
	cam.make_current()
	var times := part.warm_times() if part != null else PackedFloat32Array([0.0])
	for k in times.size():
		if part != null:
			part.pose_at(times[k])
		for i in (WARM_FRAMES if k == 0 else 1):
			await _drawn()
			if gen != _gen:
				return
	if part != null:
		part.pose_at(0.0)
	_leave_warm()


## Hides what a warm draw showed and gives the camera back; also what a cancelled prepare does for the draw it stopped in.
func _leave_warm() -> void:
	_undo_sweep()
	if _warm_holder != null and is_instance_valid(_warm_holder):
		_warm_holder.visible = false
	if _warm_cam != null and is_instance_valid(_warm_cam):
		if _warm_prev != null and is_instance_valid(_warm_prev) and _warm_prev.is_inside_tree():
			_warm_prev.make_current()
		else:
			_warm_cam.clear_current(false)
		if _warm_own_cam:
			_warm_cam.queue_free()
	_warm_holder = null
	_warm_cam = null
	_warm_own_cam = false


## The Mirror's cube capture (seam S5) runs before the cutscene or never during it; this waits for it, a little.
func _mirror_captured(gen: int) -> void:
	var m := get_tree().get_first_node_in_group(&"mirror")
	if m == null or not m.has_signal(&"captured") or bool(m.get(&"is_captured")):
		return
	var done := [false]
	m.connect(&"captured", func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	var until := Time.get_ticks_msec() + int(MIRROR_WAIT_SEC * 1000.0)
	while not done[0] and Time.get_ticks_msec() < until and gen == _gen:
		await _stepped()


func _raise_cover() -> void:
	if _cover != null:
		return
	_cover_layer = CanvasLayer.new()
	_cover_layer.layer = 100
	add_child(_cover_layer)
	_cover = CutsceneShell.new()
	_cover_layer.add_child(_cover)
	_cover.skip_button.visible = _prepare_skippable()
	_cover.skip_requested.connect(skip)
	_cover.open()
	_cover.set_fade(1.0)


## Skip during a prepare ends the sequence like Skip on a part would; the win's truck (kept on a skip) cannot be skipped before it is shown.
func _prepare_skippable() -> bool:
	return bool(_opts.get("skippable", true)) and not SKIP_KEEPS_LAST.has(playing_id)


func _drop_cover() -> void:
	if _cover != null and is_instance_valid(_cover):
		_cover.close()
	if _cover_layer != null and is_instance_valid(_cover_layer):
		_cover_layer.queue_free()
	_cover = null
	_cover_layer = null


## What a skip, an abort or a stall does to a prepare: nothing built stays, the camera and the hold come back, the cover goes.
func _cancel_prepare() -> void:
	_gen += 1
	_preparing = false
	_stop_dog()
	_leave_warm()
	for cs: Cutscene in _ready_parts.values():
		if is_instance_valid(cs):
			cs.queue_free()
	_ready_parts.clear()
	warm_extras.clear()
	_set_hold(false)
	_drop_cover()


func _set_hold(on: bool) -> void:
	if on != _held:
		_held = on
		Cutscene.hold(get_tree(), on, true)


## The next frame, built (a plain frame: one build or one wait per frame).
func _stepped() -> void:
	await get_tree().process_frame
	_kick = Time.get_ticks_msec()


## The next frame that is DRAWN (a plain frame where nothing draws: headless).
func _drawn() -> void:
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw
	_kick = Time.get_ticks_msec()


func _start_dog() -> void:
	if _dog == null:
		_dog = Timer.new()
		_dog.wait_time = 1.0
		add_child(_dog)
		_dog.timeout.connect(_watch)
	_dog.start()


func _stop_dog() -> void:
	if _dog != null:
		_dog.stop()


## A prepare step that never finishes (nothing draws: a minimised window) must not leave the game under a black cover: play the part as it is.
func _watch() -> void:
	if not _preparing or Time.get_ticks_msec() - _kick < int(PREPARE_STALL_SEC * 1000.0):
		return
	push_warning("CutscenePlayer: the prepare stalled for %.0f s, playing '%s' unprepared" % [PREPARE_STALL_SEC, playing_id])
	_cancel_prepare()
	_start_part(_queue.pop_front())


func _finish(skipped: bool) -> void:
	var id := playing_id
	playing_id = &""
	_queue.clear()
	if FIRST_WATCH_IDS.has(id) and not skipped:
		SaveManager.mark_cutscene_seen(id)
	played.emit(id, skipped)
