extends SceneTree

## Not a probe (needs a GPU window): frame cost of the chaos FX over a lit table. 10 s of rest, then 10 s of a worst-case
## storm (a 4-hit burst every frame, a pot every 0.4 s, a trick every 2.5 s) at each quality tier. Prints the mean GPU frame
## time, the CPU process time, draw calls and primitives; the delta against rest is the number for 07 §2.
##   godot --path . -s tests/fx/fx_cost.gd

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const SECONDS := 10.0

var table: Table
var director: RoundDirector
var fx: ImpactFx
var _vp: RID


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	table = TABLE.instantiate()
	root.add_child(table)
	director = RoundDirector.new()
	director.table = table
	root.add_child(director)
	fx = ImpactFx.new()
	fx.table = table
	fx.round_director = director
	root.add_child(fx)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(-1.2, 2.2, table.spec.width_m * 0.5 + table.spec.rail_width_m + 2.3)
	cam.look_at(Vector3(0, table.spec.bed_height_m * 0.7, 0), Vector3.UP)
	cam.current = true
	root.get_viewport().set_size(Vector2i(1280, 720))
	_vp = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await physics_frame
	director.start_round(NightConfig.new(), 1, 7)
	for i in 90:
		await physics_frame
	table.sim.shot_started_net.emit(1, 1, 0)
	var rest := await _measure("rest", false)
	print("%-10s gpu %.3f ms | frame %.3f ms | draws %d | primitives %d" % ["rest", rest.gpu, rest.frame, rest.draws, rest.particles])
	for tier in 3:
		QualityManager.current_tier = tier
		var s := await _measure("tier %d" % tier, true)
		print("%-10s gpu %.3f ms (+%.3f) | frame %.3f ms (+%.3f) | draws %d (+%d) | peak primitives %d" % [
			"storm t%d" % tier, s.gpu, s.gpu - rest.gpu, s.frame, s.frame - rest.frame, s.draws, s.draws - rest.draws, s.particles])
	QualityManager.current_tier = 0
	quit()


func _measure(_tag: String, storm: bool) -> Dictionary:
	var gpu := 0.0
	var frame := 0.0
	var draws := 0
	var peak := 0
	var n := 0
	var t0 := Time.get_ticks_usec()
	var last_pot := 0.0
	var last_trick := 0.0
	var pots: Array[Ball] = []
	for b in director.get_balls():
		if director.value_of(b.ball_type) > 0:
			pots.append(b)
	while (Time.get_ticks_usec() - t0) * 1e-6 < SECONDS:
		await process_frame
		var el := (Time.get_ticks_usec() - t0) * 1e-6
		if storm:
			var y := table.spec.bed_height_m + table.spec.ball_radius_m
			for k in 4:
				fx._hit(k % 3, table.global_position + Vector3(float(k) * 0.3 - 0.5, y, 0.0), Vector3.UP, 6.0 + k)
			if el - last_pot > 0.4:
				last_pot = el
				table.sim.ball_flag_applied.emit(pots[n % pots.size()], BallEventCodec.Flag.POCKETED)
			if el - last_trick > 2.5:
				last_trick = el
				director.trick_detected.emit(TrickShot.make(&"RailRunner", "c%d" % n), "c%d" % n)
		if el > 1.0:  # skip warm-up (shader compile, first allocations)
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
			frame += 1000.0 * Performance.get_monitor(Performance.TIME_PROCESS)
			draws += int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			peak = maxi(peak, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
			n += 1
	return {gpu = gpu / maxf(n, 1), frame = frame / maxf(n, 1), draws = draws / maxi(n, 1), particles = peak}
