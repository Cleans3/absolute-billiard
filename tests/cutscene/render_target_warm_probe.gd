extends SceneTree
## The intro's black prepare in the real MainLevel (adhoc-1014b): before the first part shows, the level's own render targets, the mirror's window
## pass and the TV's feeds, were asked to draw once (their framebuffers differ from the main view's, so their pipelines compile on a first draw: under
## the black, not in the first room beat). Headless draws nothing, so the requests are counted: `Mirror.renders`, `StreamTv.renders`.
##   godot --path . --headless -s tests/cutscene/render_target_warm_probe.gd     prints RENDER TARGET WARM OK

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_render_target_warm"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	CutscenePlayer.bar_warmed = false
	Cutscene.time_scale = 20.0
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	CutsceneDirector.skip_cutscenes = false  # before the level loads: it plays the intro from the fresh run's own cue
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	var director: CutsceneDirector
	var frames := 0
	while director == null and frames < 3000:
		var scene := current_scene
		if scene != null and scene.name == "MainLevel":
			director = scene.get_node_or_null("CutsceneDirector") as CutsceneDirector
		await process_frame
		frames += 1
	_check(director != null, "the real MainLevel has a CutsceneDirector")
	if director == null:
		_finish()
		return
	var level := director.level
	var mirror := level.get_node("Mirror") as Mirror
	var tv := level.get_node("Tv") as StreamTv
	var tier := clampi(QualityManager.current_tier, 0, 2)
	_check(mirror.renders == 0 and tv.renders == [0, 0], "nothing drew yet: headless has no camera, the glass and the TV are 'off screen' (%d, %s)" % [mirror.renders, tv.renders])
	var door := level.get_node("EntranceDoor") as EntranceDoor
	var crew := RoomCutscene.crew_of(level)
	_check(not crew.is_empty() and door.openness == 0.0 and door.bolt == 1.0, "the door is shut and bolted, the crew stands in the level")
	var hidden := (crew[0].player as Player).visible if not crew.is_empty() else true
	(crew[0].player as Player).visible = false  # a body the sweep has to show for the door's wide shot, and give back hidden
	var open_seen := [0.0]
	var shown := [false]
	frames = 0
	while director.cutscenes.current == null and frames < 3000:
		open_seen[0] = maxf(open_seen[0], door.openness)
		shown[0] = shown[0] or (door.openness > 0.99 and (crew[0].player as Player).visible)
		await process_frame
		frames += 1
	_check(open_seen[0] == 1.0 and shown[0], "the sweep flung the door open and showed the crew for the door's shots")
	_check(door.openness == 0.0 and door.bolt == 1.0 and not (crew[0].player as Player).visible, "...and gave the door and the hidden body back as they were")
	(crew[0].player as Player).visible = hidden
	_check(director.cutscenes.current is IntroVan, "the van is the first part shown (%s)" % director.cutscenes.current)
	_check(CutscenePlayer.bar_warmed, "the bar is marked warm")
	_check(mirror.renders == (1 if Mirror.has_window_pass() else 0), "the mirror's window pass drew once under the black (%d, tier %d)" % [mirror.renders, tier])
	_check(tv.renders == ([0, 1] if tier >= 2 else [1, 1]), "each TV feed of the tier drew once under the black (%s, tier %d)" % [tv.renders, tier])
	director.cutscenes.abort()
	await process_frame
	await process_frame
	_finish()


func _finish() -> void:
	Cutscene.time_scale = 1.0
	CutsceneDirector.skip_cutscenes = true
	if fails == 0:
		print("RENDER TARGET WARM OK")
	else:
		printerr("RENDER TARGET WARM FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)
