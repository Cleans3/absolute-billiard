extends SceneTree

## ImpactFx as wired in MainLevel.tscn (solo): the node resolves its exports, builds its pools, and a real shot through the
## host's own PhysicsSim pops FX (a strike and at least one hit). Presentation only: the shot itself resolves as without it.
##   godot --path . --headless -s tests/fx/fx_level_probe.gd
## Prints FXLEVEL OK, or the failing checks and FXLEVEL FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("FXLEVEL FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_fx_level"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	var fx := level.get_node_or_null("ImpactFx") as ImpactFx
	_check(fx != null, "MainLevel has an ImpactFx node")
	if fx == null:
		print("FXLEVEL FAIL")
		quit(1)
		return
	var counts := {}
	fx.fx_fired.connect(func(kind: StringName, _s: float) -> void: counts[kind] = int(counts.get(kind, 0)) + 1)
	var rd: RoundDirector = level.get_node("RoundDirector")
	var table: Table = level.get_node("Table")
	level.get_node("GameLoop").advance()
	for i in 240:
		await physics_frame
	_check(fx.table == table and fx.round_director == rd, "the exports resolve to the level's table and director")
	_check(fx.get_child_count() > 30, "the pools are built (%d nodes)" % fx.get_child_count())
	var cue: Ball = null
	var target: Ball = null
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	for b in rd.get_balls():
		if not b.is_cue_ball and (target == null or b.global_position.distance_to(cue.global_position) < target.global_position.distance_to(cue.global_position)):
			target = b
	var d := target.global_position - cue.global_position
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2(d.x, d.z).normalized()
	intent.power = 0.9
	table.sim.request_shot(intent)
	await rd.shot_ended
	await create_timer(0.3).timeout
	print("fxlevel: a real solo shot fired %s" % str(counts))
	_check(int(counts.get(&"kick", 0)) == 1, "the strike pops once")
	_check(int(counts.get(&"ball", 0)) >= 1, "the cue ball's hit pops")
	finished = true
	print("FXLEVEL OK" if fails == 0 else "FXLEVEL FAIL")
	quit(0 if fails == 0 else 1)
