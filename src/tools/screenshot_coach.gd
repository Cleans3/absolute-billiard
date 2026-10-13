extends SceneTree
## One-shot (adhoc-1014a V2, 06 P44): the first-time coach on screen. Presses Solo on a fresh profile with the coach on and drives
## the real signals the way tests/ui/coach_probe.gd does, saving a PNG per step: the GO LIVE hint, the wait card, WALK, AIM, SPIN, POWER
## in the touch layout (and the desktop wording of two of them), the HUD after the shot, and Settings > Help.
## Needs a display (it renders), and the machine-wide lock: ~/work/.herdr/adhoc-1014a/winrun godot --path . -s src/tools/screenshot_coach.gd
## Output: ~/work/.herdr/adhoc-1014a/shots/c/

const OUT := "/home/cleanse/work/.herdr/adhoc-1014a/shots/c/"

var level: Node
var loop: GameLoop
var rd: RoundDirector
var hud: Control
var coach: Coach
var player: Player
var controls: TouchControls


func _init() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(shot_name: String) -> void:
	await _frames(8)
	DirAccess.make_dir_recursive_absolute(OUT)
	var err := root.get_texture().get_image().save_png(OUT + shot_name + ".png")
	print("shot ", shot_name, " ", error_string(err), "  step=", Coach.Step.keys()[coach.step], "  card='", coach._body.text, "'")


func _until(cond: Callable, sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while not cond.call() and Time.get_ticks_msec() < end:
		await process_frame


func _cue_ball() -> Ball:
	for b in rd.get_balls():
		if b.is_cue_ball:
			return b
	return null


func _stand_by_cue_ball() -> void:
	var b := _cue_ball()
	player.global_position = Vector3(b.global_position.x, 0.0, b.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0


func _run() -> void:
	await process_frame
	SaveManager.root = "user://shots_coach"
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, false, false, false, false, true)
	lobby.free()
	level = current_scene
	loop = level.get_node("GameLoop")
	rd = level.get_node("RoundDirector")
	hud = level.get_node("UILayer/HUD")
	coach = hud.coach
	controls = level.get_node("UILayer/TouchControls")
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	await _frames(10)

	# first spawn: no story cards, the GO LIVE hint over the button and the card in the corner
	controls.touch = true
	coach._show()
	await _shot("01_first_spawn")  # the spawn view as it is, nothing moved
	player.global_position = Vector3(-1.2, 0.0, 0.6)
	player.rotation.y = PI / 4.0
	player.head.rotation.x = 0.05
	await _shot("02_go_live_hint")
	controls.touch = false
	coach._show()
	await _shot("03_go_live_hint_desktop")
	controls.touch = true
	coach._show()

	# the Round goes live: my turn
	loop.advance()
	await _until(func() -> bool: return loop.phase == GameLoop.Phase.ROUND_LIVE, 5.0)
	await _until(func() -> bool: return level.get_node("Table").sim.awake == 0, 10.0)
	_stand_by_cue_ball()
	await _shot("04_walk_to_the_cue_ball_touch")
	controls.touch = false
	coach._show()
	await _shot("05_walk_desktop")
	controls.touch = true
	coach._show()

	# someone else is shooting (the second or third player's view)
	rd.current_shooter_id = 2
	rd.shooter_changed.emit(2)
	await _shot("06_wait_for_your_turn")
	rd.current_shooter_id = 1
	rd.shooter_changed.emit(1)
	await _frames(2)

	# CUE: aim, spin, power
	_stand_by_cue_ball()
	await _frames(2)
	player.enter_cue()
	await _shot("07_aim_touch")
	player.cue.turn(0.25)
	await _shot("08_spin_touch")
	player.cue.set_spin(Vector2(0.3, 0.2))
	await _shot("09_power_touch")
	controls.power.set_value(0.6)
	await _shot("10_power_pulled_touch")
	controls.touch = false
	controls.power.set_value(0.0)
	coach._show()
	await _shot("11_power_desktop")
	controls.touch = true
	coach._show()

	# the shot
	player.cue.fire(0.45)
	await _until(func() -> bool: return level.get_node("Table").sim.awake == 0 and not rd.shot_in_progress, 20.0)
	await _frames(20)
	await _shot("12_after_the_first_shot")

	# Settings > Help > Replay tutorial
	var settings := level.get_node("UILayer/SettingsScreen") as SettingsScreen
	settings.open()
	settings._tabs.current_tab = settings._tabs.get_tab_count() - 1
	await _shot("13_settings_help_replay")
	quit(0)
