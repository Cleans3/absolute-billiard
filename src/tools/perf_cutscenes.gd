extends SceneTree

## One-shot (adhoc-1014b C11): frame cost of every cutscene part as the game plays it — the real MainLevel (Solo) loaded and running behind
## it, the intro from the fresh run's own cue, then the failure and the win from `CutsceneDirector._begin_ending`. Uncapped (no vsync, no fps
## cap), a 20:9 window like a phone's (the stage camera's horizontal FOV reaches the bar on tall screens), at one quality tier. Needs a window:
##   DISPLAY=:0 godot --path . -s src/tools/perf_cutscenes.gd -- tier=0|1|2 [label=<s>] [only=intro,fail,win] [truck_frames=240] [size=1600x720]
##     [shots=<dir>]   (size=3840x1728 makes the GPU the bottleneck on a desktop card; shots keeps one PNG per part)
## One row per part: frame ms (mean / p95 / max), the worst frame at its cut (its first 3 frames), GPU ms summed over the main viewport and
## every SubViewport (mirror, TV feeds), draw calls, primitives, and the pipelines compiled while it was on screen (draw + surface + mesh
## + specialization monitors), the mean luma of its frame LUMA_AT_FRAME (a light lost to a layer mask reads as a darker scene), its total time. The desktop is not the phone (07): compare tiers and before/after, not absolute numbers.

const SEQUENCE_TIMEOUT_SEC := 40.0

const LUMA_AT_FRAME := 120  ## a shown part's frame whose picture is kept (past every fade-in)

var level: Node
var shots := ""  ## directory for one PNG per part, "" = none
var tag := ""
var director: CutsceneDirector
var rows: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _opts() -> Dictionary:
	var o := {}
	for a in OS.get_cmdline_user_args():
		var kv := String(a).split("=", true, 1)
		if kv.size() == 2:
			o[kv[0]] = kv[1]
	return o


func _run() -> void:
	var o := _opts()
	var tier := int(o.get("tier", "0"))
	var only := String(o.get("only", "intro,fail,win")).split(",")
	Settings.path = "user://perf_cutscenes_settings.cfg"
	Settings.set_value(&"quality", Settings.QUALITY[1 + tier])
	SaveManager.root = "user://perf_cutscenes"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	GlareFlags.persist = false
	DeviceClass.enabled = false
	var size := String(o.get("size", "1600x720")).split("x")
	root.size = Vector2i(int(size[0]), int(size[1]))
	shots = String(o.get("shots", ""))
	if shots != "":
		shots = shots.trim_suffix("/") + "/"
		DirAccess.make_dir_recursive_absolute(shots)
	tag = "%s_t%d" % [o.get("label", ""), tier]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("PERF_CUTSCENES label=%s tier=%d renderer=%s adapter=%s size=%s" % [o.get("label", ""), tier, RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name(), root.size])
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	# The intro is cued by the fresh run as soon as MainLevel is up: sample from the first frame it plays, whatever SoloSupport is doing.
	CutsceneDirector.skip_cutscenes = false
	var waited := 0
	while director == null and waited < 3000:
		var scene := current_scene
		if scene != null and scene.name == "MainLevel":
			level = scene
			director = level.get_node_or_null("CutsceneDirector") as CutsceneDirector
			if is_instance_valid(lobby):
				lobby.queue_free()  # the game changes scene; a lobby left over would draw its UI over every cutscene frame
		Engine.max_fps = 0
		await process_frame
		waited += 1
	if director == null:
		push_error("perf_cutscenes: no CutsceneDirector")
		quit(1)
		return
	if "intro" in only:
		await _measure(&"intro", int(o.get("truck_frames", "240")))
	await SoloSupport.until_playable(self, 60.0, false, false, false, true)
	if is_instance_valid(lobby):
		lobby.queue_free()
	for i in 30:
		Engine.max_fps = 0
		await process_frame
	if "fail" in only:
		director._ending = &""
		director._begin_ending(&"fail")
		await _measure(&"fail", 0)
		director._close_card()
		director._over = true
		for i in 30:
			await process_frame
	if "win" in only:
		director._ending = &""
		director._begin_ending(&"win")
		await _measure(&"win", int(o.get("truck_frames", "240")))
	for r in rows:
		print(r)
	print("PERF_CUTSCENES DONE %d parts" % rows.size())
	quit()


