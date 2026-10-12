extends SceneTree
## One-shot (REQ#slot): the slot machine on screen. Presses Solo, then saves a PNG per moment: the cabinet from the room and
## close, the strip, reels mid-spin, a plain win, the jackpot strobe, the pay table, the zap.
## Needs a display (it renders): DISPLAY=:0 godot --path . -s src/tools/screenshot_slot.gd
## Output: ~/work/.herdr/adhoc-1012a/slot-shots/

const OUT := "/home/cleanse/work/.herdr/adhoc-1012a/slot-shots/"

var level: Node
var cam: Camera3D
var house: SlotHouse
var machine: SlotMachine
var screen: SlotScreen
var world: WorldInteractions


func _init() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(shot_name: String) -> void:
	await _frames(4)
	DirAccess.make_dir_recursive_absolute(OUT)
	var err := root.get_texture().get_image().save_png(OUT + shot_name + ".png")
	print("shot ", shot_name, " ", error_string(err))


func _look(from: Vector3, at: Vector3, fov: float) -> void:
	cam.fov = fov
	cam.current = true
	cam.look_at_from_position(from, at)


func _seed_for(win: StringName) -> int:
	var r := RandomNumberGenerator.new()
	for s in range(1, 400000):
		r.seed = s
		if SlotMath.evaluate(SlotMath.roll(r)) == win:
			return s
	return -1


func _spin(win: StringName, tier: int) -> void:
	house.rng.seed = _seed_for(win)
	world.request(&"slot_spin", 0, {&"tier": tier})


func _run() -> void:
	await process_frame
	SaveManager.root = "user://shots_slot"
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	lobby.free()
	level = current_scene
	world = level.get_node("WorldInteractions")
	house = world.slot_house
	machine = get_first_node_in_group(&"slot_machine")
	screen = level.get_node("UILayer/SlotScreen")
	var econ: EconomyManager = level.get_node("EconomyManager")
	var player: Player = level.get_node("PlayerSpawner").get_local_player()
	player.global_position = Vector3(-3.0, 0.05, 3.6)  # out of the picture; the host still believes they stand at the machine
	world.player_position_source = func(_id: int) -> Vector3: return Bar.SLOT_AT + Vector3(1.0, 0.0, 0.0)
	econ.add_cash(2000 - econ.cash, &"shot")
	level.get_node("UILayer/HUD").visible = false
	level.get_node("UILayer/TouchControls").visible = false
	cam = Camera3D.new()
	level.add_child(cam)
	await _frames(10)

	_look(Vector3(-2.2, 1.6, 4.2), Vector3(-6.3, 1.0, 1.5), 60.0)
	await _shot("01_room_view")
	_look(Vector3(-4.3, 1.45, 1.5), Vector3(-6.3, 1.2, 1.5), 45.0)
	await _shot("02_machine_front")
	_look(Vector3(-4.6, 1.9, 0.2), Vector3(-6.3, 1.1, 1.5), 50.0)
	await _shot("03_machine_side")

	# the strip, then a spin caught mid-run
	screen.open()
	await _frames(30)
	await _shot("04_strip")
	_spin(&"lemons", 1)
	await create_timer(0.8).timeout
	await _shot("05_spinning")
	await create_timer(1.2).timeout
	await _shot("06_third_drum_teasing")
	await create_timer(2.6).timeout
	await _shot("07_lemons_landed")
	house.flush()
	machine._finish()

	screen.close()
	_look(Vector3(-3.8, 1.8, 2.6), Vector3(-6.3, 1.5, 1.5), 62.0)
	_spin(&"jackpot", 2)
	await create_timer(SlotMath.MAX_SPIN_SEC - SlotMath.SETTLE_SEC + 0.3).timeout
	await _shot("08_jackpot_a")
	await create_timer(0.3).timeout
	await _shot("09_jackpot_b")
	await create_timer(0.8).timeout
	await _shot("10_jackpot_pop")
	house.flush()
	machine._finish()
	screen.open()
	screen._pays_panel.show()
	await _shot("11_pay_table")
	screen._pays_panel.hide()
	screen.close()

	await create_timer(1.0).timeout
	_look(Vector3(-4.3, 1.45, 1.5), Vector3(-6.3, 1.2, 1.5), 45.0)
	_spin(&"zap", 0)
	await create_timer(SlotMath.MAX_SPIN_SEC).timeout
	await _shot("12_zap")
	print("SLOT SHOTS DONE")
	quit()
