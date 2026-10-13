extends SceneTree
## One-shot (adhoc-1013c F3b): the real MainLevel (Solo, a window), the in-room cutscenes played on a manual clock and saved as PNGs, plus the render
## cost of each frame (draw calls, triangles, texture memory) for 07. Needs a display, run through `heavy`:
##   heavy godot --path . --resolution 1280x720 -s src/tools/preview_room_cutscenes.gd
## Output: ~/work/.herdr/adhoc-1013c/shots/f3b/*.png and a `shot <name> <err> draws=.. tris=.. tex_mb=..` line per image. Ends with `PREVIEW DONE <n> shots`.
## The cutscene clock is ours (CutsceneDirector.manual_clock); tweens (the door's, the Vent's and the Trapdoor's) and the gas run on real time, so a
## shot that needs one waits real frames with the cutscene clock held still.

const OUT := "/home/cleanse/work/.herdr/adhoc-1013c/shots/f3b/"

var shots := 0
var level: Node
var loop: GameLoop
var director: CutsceneDirector
var cs: CutscenePlayer
var player: Player
var home := Vector3.ZERO


func _init() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(shot_name: String, settle := 8) -> void:
	await _frames(settle)  # Humanoids smooth their pose over frames
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var err := img.save_png(OUT + shot_name + ".png")
	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var tris := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var tex := float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)) / 1048576.0
	print("shot %s %s draws=%d tris=%d tex_mb=%.1f" % [shot_name, error_string(err), draws, tris, tex])
	shots += 1


func _to(c: Cutscene, time: float) -> void:
	while c.playing and c.t < time - 0.0001:
		c.step(minf(0.05, time - c.t))


## Looks from `eye` at `target` instead of the beat's own camera until the next step.
func _look(c: Cutscene, eye: Vector3, target: Vector3, fov := 65.0) -> void:
	c.camera.global_transform = CutsceneKit.look_from(eye, target)
	c.camera.fov = fov


func _until_part(want: StringName) -> void:
	var guard := 0
	while cs.is_playing() and (cs.current == null or cs.current.id() != want) and guard < 200:
		if cs.current != null:
			cs.current.step(0.5)
		guard += 1


func _reset_world() -> void:
	director._close_card()
	(level.get_node("Trapdoor") as Trapdoor).set_openness(0.0)
	(level.get_node("Tv") as StreamTv).set_feeds_on(true)
	(level.get_node("Mirror") as Mirror).set_blood(0.0)
	(level.get_node("UILayer/CutScreen") as CutScreen).clear()
	player.global_position = home
	player.visible = true
	player.humanoid.transform = Transform3D.IDENTITY
	player.humanoid.clear_hand(0)
	player.humanoid.clear_hand(1)
	player.set_physics_process(true)
	player.humanoid.set_physics_process(true)
	if director._mouth != null:
		director._mouth.visible = false
	for sm in get_nodes_in_group(&"slot_machine"):
		(sm as SlotMachine).set_power(true)
	(level.get_node("Vent") as Vent).set_openness(0.0)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	SaveManager.root = "user://preview_room_cutscenes"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	root.msaa_3d = Viewport.MSAA_2X
	CutsceneDirector.skip_cutscenes = false
	CutsceneDirector.manual_clock = true
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby  # so the scene change to MainLevel frees it, as in the app
	await _frames(3)
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 90.0, true, true, false, true)
	level = current_scene
	loop = level.get_node("GameLoop")
	director = level.get_node("CutsceneDirector")
	cs = director.cutscenes
	director.leave_handler = func() -> void: pass  # Continue would leave the session: this tool keeps going
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	home = player.global_position
	await _frames(20)
	await _intro()
	await _failure()
	await _win()
	print("PREVIEW DONE %d shots" % shots)
	quit(0)


func _intro() -> void:
	_until_part(&"intro_room")
	var room := cs.current as IntroRoom
	_to(room, 0.6)
	_look(room, Vector3(-3.0, 1.7, -2.0), Vector3(0.0, 1.0, -6.0), 70.0)
	await _shot("intro_door_open_side")
	for time in [0.9, 1.5, 2.1, 3.0, 3.9, 4.6, 5.3, 6.0]:
		_to(room, time)
		await _shot("intro_t%.2f" % time)
	room.step(IntroRoom.LENGTH_SEC)
	await _frames(10)
	(level.get_node("UILayer/StoryCards") as StoryCards).close()
	await _shot("intro_end_player_eye")


func _failure() -> void:
	_reset_world()
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	await _frames(3)
	var room := cs.current as FailRoom
	for time in [0.5, 0.9, 1.6, 2.4]:
		_to(room, time)
		await _shot("fail_t%.2f" % time)
	_to(room, 3.4)
	_look(room, Vector3(-3.0, 1.6, -3.8), Vector3(-6.9, 1.4, -3.8), 70.0)  # the mirror on the west wall, bloody by now
	await _shot("fail_mirror_blood")
	_look(room, Vector3(3.5, 1.7, 3.0), Vector3(0.0, 3.1, 0.0), 70.0)  # the beacon
	await _shot("fail_beacon")
	_look(room, Vector3(0.0, 1.9, -1.0), Vector3(0.0, 1.9, 7.0), 70.0)  # the TV and the slot machine, dark
	await _shot("fail_screens_black")
	_to(room, 4.2)
	await _shot("fail_pull_t4.20")
	_to(room, FailRoom.LENGTH_SEC - 0.01)
	room.step(0.02)
	await _frames(70)  # the leaves swing on real time
	var fall := cs.current as FallCam
	_to(fall, 0.7)
	await _shot("fail_fall_t0.70")
	_to(fall, 1.4)
	await _shot("fail_fall_t1.40")
	_to(fall, 2.0)
	await _shot("fail_fall_t2.00")
	_to(fall, FallCam.LENGTH_SEC - 0.01)
	fall.step(0.02)
	await _shot("fail_stats_card_on_black")
	director._close_card()
	director._over = true
	_reset_world()


func _win() -> void:
	loop.night_index = 2
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _frames(3)
	var room := cs.current as WinRoom
	for time in [0.7, 1.6]:
		_to(room, time)
		await _shot("win_t%.2f" % time)
	_look(room, Vector3(3.8, 1.9, 0.2), Vector3(6.0, 1.3, 2.5), 60.0)  # Gus cheering
	await _shot("win_gus_cheers")
	_to(room, 2.9)
	await _frames(100)  # the louvres slide on real time and the first puffs need a moment to leave the mouth
	_to(room, 3.1)
	await _shot("win_vent_gas_t3.10", 30)
	_to(room, 3.9)
	await _frames(60)
	await _shot("win_gas_t3.90", 4)
	_to(room, 4.9)
	await _shot("win_blur_t4.90", 4)
	_to(room, 5.9)
	await _shot("win_dark_t5.90", 4)
	room.step(WinRoom.LENGTH_SEC)
	var truck := cs.current as TruckOutro
	_to(truck, 4.0)
	await _shot("win_truck_t4.00")
	truck.step(30.0)
	await _shot("win_truck_card")
	cs.abort()
