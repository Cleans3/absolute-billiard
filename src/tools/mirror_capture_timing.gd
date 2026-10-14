extends SceneTree

## One-shot (adhoc-1014b S5): where the wall mirror's room capture (six get_image readbacks) lands, on a real renderer. Needs a window.
##   DISPLAY=:0 godot --path . --resolution 1280x720 -s src/tools/mirror_capture_timing.gd -- [tier=0|1|2] [intro=1]
## Default: Solo with the cutscenes skipped, then (A) a capture asked for while a cutscene holds draws no face until it ends, and (B) one
## already running when a cutscene takes the screen stops at the next face and finishes after it. The hold is emulated with the group call
## Cutscene makes (QualityManager.HOLD_GROUP).
## intro=1: the real intro runs; the frames of "the level is up", "the mirror captured", "the loading screen ended" and "a cutscene camera
## is current" are printed in order (the capture must be done before the first cutscene frame that is shown, and under the loading screen).

var _frames_up := -1
var _captured_at := -1
var _loading_done_at := -1
var _cutscene_at := -1
var _mirror: Mirror
var _cut_cam: Camera3D
var _prev_cam: Camera3D


func _init() -> void:
	call_deferred("_run")


func _opts() -> Dictionary:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := String(a).split("=", true, 1)
		if kv.size() == 2:
			o[kv[0]] = kv[1]
	return o


## What Cutscene does: its own camera current while the hold stands (QualityManager drops a hold that has none).
func _hold(on: bool) -> void:
	if on:
		_prev_cam = root.get_camera_3d()
		_cut_cam = Camera3D.new()
		_cut_cam.name = QualityManager.CUTSCENE_CAMERA
		current_scene.add_child(_cut_cam)
		_cut_cam.make_current()
	call_group(QualityManager.HOLD_GROUP, &"cutscene_hold", on, true)
	if not on and _cut_cam != null:
		_prev_cam.make_current()
		_cut_cam.free()
		_cut_cam = null


func _run() -> void:
	var o := _opts()
	var tier := int(o.get("tier", "0"))
	var intro: bool = o.get("intro", "0") == "1"
	Settings.path = "user://mirror_timing_settings.cfg"
	Settings.set_value(&"quality", Settings.QUALITY[1 + tier])
	SaveManager.root = "user://mirror_timing"
	DirAccess.make_dir_recursive_absolute(SaveManager.root.path_join("checkpoints"))
	GlareFlags.persist = false
	DeviceClass.enabled = false
	root.size = Vector2i(1280, 720)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	CutsceneDirector.skip_cutscenes = not intro
	RoundDirector.skip_staging = true
	StoryDirector.auto_intro_cards = false
	Coach.enabled = false
	var t0 := Time.get_ticks_usec()
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	var limit := 1200 if intro else 600
	for i in limit:
		await process_frame
		var f := Engine.get_frames_drawn()
		if _mirror == null:
			_mirror = get_first_node_in_group(&"mirror") as Mirror
			if _mirror != null:
				_frames_up = f
				t0 = Time.get_ticks_usec()
				_mirror.captured.connect(func() -> void:
					if _captured_at < 0:
						_captured_at = Engine.get_frames_drawn()
						print("MIRROR first capture done at frame %d, %d frames and %.0f ms after the level came up (tier %d)" % [_captured_at, _captured_at - _frames_up, (Time.get_ticks_usec() - t0) * 1e-3, tier]))
		if _mirror != null and _loading_done_at < 0 and root.get_node_or_null("LoadingScreen") == null:
			_loading_done_at = f
		var cam := root.get_camera_3d()
		if _cutscene_at < 0 and cam != null and cam.name == QualityManager.CUTSCENE_CAMERA:
			_cutscene_at = f
		if not intro and _loading_done_at >= 0 and _captured_at >= 0:
			break
		if intro and _cutscene_at >= 0 and i > 60:
			break
	print("MIRROR frames: level up %d, captured %d, loading screen ended %d, first cutscene camera %d" % [_frames_up, _captured_at, _loading_done_at, _cutscene_at])
	var ok := _captured_at >= 0 and _captured_at <= _loading_done_at
	print("MIRROR the capture %s the loading screen" % ("finished under" if ok else "did NOT finish under"))
	if intro:
		var shown := maxi(_cutscene_at, _loading_done_at)  # the intro's camera is current under the loading screen from the first frame; it shows when that ends
		var before := _captured_at >= 0 and _captured_at < shown
		print("MIRROR the capture (frame %d) is %s the first SHOWN cutscene frame (%d: camera at %d, loading screen ended %d)" % [_captured_at, "before" if before else "NOT before", shown, _cutscene_at, _loading_done_at])
		quit(0 if ok and before else 1)
		return
	for i in 30:
		await process_frame

	# A: asked for while held
	var faces := _mirror.faces_drawn
	var caps := _mirror.captures
	_hold(true)
	_mirror.capture()
	for i in 40:
		await process_frame
	print("MIRROR A held 40 frames: faces drawn %d (before %d), captures %d (before %d)" % [_mirror.faces_drawn, faces, _mirror.captures, caps])
	var ok_a := _mirror.faces_drawn == faces and _mirror.captures == caps
	var f0 := Engine.get_frames_drawn()
	t0 = Time.get_ticks_usec()
	_hold(false)
	while _mirror.captures == caps:
		await process_frame
	print("MIRROR A released: done %d frames, %.0f ms later, faces +%d" % [Engine.get_frames_drawn() - f0, (Time.get_ticks_usec() - t0) * 1e-3, _mirror.faces_drawn - faces])
	ok_a = ok_a and _mirror.faces_drawn == faces + 6

	# B: a capture already running when the hold comes
	faces = _mirror.faces_drawn
	caps = _mirror.captures
	_mirror.capture()
	while _mirror.faces_drawn < faces + 2:
		await process_frame
	_hold(true)
	for i in 3:
		await process_frame  # the face being drawn when the hold came still finishes
	var at_hold := _mirror.faces_drawn
	for i in 40:
		await process_frame
	print("MIRROR B hold came after %d faces; 40 held frames later: %d faces, captures %d (before %d)" % [at_hold - faces, _mirror.faces_drawn, _mirror.captures, caps])
	var ok_b := _mirror.faces_drawn <= at_hold and _mirror.captures == caps
	_hold(false)
	while _mirror.captures == caps:
		await process_frame
	print("MIRROR B released: faces +%d in all" % (_mirror.faces_drawn - faces))
	ok_b = ok_b and _mirror.faces_drawn == faces + 6

	# C: the same hold under the loading screen (the intro's cue fires beneath it): the capture runs, nothing waits on anything
	var overlay: Node = load("res://src/ui/LoadingScreen.tscn").instantiate()
	root.add_child(overlay)
	faces = _mirror.faces_drawn
	caps = _mirror.captures
	_hold(true)
	_mirror.capture()
	while _mirror.captures == caps:
		await process_frame
	print("MIRROR C hold under the loading screen: the capture ran, faces +%d" % (_mirror.faces_drawn - faces))
	var ok_c := _mirror.faces_drawn == faces + 6
	_hold(false)
	overlay.queue_free()
	print("MIRROR %s" % ("TIMING OK" if ok and ok_a and ok_b and ok_c else "TIMING FAILED (loading %s, held %s, in flight %s, covered %s)" % [ok, ok_a, ok_b, ok_c]))
	quit(0 if ok and ok_a and ok_b and ok_c else 1)
