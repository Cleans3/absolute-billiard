extends SceneTree
## Draw-call / GPU / texture cost of the wall TV's two feeds (07 §2 "TV feeds", adhoc-1013c W4). Boots the real MainLevel solo with a
## live Round, then for each quality tier samples `FRAMES` frames with the player looking away from the TV (the feeds must cost nothing),
## looking at it with the feeds switched off (the baseline: the glass is black) and looking at it live; one row per tier and view. Needs a window.
##   godot --path . -s src/tools/perf_tv.gd [-- --scale=0.85]
## Rows: draw calls and primitives from RenderingServer's frame counters (the feeds' SubViewports count), GPU ms of the main viewport and
## of each feed (measured render times), texture memory, and how many passes the feeds drew.

const FRAMES := 300
const VIEWS := {
	"away": [Vector3(0.0, 0.0, 1.5), 0.0, 0.0],        # facing north, the TV behind the player
	"toward_off": [Vector3(0.0, 0.0, 1.5), 180.0, 0.0],  # facing the TV, feeds switched off
	"toward_live": [Vector3(0.0, 0.0, 1.5), 180.0, 0.0],
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
	await SoloSupport.until_playable(self)
	var level := current_scene
	root.scaling_3d_scale = scale
	root.msaa_3d = Viewport.MSAA_2X
	var player: Player = level.get_node("PlayerSpawner").get_local_player()
	var tv := level.get_node("Tv") as StreamTv
	level.get_node("GameLoop").advance()
	for i in 60:
		await process_frame
	var main_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(main_rid, true)
	for vp: SubViewport in tv._vp:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	print("PERF_TV scale=%.2f balls=%d" % [scale, level.get_node("RoundDirector").get_balls().size()])
	for tier in 3:
		QualityManager.current_tier = tier
		for name: String in VIEWS:
			var v: Array = VIEWS[name]
			tv.set_feeds_on(name != "toward_off")
			player.global_position = v[0]
			player.rotation.y = deg_to_rad(v[1])
			player.head.rotation.x = deg_to_rad(v[2])
			for i in 40:
				await process_frame
			var dc: Array[float] = []
			var prim: Array[float] = []
			var gpu: Array[float] = []
			var gpu_a: Array[float] = []
			var gpu_b: Array[float] = []
			var tex: Array[float] = []
			var passes := tv.renders.duplicate()
			for i in FRAMES:
				await process_frame
				dc.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
				prim.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
				tex.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0)
				gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(main_rid))
				gpu_a.append(RenderingServer.viewport_get_measured_render_time_gpu(tv._vp[0].get_viewport_rid()))
				gpu_b.append(RenderingServer.viewport_get_measured_render_time_gpu(tv._vp[1].get_viewport_rid()))
			print("PERF_TV tier %d %-11s dc mean %5.1f p95 %5.1f max %5.1f | tris max %7.0f | tex %5.1f MB | gpu main %.2f ms tripod %.2f ceiling %.2f | passes %d tripod %d ceiling in %d frames" % [
				tier, name, _mean(dc), _p(dc, 0.95), _p(dc, 1.0), _p(prim, 1.0), _p(tex, 1.0), _mean(gpu), _mean(gpu_a), _mean(gpu_b),
				tv.renders[0] - passes[0], tv.renders[1] - passes[1], FRAMES])
	quit()


func _mean(a: Array[float]) -> float:
	var s := 0.0
	for x in a:
		s += x
	return s / maxf(a.size(), 1.0)


func _p(a: Array[float], q: float) -> float:
	var b := a.duplicate()
	b.sort()
	return b[mini(int(q * (b.size() - 1) + 0.5), b.size() - 1)]