## The root viewport plus every SubViewport of the level (mirror, TV feeds); nodes, so one freed mid-run is skipped.
func _rids() -> Array[Viewport]:
	var out: Array[Viewport] = [root]
	for n: Node in level.find_children("*", "SubViewport", true, false):
		out.append(n as SubViewport)
	for v in out:
		RenderingServer.viewport_set_measure_render_time(v.get_viewport_rid(), true)
	return out


## [draw, surface, mesh, specialization]: draw-time ones stall the frame; surface ones the frame that adds the instance; specialization ones
## build in the background while the ubershader draws (Godot 4.4+), so they cost a worker thread, not the frame.
func _pipelines() -> PackedFloat32Array:
	return PackedFloat32Array([Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW), Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE), Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH), Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION)])


func _since(p0: PackedFloat32Array) -> PackedFloat32Array:
	var p := _pipelines()
	for i in p.size():
		p[i] -= p0[i]
	return p


## Mean luminance of the frame on screen (0..1) and a PNG of it under `shots` (when set): one readback, so the frame after it is not sampled.
func _luma(png: String) -> float:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if shots != "":
		img.save_png(shots + png + ".png")
	img.resize(32, 16, Image.INTERPOLATE_BILINEAR)
	var sum := 0.0
	for y in img.get_height():
		for x in img.get_width():
			sum += img.get_pixel(x, y).get_luminance()
	return sum / float(img.get_width() * img.get_height())


## Samples every frame while `id` plays, one row per part. An open-ended last part (the truck) is ended after `open_frames` of it.
func _measure(id: StringName, open_frames: int) -> void:
	var cs := director.cutscenes
	var t0 := Time.get_ticks_msec()
	while not cs.is_playing() and Time.get_ticks_msec() - t0 < 5000:
		Engine.max_fps = 0
		await process_frame
	if not cs.is_playing():
		rows.append("PERF_CUTSCENES %-12s did not start" % id)
		return
	var rids := _rids()
	var part := &""
	var acc := {}
	var prev := Time.get_ticks_usec()
	var pipe0 := _pipelines()
	while cs.is_playing() and Time.get_ticks_msec() - t0 < SEQUENCE_TIMEOUT_SEC * 1000.0:
		Engine.max_fps = 0
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - prev) * 1e-3
		prev = now
		# A part counts only while it is on screen (playing); its prepare under black, and the gaps between parts, are "(black)".
		var cur: StringName = cs.current.id() if cs.current != null and cs.current.playing else &"(black)"
		if cur != part:
			if not acc.is_empty():
				_row(id, part, acc, _since(pipe0))
			part = cur
			acc = {"ms": [], "gpu": [], "dc": [], "prim": [], "luma": -1.0}
			pipe0 = _pipelines()
			rids = _rids()
		var g := 0.0
		for v in rids:
			if is_instance_valid(v) and v.is_inside_tree():
				g += RenderingServer.viewport_get_measured_render_time_gpu(v.get_viewport_rid())
		(acc.ms as Array).append(ms)
		(acc.gpu as Array).append(g)
		(acc.dc as Array).append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)))
		(acc.prim as Array).append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)))
		if cur != &"(black)" and (acc.ms as Array).size() == LUMA_AT_FRAME:
			acc.luma = await _luma("%s_%s_%s" % [tag, id, cur])
			prev = Time.get_ticks_usec()
		if open_frames > 0 and cs.current != null and cs.current.length_sec() <= 0.0 and (acc.ms as Array).size() >= open_frames:
			cs.current.finish()
	if not acc.is_empty():
		_row(id, part, acc, _since(pipe0))


func _row(seq: StringName, part: StringName, acc: Dictionary, pipes: PackedFloat32Array) -> void:
	var ms: Array = acc.ms
	var cut := 0.0
	for i in mini(3, ms.size()):
		cut = maxf(cut, ms[i])
	rows.append("PERF_CUTSCENES %-6s %-12s frames %4d | ms mean %6.2f p95 %6.2f max %7.2f cut %7.2f | gpu %5.2f | draws %5.0f | tris %7.0f | pipelines d/s/m/spec %2.0f/%2.0f/%2.0f/%2.0f | luma %5.3f | total %6.0f ms" % [
		seq, part, ms.size(), _mean(ms), _p(ms, 0.95), _p(ms, 1.0), cut, _mean(acc.gpu), _mean(acc.dc), _mean(acc.prim), pipes[0], pipes[1], pipes[2], pipes[3], float(acc.luma), _mean(ms) * ms.size()])


func _mean(a: Array) -> float:
	var s := 0.0
	for x: float in a:
		s += x
	return s / maxf(a.size(), 1.0)


func _p(a: Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[mini(int(q * (b.size() - 1) + 0.5), b.size() - 1)]
