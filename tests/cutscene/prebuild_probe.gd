extends SceneTree
## Cutscenes are built and compiled under black, never on a shown frame (adhoc-1014b C1, C3, C7, C9, C10). Headless, so nothing draws and a
## "drawn frame" is a plain one; what it proves is the ORDER and the bookkeeping, the pipeline counts are tools/perf_cutscenes.gd's:
##   S1 a stage part's lights and meshes are all on STAGE_LAYER, its camera sees only that and no farther than STAGE_FAR (a room part is untouched);
##   S2 `Cutscene.holding` counts +1 at play, -1 at the end, never below 0, and a part freed while playing gives it back;
##   S3 prepare() builds without showing (hidden, shell unopened, camera not current), play() then builds nothing; the player prepares the
##      stage parts of the intro behind a cover that blocks input, ends the black with the part, acks once, and a skip, an abort or a stall
##      during it leaves nothing built, nothing held and no cover; the win's truck is prepared under the room part's black;
##   C7 the crew has no physical bones; C9 the sounds are rendered by prerender(); the monster is built hidden and does not run hidden.
##   godot --path . --headless -s tests/cutscene/prebuild_probe.gd     prints PREBUILD OK

const VAN := "res://src/cutscene/IntroVan.tscn"
const CABIN := "res://src/cutscene/IntroCabin.tscn"
const TRUCK := "res://src/cutscene/TruckOutro.tscn"
const INTRO_ROOM := "res://src/cutscene/IntroRoom.tscn"
const FALL := "res://src/cutscene/FallCam.tscn"
const MOUTH := "res://src/cutscene/MonsterMouth.tscn"
const FAST := 200.0  ## Cutscene.time_scale: a 3 s part runs in a frame or two

var fails := 0
var base_cam: Camera3D
var router: UIRouter


class Hear extends Node:
	var calls: Array = []

	func _init() -> void:
		add_to_group(Cutscene.HOLD_GROUP)

	func cutscene_hold(on: bool, on_stage: bool) -> void:
		calls.append([on, on_stage])


