extends SceneTree
## Lean on a rail is visible (C13, 03 §3.7): through the real request path the presser's body leans for ~2 s, the rail
## carries a marker while its cushion is dead, the toast names who and which rail, the marker goes when the Shot resolves
## and is rebuilt from the Effect state alone (a resumed client).
##   godot --path . --headless -s tests/player/lean_probe.gd
## Prints LEAN OK, or the failing checks and LEAN FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(90.0).timeout.connect(func() -> void:
		if not finished:
			print("LEAN FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## The one place a probe waits for the level to be playable after pressing Solo (alpha swaps the body for
## `await SoloSupport.until_playable(self)` once the threaded loading screen lands).
func _until_playable() -> void:
	await _frames(8)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_lean"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	var level := current_scene
	var rd: RoundDirector = level.get_node("RoundDirector")
	var fx: EffectManager = level.get_node("EffectManager")
	var world: WorldInteractions = level.get_node("WorldInteractions")
	var lf: LeanFeedback = level.get_node("LeanFeedback")
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var me := root.multiplayer.get_unique_id()
	level.get_node("GameLoop").advance()
	await _frames(30)
	_check(player != null and lf != null, "player and LeanFeedback exist")
	# 03 §3.7: lean_on_rail target 1 = rail_w, prop at (-3.44, 0, -3.5)
	player.global_position = Vector3(-3.44, 0.0, -3.5)
	player.velocity = Vector3.ZERO
	await _frames(2)
	_check(not lf.is_marked(1) and not player.humanoid.is_leaning(), "nothing leaning, no marker before the press")
	world.request(&"lean_on_rail", 1, {})
	await _frames(2)
	_check(lf.is_marked(1) and not lf.is_marked(2), "west rail marked on apply, no other rail")
	_check(player.humanoid.is_leaning(), "the presser's body leans")
	var toast: String = UIRouter.instance._toast_label.text
	_check(toast.contains("leaned on the west rail") and toast.contains("15%") and toast.length() <= 56, "toast names the rail and the effect: '%s'" % toast)
	await create_timer(LeanFeedback.LEAN_SEC + 0.4).timeout
	_check(not player.humanoid.is_leaning(), "the lean lasts about %.0f s" % LeanFeedback.LEAN_SEC)
	_check(lf.is_marked(1), "the marker stays until the Shot resolves")
	var none: Array[StringName] = []
	rd.shot_ended.emit("lean_probe", me, 0, none, false)
	await _frames(2)
	_check(not lf.is_marked(1), "the marker clears when the Shot resolves")
	# a client that resumed has only the Effect state: the marker follows it
	fx.apply_local(FxCatalog.effect(&"lean_on_rail_dead"), me, 4, EffectManager.SHOT)
	_check(lf.is_marked(4), "a mirrored Effect marks its rail")
	lf._build()
	_check(lf.is_marked(4) and not lf.is_marked(1), "the markers rebuild from the Effect state")
	# walking off ends a lean early
	player.humanoid.lean_on(Vector3(-3.0, 1.0, -3.5), 2.0)
	player.humanoid._speed = 2.0
	await _frames(2)
	_check(not player.humanoid.is_leaning(), "walking off ends the lean")
	finished = true
	print("LEAN OK" if fails == 0 else "LEAN FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)
