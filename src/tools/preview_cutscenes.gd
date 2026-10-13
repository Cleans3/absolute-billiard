extends SceneTree
## One-shot (adhoc-1013c F3a): plays every standalone cutscene in a window on a manual clock and saves PNGs, plus the render cost of each
## frame (draw calls, triangles, texture memory) for 07. Needs a display, run through `heavy`:
##   heavy godot --path . --resolution 1280x720 -s src/tools/preview_cutscenes.gd
## Output: ~/work/.herdr/adhoc-1013c/shots/f3a/*.png, and a `shot <name> draws=.. tris=.. tex_mb=..` line per image on stdout.
## Ends with `PREVIEW DONE <n> shots`. The cutscenes are the real scenes (res://src/cutscene/*.tscn); only the clock is ours.

const OUT := "/home/cleanse/work/.herdr/adhoc-1013c/shots/f3a/"
const VAN := "res://src/cutscene/IntroVan.tscn"
const CABIN := "res://src/cutscene/IntroCabin.tscn"
const TRUCK := "res://src/cutscene/TruckOutro.tscn"
const FALL := "res://src/cutscene/FallCam.tscn"
const STATS := {
	"nights_cleared": 3, "pots": 58, "best_combo": 6, "trick_shots": 9, "best_shot": 1240, "cash_earned": 8420,
	"scratches": 2, "fines_paid": 70, "play_time": 3725.0,
}

var shots := 0


func _init() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Waits for the pose to settle (Humanoids smooth over frames), then saves the window.
func _shot(shot_name: String) -> void:
	await _frames(10)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var err := img.save_png(OUT + shot_name + ".png")
	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var tris := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var tex := float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)) / 1048576.0
	print("shot %s %s draws=%d tris=%d tex_mb=%.1f" % [shot_name, error_string(err), draws, tris, tex])
	shots += 1


func _scene(path: String, opts: Dictionary) -> Cutscene:
	var cs := (load(path) as PackedScene).instantiate() as Cutscene
	var o := {"manual": true}
	o.merge(opts, true)
	cs.configure(o)
	root.add_child(cs)
	if cs.on_stage:
		cs.global_position = Cutscene.STAGE_ORIGIN
	cs.play()
	return cs


func _at(cs: Cutscene, time: float) -> void:
	cs.step(maxf(time - cs.t, 0.0))


func _drop(cs: Cutscene) -> void:
	cs.abort()
	cs.free()
	await _frames(2)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	SaveManager.root = "user://preview_cutscenes"
	root.msaa_3d = Viewport.MSAA_2X
	await _frames(3)
	await _van()
	await _cabin()
	await _truck()
	await _fall()
	await _mouth()
	print("PREVIEW DONE %d shots" % shots)
	quit(0)


func _van() -> void:
	var cs := _scene(VAN, {"seed": 11, "crew_size": 4})
	for time in [0.5, 1.0, 1.6, 1.95]:
		_at(cs, time)
		await _shot("van_n4_t%.2f" % time)
	await _drop(cs)
	for spec in [[1, 5], [2, 8], [3, 13], [4, 27]]:  # the roster sizes, each with a seed of its own
		var c := _scene(VAN, {"seed": spec[1], "crew_size": spec[0]})
		_at(c, 1.0)
		await _shot("van_n%d_seed%d" % [spec[0], spec[1]])
		await _drop(c)


func _cabin() -> void:
	var cs := _scene(CABIN, {"seed": 11})
	for time in [0.3, 0.8, 1.3, 1.8, 2.3, 2.6, 2.9]:
		_at(cs, time)
		await _shot("cabin_t%.2f" % time)
	await _drop(cs)


func _truck() -> void:
	var lines: Array[String] = ["The Buyout clears live, in front of more viewers than this room has ever had.", "You wake on a flatbed, on a road, with the sun coming up."]
	var cs := _scene(TRUCK, {"seed": 11, "crew_size": 4, "stats": STATS, "captions": lines})
	for time in [1.6, 6.0, 6.1]:  # two frames 0.1 s apart show the world sliding and the truck shaking
		_at(cs, time)
		await _shot("truck_captions_t%.1f" % time)
	await _drop(cs)
	var plain := _scene(TRUCK, {"seed": 4, "crew_size": 3, "stats": STATS})
	for time in [1.0, 4.0, 9.0, 12.0, 16.5]:
		_at(plain, time)
		await _shot("truck_card_t%.1f" % time)
	await _drop(plain)


func _fall() -> void:
	var cs := _scene(FALL, {"seed": 11, "crew_size": 4, "caption": "Four hundred. You missed by a little. The floor doesn't care how little."})
	for time in [0.2, 0.9, 1.5, 1.9, 2.3, 2.7, 3.4]:
		_at(cs, time)
		await _shot("fall_t%.1f" % time)
	await _drop(cs)


## The maw on its own, three ways, lit by nothing but its own glow.
func _mouth() -> void:
	var origin := Cutscene.STAGE_ORIGIN
	var mouth := MonsterMouth.new()
	mouth.auto = false  # our clock, so the pictures repeat
	root.add_child(mouth)
	mouth.global_position = origin
	var cam := Camera3D.new()
	cam.environment = CutsceneKit.night_env(Color.BLACK, Color(0.12, 0.07, 0.08), 1.0, Color(0.05, 0.02, 0.03), 0.02)
	cam.fov = 60.0
	root.add_child(cam)
	cam.make_current()
	var views := {
		"mouth_top": [Vector3(0.0, 6.5, 0.4), Vector3(0.0, -1.0, 0.0)],
		"mouth_angle": [Vector3(3.4, 3.2, 3.4), Vector3(0.0, -1.2, 0.0)],
		"mouth_throat": [Vector3(0.0, -2.0, 0.3), Vector3(0.0, -6.0, 0.0)],
	}
	for view_name: String in views:
		var v: Array = views[view_name]
		cam.global_transform = CutsceneKit.look_from(origin + (v[0] as Vector3), origin + (v[1] as Vector3))
		mouth.pose(0.9)
		await _shot(view_name)
	mouth.close_amount = 1.0
	cam.global_transform = CutsceneKit.look_from(origin + Vector3(0.0, 6.5, 0.4), origin + Vector3(0.0, -1.0, 0.0))
	await _shot("mouth_top_closed")
	cam.free()
	mouth.free()