## A render target of the level (the mirror's window pass, the TV's feeds): the sweep asks it to draw once.
class Target extends Node:
	var warms := 0
	var drew := true

	func _init() -> void:
		add_to_group(Cutscene.WARM_GROUP)

	func warm() -> bool:
		warms += 1
		return drew


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	SaveManager.root = "user://prebuild_probe"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	router = UIRouter.new()
	root.add_child(router)
	base_cam = Camera3D.new()
	root.add_child(base_cam)
	base_cam.make_current()
	await process_frame
	_stage_layer()
	_scene_flags()
	_hold_counter()
	_prepare_state()
	_crew_bodies()
	_sfx()
	_mouth_hidden()
	await _player_intro()
	await _player_skip_during_prepare()
	await _player_abort_during_prepare()
	await _player_first_watch()
	await _player_stall()
	await _player_win()
	await _player_extras()
	await _director()
	if fails == 0:
		print("PREBUILD OK")
	else:
		printerr("PREBUILD FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


func _make(path: String, opts := {}) -> Cutscene:
	var cs := (load(path) as PackedScene).instantiate() as Cutscene
	var o := {"seed": 4242, "manual": true, "crew_size": 4}
	o.merge(opts, true)
	cs.configure(o)
	root.add_child(cs)
	if cs.on_stage:
		cs.global_position = Cutscene.STAGE_ORIGIN
	return cs


func _camera_back(what: String) -> void:
	_check(root.get_camera_3d() == base_cam and not UIRouter.blocking() and Cutscene.holding == 0, "%s: the level's camera is back, nothing blocks input, nothing is held" % what)


func _visuals(cs: Node) -> Array[Node]:
	return cs.find_children("*", "VisualInstance3D", true, false)


# --- S1 -----------------------------------------------------------------------------------------------------------------------------

func _stage_layer() -> void:
	for path in [VAN, CABIN, TRUCK]:
		var cs := _make(path)
		cs.prepare()
		var vis := _visuals(cs)
		var lights := 0
		var off: Array[String] = []
		for n in vis:
			if n is Light3D:
				lights += 1
			if (n as VisualInstance3D).layers != Cutscene.STAGE_LAYER:
				off.append(String(n.name))
		_check(vis.size() > 5 and lights >= 1, "%s: it has meshes and lights to put on the layer (%d, %d lights)" % [cs.id(), vis.size(), lights])
		_check(off.is_empty(), "%s: every VisualInstance3D, lights too, is on STAGE_LAYER only (off: %s)" % [cs.id(), off])
		_check(cs.camera.cull_mask == Cutscene.STAGE_LAYER and is_equal_approx(cs.camera.far, Cutscene.STAGE_FAR), "%s: its camera sees the stage layer, no farther than %.0f m" % [cs.id(), Cutscene.STAGE_FAR])
		var count := vis.size()
		for time in cs.warm_times():
			cs.pose_at(time)
		cs.pose_at(CutscenePlayer.length_sec(StringName(cs.id())) * 0.5)
		_check(_visuals(cs).size() == count, "%s: posing it at any time adds nothing that could miss the layer" % cs.id())
		cs.free()
	var room := _make(INTRO_ROOM)  # a room part draws the bar: its camera is the game's kind
	room.prepare()
	_check(room.camera.cull_mask != Cutscene.STAGE_LAYER and room.camera.far > Cutscene.STAGE_FAR and room.visible, "%s: a room part's camera and visibility are untouched" % room.id())
	room.free()
	var mouth := MonsterMouth.new()  # the fall in the real room: given the Trapdoor's mouth it is a room part, and must see the bar
	var fall := _make(FALL, {"mouth": mouth})
	fall.prepare()
	_check(not fall.on_stage and fall.camera.cull_mask != Cutscene.STAGE_LAYER and fall.visible, "fall: in the room it is not culled to the stage")
	fall.free()
	mouth.free()


func _scene_flags() -> void:
	for id: StringName in CutscenePlayer.SCENES:
		var cs := (CutscenePlayer.SCENES[id]["scene"] as PackedScene).instantiate() as Cutscene
		var mouth := MonsterMouth.new() if id == &"fall" else null  # the game gives the fall its mouth: that is what makes it a room part
		cs.configure({"manual": true, "mouth": mouth})
		_check(cs.on_stage == bool(CutscenePlayer.SCENES[id]["stage"]), "player: '%s' is a stage part exactly when SCENES says so" % id)
		_check(cs.id() == id, "player: '%s' is the scene's own id" % id)
		cs.free()
		if mouth != null:
			mouth.free()
	_check(CutscenePlayer.max_wait_sec(&"intro") == CutscenePlayer.length_sec(&"intro") + CutscenePlayer.ACK_MARGIN_SEC and CutscenePlayer.ACK_MARGIN_SEC >= 5.0 + CutscenePlayer.PREPARE_MAX_SEC, "player: the host's wait covers the black prepare")


# --- S2 -----------------------------------------------------------------------------------------------------------------------------

func _hold_counter() -> void:
	var ear := Hear.new()
	root.add_child(ear)
	_check(Cutscene.holding == 0, "hold: nothing is held to begin with")
	Cutscene.hold(self, false, true)
	_check(Cutscene.holding == 0, "hold: it never goes below 0")
	ear.calls.clear()
	var a := _make(VAN)
	a.play()
	_check(Cutscene.holding == 1 and ear.calls == [[true, true]], "hold: a playing stage part holds, and the group hears it (%s)" % [ear.calls])
	a.abort()
	_check(Cutscene.holding == 0 and ear.calls == [[true, true], [false, true]], "hold: the end gives it back before the camera does (%s)" % [ear.calls])
	var b := _make(INTRO_ROOM)
	b.play()
	_check(Cutscene.holding == 1 and ear.calls[-1] == [true, false], "hold: a room part holds too, and says it is not on a stage")
	b.abort()
	var c := _make(CABIN)
	c.play()
	c.free()  # the level is freed mid-cutscene
	_check(Cutscene.holding == 0, "hold: a part freed while playing gives it back")
	base_cam.make_current()
	_camera_back("hold")
	for n in root.get_children():
		if n is Cutscene:
			n.free()
	ear.free()


# --- S3: prepare / play -------------------------------------------------------------------------------------------------------------

func _prepare_state() -> void:
	var van := _make(VAN)
	var cabin := _make(CABIN)
	van.prepare()
	cabin.prepare()
	for cs in [van, cabin]:
		_check(cs.prepared and not cs.playing and not cs.visible and not cs.camera.is_current() and not cs.shell.visible and not cs.is_processing(), "prepare: %s is built, hidden, not current, its shell unopened, nothing running" % cs.id())
	_check(root.get_camera_3d() == base_cam and not UIRouter.blocking(), "prepare: nothing took the camera or the input")
	var van_nodes := _visuals(van).size() + van.get_child_count()
	van.play()
	_check(van.playing and van.visible and van.camera.is_current() and van.shell.visible and UIRouter.blocking() and not cabin.shell.visible, "play: a prepared part shows and takes over; the other one's shell stays shut (UIRouter keeps one modal)")
	_check(_visuals(van).size() + van.get_child_count() == van_nodes, "play: a prepared part builds nothing")
	van.abort()
	cabin.play()
	_check(cabin.playing and cabin.shell.visible and UIRouter.blocking() and cabin.camera.is_current(), "play: the second part opens after the first has closed")
	cabin.abort()
	_camera_back("prepare / play")
	var late := _make(TRUCK)  # nobody prepared it: play() does
	late.play()
	_check(late.prepared and late.playing and late.shell.visible, "play: an unprepared part prepares itself")
	late.abort()
	for n in root.get_children():
		if n is Cutscene:
			n.free()
	base_cam.make_current()


# --- C7 / C9 ------------------------------------------------------------------------------------------------------------------------

func _crew_bodies() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var crew := CrewDress.spawn(holder, 4, [] as Array[CharacterSkin])
	var ours := 0  # the engine gives every Skeleton3D an internal simulator of its own; what Humanoid adds is a child of the skeleton
	for h in crew:
		for c in h.get_node("Skeleton").get_children():
			ours += 1 if c is PhysicalBoneSimulator3D or c is PhysicalBone3D else 0
	_check(crew.size() == 4 and holder.find_children("*", "PhysicalBone3D", true, false).is_empty() and ours == 0, "crew: four bodies with no physical bone and no simulator of ours")
	crew[0].ragdoll(Vector3.ONE)
	_check(not crew[0].is_ragdoll(), "crew: a body that cannot go limp does not")
	var walker := Humanoid.new()
	holder.add_child(walker)
	_check(walker.find_children("*", "PhysicalBone3D", true, false).size() == 11, "a player's body keeps its 11 physical bones")
	walker.ragdoll(Vector3(0.0, 1.0, 0.0))
	_check(walker.is_ragdoll(), "a player's body still goes limp")
	holder.free()


func _sfx() -> void:
	CutsceneSfx._cache.clear()
	CutsceneSfx.prerender()
	_check(CutsceneSfx._cache.size() == CutsceneSfx.SECONDS.size(), "sfx: prerender() renders every kind (%d)" % CutsceneSfx._cache.size())
	var first := CutsceneSfx.stream(CutsceneSfx.Kind.ALARM)
	CutsceneSfx.prerender()
	_check(CutsceneSfx.stream(CutsceneSfx.Kind.ALARM) == first and first.data.size() == int(CutsceneSfx.SECONDS[CutsceneSfx.Kind.ALARM] * CutsceneSfx.MIX_RATE) * 2, "sfx: it renders once, and the buffer is the whole sound")


func _mouth_hidden() -> void:
	var m := (load(MOUTH) as PackedScene).instantiate() as MonsterMouth
	m.visible = false
	root.add_child(m)
	_check(not m.is_processing(), "mouth: parked hidden it does not run")
	m.visible = true
	_check(m.is_processing(), "mouth: shown it breathes")
	m.visible = false
	_check(not m.is_processing(), "mouth: hidden again it stops")
	m.free()


# --- the player ---------------------------------------------------------------------------------------------------------------------

func _new_player(events: Array) -> CutscenePlayer:
	var player := CutscenePlayer.new()
	root.add_child(player)
	player.started.connect(func(id: StringName) -> void: events.append("start " + String(id)))
	player.played.connect(func(id: StringName, skipped: bool) -> void: events.append("played %s %s" % [id, skipped]))
	return player


func _frames_until(cond: Callable, limit := 600) -> int:
	var n := 0
	while not cond.call() and n < limit:
		await process_frame
		n += 1
	return n


func _cutscenes_under(player: Node) -> int:
	var n := 0
	for c in player.get_children():
		if c is Cutscene and not c.is_queued_for_deletion():
			n += 1
	return n


func _player_intro() -> void:
	var events := []
	var player := _new_player(events)
	Cutscene.time_scale = FAST
	CutscenePlayer.bar_warmed = false
	var target := Target.new()
	var idle_target := Target.new()
	idle_target.drew = false
	root.add_child(target)
	root.add_child(idle_target)
	_check(player.play(&"intro", {"seed": 31, "crew_size": 2, "skippable": true}), "intro: starts")
	_check(player.is_playing() and player.current == null and UIRouter.blocking() and root.get_camera_3d() == base_cam, "intro: under a black cover that holds the input, the level's camera still current, nothing shown yet")
	_check(events == ["start intro"], "intro: started is announced at once")
	var frames := await _frames_until(func() -> bool: return player.current != null)
	_check(player.current is IntroVan and player.current.playing and player.current.visible, "intro: the van plays when the prepare is done")
	_check(frames >= CutscenePlayer.BAR_VIEWS.size() + 4, "intro: the bar drew from every side first, then one more frame for the level's render target (%d frames before the van)" % frames)
	_check(target.warms == 1 and idle_target.warms == 1, "intro: every render target of the level was asked to draw once under the black (%d, %d)" % [target.warms, idle_target.warms])
	var cabin := player._ready_parts.get(&"intro_cabin") as Cutscene
	_check(cabin != null and cabin.prepared and not cabin.visible and not cabin.playing and not cabin.shell.visible and not cabin.camera.is_current(), "intro: the cabin was built with the van, hidden, shut, waiting")
	_check(Cutscene.holding == 1 and not player._held, "intro: one hold, the van's; the prepare's own is released")
	_check(player._cover == null, "intro: the cover went with the van's own shell opening")
	var blocked_gap := [false]
	var watch := func() -> void: blocked_gap[0] = blocked_gap[0] or not UIRouter.blocking()
	while player.is_playing() and player.current != null and player.current is IntroVan:
		watch.call()
		await process_frame
	_check(player.current is IntroCabin and player.current.playing and cabin == player.current, "intro: the cabin plays on the van's cut, the one built before")
	_check(not blocked_gap[0], "intro: the game's input was never free between the cover and the van")
	await _frames_until(func() -> bool: return not player.is_playing())
	_check(events == ["start intro", "played intro false"], "intro: one start, one ack, not skipped (%s)" % [events])
	_check(SaveManager.cutscene_seen(&"intro") and CutscenePlayer.bar_warmed, "intro: seen, and the bar is marked warm")
	target.free()
	idle_target.free()
	await process_frame
	_check(_cutscenes_under(player) == 0 and player._ready_parts.is_empty(), "intro: nothing is left built")
	_camera_back("the intro")
	player.free()
	Cutscene.time_scale = 1.0


func _player_skip_during_prepare() -> void:
	var events := []
	var player := _new_player(events)
	player.play(&"intro", {"seed": 5, "skippable": true})
	player.skip()
	_check(not player.is_playing() and events == ["start intro", "played intro true"] and player.current == null, "skip: at once, during the cover: one ack, skipped (%s)" % [events])
	await process_frame
	_check(_cutscenes_under(player) == 0 and player._cover == null and player._ready_parts.is_empty(), "skip: nothing built, no cover")
	_camera_back("skip at once")
	events.clear()
	player.play(&"intro", {"seed": 5, "skippable": true})
	await _frames_until(func() -> bool: return not player._ready_parts.is_empty())
	_check(player.current == null and player._preparing and player._held, "skip: the van and the cabin are built, not shown, the prepare holds")
	var built: Array = player._ready_parts.values()
	player.skip()
	_check(not player.is_playing() and events == ["start intro", "played intro true"], "skip: in the middle of the prepare: one ack, skipped (%s)" % [events])
	_check(built.all(func(cs: Cutscene) -> bool: return cs.is_queued_for_deletion()) and player._ready_parts.is_empty(), "skip: what was built is freed")
	await _frames_until(func() -> bool: return true, 3)
	_camera_back("skip in the middle")
	await process_frame
	_check(_cutscenes_under(player) == 0 and events.size() == 2, "skip: nothing comes back to life, no second ack")
	player.free()


func _player_abort_during_prepare() -> void:
	var events := []
	var player := _new_player(events)
	player.play(&"intro", {"seed": 5, "skippable": false})
	await _frames_until(func() -> bool: return not player._ready_parts.is_empty())
	player.abort()
	_check(not player.is_playing() and events == ["start intro", "played intro true"], "abort: a prepare in progress ends, acked as skipped, even when it cannot be skipped (%s)" % [events])
	await process_frame
	_check(_cutscenes_under(player) == 0 and player._cover == null, "abort: nothing built, no cover")
	_camera_back("abort")
	await process_frame
	_check(events.size() == 2, "abort: one ack")
	player.free()


func _player_first_watch() -> void:
	var events := []
	var player := _new_player(events)
	player.play(&"intro", {"seed": 5, "skippable": false})
	_check(not player._cover.skip_button.visible, "first watch: the cover has no Skip button")
	player.skip()
	_check(player.is_playing() and player._preparing, "first watch: Skip is ignored during the prepare")
	player.abort()
	player.free()
	_camera_back("first watch")


## A prepare step that never finishes (a window that draws nothing) must not leave the game under black.
func _player_stall() -> void:
	var events := []
	var player := _new_player(events)
	Cutscene.time_scale = FAST
	player.play(&"intro", {"seed": 5, "skippable": true})
	await _frames_until(func() -> bool: return not player._ready_parts.is_empty())
	player._kick = Time.get_ticks_msec() - int(CutscenePlayer.PREPARE_STALL_SEC * 1000.0) - 1000
	var t0 := Time.get_ticks_msec()
	while player.current == null and Time.get_ticks_msec() - t0 < 4000:
		await process_frame
	_check(player.current is IntroVan and player.current.playing and player._cover == null and not player._preparing, "stall: the watchdog plays the van as it is")
	await _frames_until(func() -> bool: return not player.is_playing())
	_check(events == ["start intro", "played intro false"], "stall: and the intro still ends with one ack (%s)" % [events])
	await process_frame
	_camera_back("stall")
	player.free()
	Cutscene.time_scale = 1.0


func _player_win() -> void:
	var events := []
	var player := _new_player(events)
	Cutscene.time_scale = FAST
	var opts := {"seed": 8, "crew_size": 2, "stats": {}, "captions": []}
	player.play(&"win", opts)
	_check(player.current is WinRoom and player.current.playing and player._cover == null, "win: the room part starts at once, as ever: it builds at its own start")
	await _frames_until(func() -> bool: return player.current == null or not player.current is WinRoom)
	_check(player.is_playing() and player.current == null and player._preparing and UIRouter.blocking(), "win: when the room ends, the truck is prepared under a cover")
	_check(not player._cover.skip_button.visible, "win: the truck cannot be skipped before it is shown")
	player.skip()
	_check(player._preparing, "win: Skip is ignored during the truck's prepare")
	await _frames_until(func() -> bool: return player.current != null)
	_check(player.current is TruckOutro and player.current.playing and player.current.prepared and player._cover == null, "win: the truck plays after its prepare")
	_check(Cutscene.holding == 1, "win: held by the truck alone")
	player.current.finish()
	await process_frame
	_check(events == ["start win", "played win false"], "win: ends on the truck, one ack (%s)" % [events])
	await process_frame
	_camera_back("win")
	# a skipped room part still leaves the truck (SKIP_KEEPS_LAST)
	events.clear()
	player.play(&"win", opts)
	player.skip()
	await _frames_until(func() -> bool: return player.current is TruckOutro)
	_check(player.current is TruckOutro and events == ["start win"], "win: skipping the room still plays the truck, prepared (%s)" % [events])
	player.current.abort()
	await process_frame
	_check(events == ["start win", "played win true"], "win: aborting the truck acks as skipped (%s)" % [events])
	await process_frame
	_camera_back("win skipped")
	player.free()
	Cutscene.time_scale = 1.0


func _player_extras() -> void:
	var events := []
	var player := _new_player(events)
	Cutscene.time_scale = FAST
	var prop := Node3D.new()
	prop.visible = false
	root.add_child(prop)
	var puff := CPUParticles3D.new()  # a one-shot burst parked at level load: over by the time the black draws it
	puff.one_shot = true
	puff.emitting = false
	prop.add_child(puff)
	player.add_warm(prop, Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 5.0)))
	player.play(&"win", {"seed": 8, "crew_size": 1, "stats": {}, "captions": []})
	_check(player.current == null and player._preparing, "extras: a prop waiting to be drawn makes even a room part's start a black prepare")
	var shown := [false]
	var bursting := [false]
	var named := [false]
	var frames := 0
	while player.current == null and frames < 600:
		shown[0] = shown[0] or prop.visible
		bursting[0] = bursting[0] or (prop.visible and puff.emitting)
		named[0] = named[0] or (prop.visible and String(root.get_viewport().get_camera_3d().name) == "CutsceneCamera")
		await process_frame
		frames += 1
	_check(shown[0] and not prop.visible and player.warm_extras.is_empty(), "extras: it was drawn once, then hidden again, and the list is empty")
	_check(bursting[0], "extras: a parked one-shot burst bursts again while it is drawn")
	_check(named[0], "extras: the warm camera carries the cutscene camera's name (the quality hold's watchdog)")
	await process_frame
	_check(prop.get_child_count() == 1, "extras: its throwaway camera is gone")  # the puff stays
	player.abort()
	await process_frame
	await process_frame
	prop.free()
	player.free()
	Cutscene.time_scale = 1.0
	base_cam.make_current()
	_camera_back("extras")


