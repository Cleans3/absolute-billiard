extends SceneTree
## FailRoom.prewarm / WinRoom.prewarm (adhoc-1014b S6). Headless. Each parks the beat's new visual pieces under the level and returns their
## parent: the beacon with its spot lit, the screen pass on the shader the tier will use, and for the win one burst plume (half the quads on
## tier 2). Nothing of the world changes, every drawable is kept out of the culler's reach, and hiding the node hides the screen pass too.
##   godot --path . --headless -s tests/cutscene/room_prewarm_probe.gd     prints ROOM PREWARM OK

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	await process_frame
	_check(FailRoom.prewarm(null) == null and WinRoom.prewarm(null) == null, "no level: nothing to warm, null")
	for tier in 3:
		QualityManager.current_tier = tier
		_part(tier, &"fail", false)
		_part(tier, &"win", true)
	QualityManager.current_tier = 0
	if fails == 0:
		print("ROOM PREWARM OK")
	else:
		printerr("ROOM PREWARM FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


func _part(tier: int, which: StringName, is_win: bool) -> void:
	var level := Node3D.new()
	var ui := Node.new()
	ui.name = "UILayer"
	level.add_child(ui)
	var real_cut := CutScreen.new()
	real_cut.name = "CutScreen"
	ui.add_child(real_cut)
	root.add_child(level)
	var kids := level.get_child_count()
	var warm := (WinRoom.prewarm(level) if is_win else FailRoom.prewarm(level)) as RoomPrewarm
	var tag := "%s tier %d" % [which, tier]
	_check(warm != null and warm.get_parent() == level and level.get_child_count() == kids + 1, "%s: one parked node under the level, nothing else added" % tag)
	_check(not real_cut.active and not real_cut.visible and not real_cut.blurs, "%s: the level's own screen pass is untouched" % tag)
	var alert := warm.find_child("*", true, false) as AlertLight
	_check(alert != null and alert.position == AlertLight.MOUNT, "%s: the beacon sits at its mount" % tag)
	var spot := alert.find_children("*", "SpotLight3D", true, false)[0] as SpotLight3D
	_check(spot.is_visible_in_tree() and spot.light_energy > 0.0, "%s: its spot is lit" % tag)
	var gas := warm.find_children("*", "CPUParticles3D", true, false)
	var want := WinRoom.GAS_PARTICLES_TIER2 if tier >= 2 else WinRoom.GAS_PARTICLES
	_check(gas.size() == (1 if is_win else 0), "%s: %d plumes" % [tag, gas.size()])
	if is_win and not gas.is_empty():
		var g := gas[0] as CPUParticles3D
		_check(g.amount == want and g.emitting and g.one_shot and g.explosiveness == 1.0, "%s: one burst of %d quads" % [tag, want])
		_check(g.material_override is StandardMaterial3D and g.mesh is QuadMesh, "%s: the plume has its own material and quad" % tag)
	var cut := warm.find_children("*", "CutScreen", true, false)[0] as CutScreen
	var code := (cut.material as ShaderMaterial).shader.code
	_check(cut.visible and cut.active, "%s: the screen pass draws" % tag)
	_check(code.contains("hint_screen_texture") == (is_win and tier < 2), "%s: the screen pass is on the shader the beat will use" % tag)
	for n in warm.find_children("*", "GeometryInstance3D", true, false):
		_check((n as GeometryInstance3D).extra_cull_margin == RoomPrewarm.NO_CULL, "%s: %s is kept out of the culler's reach" % [tag, n.name])
	warm.visible = false
	_check(not cut.visible and not spot.is_visible_in_tree(), "%s: hidden, the screen pass and the spot go with it" % tag)
	warm.visible = true
	_check(cut.visible and spot.is_visible_in_tree(), "%s: shown again, they come back" % tag)
	level.free()
