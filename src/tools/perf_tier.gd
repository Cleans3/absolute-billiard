extends SceneTree

## One-shot (adhoc-1014a V11): frame cost of the real MainLevel (Solo, a live Round, 5 humanoids) at one quality tier, per view,
## uncapped (no vsync, no fps cap), so the numbers are what a frame COSTS, not what a 60 Hz display hides. Needs a window.
##   DISPLAY=:0 godot --path . [--gpu-index N] [--rendering-method M] -s src/tools/perf_tier.gd -- tier=0|1|2 [label=<s>] [flags=<AB_GLARE>] [frames=240]
## Views: table (idle, mirror and TV off screen) · room (mirror and TV both on screen) · break (table view, a full-power break
## from the strike on). Rows: frame ms (mean / p95 / max), GPU ms and CPU render ms of the main viewport plus the mirror's and
## TV's SubViewports, draw calls, primitives. The desktop is not the phone (07): read the ratios between tiers, and before/after.

const VIEWS := {
	"table": [Vector3(0.0, 1.75, -0.4), Vector3(0.0, 0.8, -4.2)],
	"room": [Vector3(3.5, 1.6, 0.0), Vector3(-5.2, 1.7, 4.8)],
}
const BREAK_FRAMES := 360


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
	var frames := int(o.get("frames", "240"))
	Settings.path = "user://perf_tier_settings.cfg"
	Settings.set_value(&"quality", Settings.QUALITY[1 + tier])
	SaveManager.root = "user://perf_tier"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	GlareFlags.persist = false
	DeviceClass.enabled = false
	GlareFlags.set_all(GlareFlags.parse(String(o.get("flags", "none")).replace("+", ",")))
	root.size = Vector2i(1280, 720)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	if is_instance_valid(lobby):
		lobby.queue_free()
	level.get_node("QualityManager").process_mode = Node.PROCESS_MODE_DISABLED  # it re-caps the fps and idles the frame rate
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	level.get_node("GameLoop").advance()
	for i in 60:
		await process_frame
	for spot in [Vector3(-2.0, 0, 1.0), Vector3(2.5, 0, 0.5), Vector3(-5.0, 0, -5.5)]:
		var h := Humanoid.new()
		level.add_child(h)
		h.global_position = spot
	var cam := Camera3D.new()
	cam.fov = 70.0
	level.add_child(cam)
	var rids: Array[RID] = [root.get_viewport_rid()]
	var mirror := level.get_node("Mirror")
	rids.append(mirror.get_node("View").get_viewport_rid())
	for n: Node in level.get_node("Tv").find_children("*", "SubViewport", true, false):
		rids.append(n.get_viewport_rid())
	for r in rids:
		RenderingServer.viewport_set_measure_render_time(r, true)
	var table: Table = level.get_node("Table")
	var balls: Array[Ball] = level.get_node("RoundDirector").get_balls()
	print("PERF_TIER label=%s tier=%d renderer=%s adapter=%s scale=%.2f msaa=%d aa=%d flags=%s balls=%d" % [o.get("label", ""), tier, RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name(), root.scaling_3d_scale, root.msaa_3d, root.screen_space_aa, GlareFlags.describe(), balls.size()])
	for name: String in VIEWS:
		_aim(cam, VIEWS[name])
		for i in 60:
			cam.current = true
			await process_frame
		await _sample(name, frames, rids, cam)
	_aim(cam, VIEWS.table)
	for i in 30:
		cam.current = true
		await process_frame
	var cue: Ball = null
	var target := Vector3.ZERO
	for b in balls:
		if b.is_cue_ball:
			cue = b
	for b in balls:
		if not b.is_cue_ball and (target == Vector3.ZERO or b.global_position.distance_to(cue.global_position) < target.distance_to(cue.global_position)):
			target = b.global_position
	var intent := ShotIntent.new()
	var d := (target - cue.global_position)
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 1.0
	intent.shooter_id = get_multiplayer().get_unique_id()
	table.sim.request_shot(intent)
	await _sample("break", BREAK_FRAMES, rids, cam)
	quit()


func _aim(cam: Camera3D, v: Array) -> void:
	cam.global_position = v[0]
	cam.look_at(v[1])


func _sample(name: String, frames: int, rids: Array[RID], cam: Camera3D) -> void:
	var ms: Array[float] = []
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var dc: Array[float] = []
	var prim: Array[float] = []
	var prev := Time.get_ticks_usec()
	for i in frames:
		cam.current = true
		await process_frame
		var now := Time.get_ticks_usec()
		ms.append((now - prev) * 1e-3)
		prev = now
		var g := 0.0
		var c := 0.0
		for r in rids:
			g += RenderingServer.viewport_get_measured_render_time_gpu(r)
			c += RenderingServer.viewport_get_measured_render_time_cpu(r)
		gpu.append(g)
		cpu.append(c)
		dc.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		prim.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	print("PERF_TIER %-6s frame ms mean %6.2f p95 %6.2f max %6.2f | fps %5.0f | gpu %5.2f cpu-render %5.2f | draw calls %5.0f | tris %7.0f" % [
		name, _mean(ms), _p(ms, 0.95), _p(ms, 1.0), 1000.0 / maxf(_mean(ms), 0.001), _mean(gpu), _mean(cpu), _mean(dc), _mean(prim)])


func _mean(a: Array[float]) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / maxf(a.size(), 1.0)


func _p(a: Array[float], q: float) -> float:
	var b := a.duplicate()
	b.sort()
	return b[mini(int(q * (b.size() - 1) + 0.5), b.size() - 1)]