# --- the director -------------------------------------------------------------------------------------------------------------------

func _director() -> void:
	var quiet_level := Node3D.new()
	var quiet_trap := Trapdoor.new()
	quiet_trap.name = "Trapdoor"
	quiet_level.add_child(quiet_trap)
	var quiet := CutsceneDirector.new()
	quiet_level.add_child(quiet)
	CutsceneDirector.skip_cutscenes = true
	root.add_child(quiet_level)
	await process_frame
	_check(quiet._mouth == null and quiet.cutscenes.warm_extras.is_empty(), "director: with cutscenes skipped it builds nothing")
	quiet_level.free()
	var level := Node3D.new()
	var trap := Trapdoor.new()
	trap.name = "Trapdoor"
	level.add_child(trap)
	var d := CutsceneDirector.new()
	d.name = "CutsceneDirector"
	level.add_child(d)
	CutsceneDirector.skip_cutscenes = false
	CutsceneSfx._cache.clear()
	root.add_child(level)
	await process_frame
	_check(d._mouth != null and not d._mouth.visible and d._mouth.get_parent() == trap.pit() and not d._mouth.is_processing(), "director: the monster is built at level load, hidden in the Pit, not running")
	var rooms := 2 if (FailRoom as Script).has_method(&"prewarm") and (WinRoom as Script).has_method(&"prewarm") else 0  # S6 (c-scenes): the beats' new pieces
	_check(d.cutscenes.warm_extras.size() == 1 + rooms and d.cutscenes.warm_extras[0].node == d._mouth, "director: the monster and the beats' new pieces are queued for their first draw under black")
	for e: Dictionary in d.cutscenes.warm_extras:
		var n := e.node as Node3D
		_check(not n.visible and (n == d._mouth or n.get_parent() == level), "director: %s is parked hidden (a beat's pieces under the level)" % n.name)
	_check(CutsceneSfx._cache.size() == CutsceneSfx.SECONDS.size(), "director: the sounds are rendered at level load")
	level.free()
	CutsceneDirector.skip_cutscenes = true
