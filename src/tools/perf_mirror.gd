extends SceneTree
## Draw-call / GPU cost of the wall mirror (06 P26, 07 §2 gate: draw calls p95 <= 120). Boots the real MainLevel solo
## with five humanoids (the local player, the Bartender, three more), a live Round, then samples `FRAMES` frames in each
## view and prints one row per view. Needs a window (headless has no renderer).
##   godot --path . -s src/tools/perf_mirror.gd [-- --scale=0.85]
## Rows: draw calls and primitives from RenderingServer's frame counters (the mirror's SubViewport counts), GPU ms from
## the measured render times of the main viewport and the mirror's.

const FRAMES := 300
const VIEWS := {
	"mirror_off_screen": [Vector3(-3.4, 0.0, -3.8), 270.0, -5.0],   # looking east, away from the glass
	"mirror_far_3.4m": [Vector3(-3.4, 0.0, -3.8), 90.0, -5.0],      # the shooting spot beside the table, facing the glass
	"mirror_near_1.8m": [Vector3(-5.1, 0.0, -3.8), 90.0, -5.0],
	"mirror_oblique": [Vector3(-3.4, 0.0, -1.6), 115.0, -5.0],
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scale := 0.85
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scale="):
			scale = float(a.substr(8))
	change_scene_to_file("res://src/levels/Lobby.tscn")
	for i in 3:
		await process_frame
	current_scene.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	var level := current_scene
	root.scaling_3d_scale = scale
	root.msaa_3d = Viewport.MSAA_2X
	var player: Player = level.get_node("PlayerSpawner").get_local_player()
	level.get_node("GameLoop").advance()
	for i in 60:
		await process_frame
	for spot in [Vector3(-2.0, 0, 1.0), Vector3(2.5, 0, 0.5), Vector3(-5.0, 0, -5.5)]:
		var h := Humanoid.new()
		level.add_child(h)
		h.global_position = spot
	var mirror: Mirror = level.get_node("Mirror")
	var main_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(main_rid, true)
	RenderingServer.viewport_set_measure_render_time(mirror.get_node("View").get_viewport_rid(), true)
	print("PERF_MIRROR scale=%.2f avatars=5 balls=%d" % [scale, level.get_node("RoundDirector").get_balls().size()])
	for name: String in VIEWS:
		var v: Array = VIEWS[name]
		player.global_position = v[0]
		player.rotation.y = deg_to_rad(v[1])
		player.head.rotation.x = deg_to_rad(v[2])
		for i in 30:
			await process_frame
		var dc: Array[float] = []
		var prim: Array[float] = []
		var gpu: Array[float] = []
		var gpu_mirror: Array[float] = []
		var renders := mirror.renders
		for i in FRAMES:
			await process_frame
			dc.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			prim.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(main_rid))
			gpu_mirror.append(RenderingServer.viewport_get_measured_render_time_gpu(mirror.get_node("View").get_viewport_rid()))
		print("PERF_MIRROR %-18s dc mean %5.1f p95 %5.1f max %5.1f | tris max %7.0f | gpu main %.2f ms mirror %.2f ms (mean) | mirror renders %d/%d frames" % [
			name, _mean(dc), _p(dc, 0.95), _p(dc, 1.0), _p(prim, 1.0), _mean(gpu), _mean(gpu_mirror), mirror.renders - renders, FRAMES])
	quit()


## The one place a probe waits for the level to be playable after pressing Solo (alpha swaps the body for
## `await SoloSupport.until_playable(self)` once the threaded loading screen lands).
func _until_playable() -> void:
	for i in 40:
		await process_frame


func _mean(a: Array[float]) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / maxf(a.size(), 1.0)


func _p(a: Array[float], q: float) -> float:
	var b := a.duplicate()
	b.sort()
	return b[mini(int(q * (b.size() - 1) + 0.5), b.size() - 1)]
