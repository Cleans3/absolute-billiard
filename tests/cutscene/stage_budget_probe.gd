extends SceneTree
## The stage cutscenes' GPU budget per quality tier (adhoc-1014b C6). Headless, on a manual clock. Each stage part (IntroVan, IntroCabin,
## TruckOutro) is built at tier 0, 1 and 2 and sampled at a few times; it must have at most 4 / 3 / 2 VISIBLE Light3D (energy ignored: a light
## parked at 0 still counts), every range at most 25 m, no DirectionalLight3D, and from tier 1 no alpha surface wider than 2 m radius.
## The in-room beats: WinRoom runs at most half its gas on tier 2, and CutScreen reads the screen (copy + mip chain) only for a scene that
## blurs below tier 2, so FailRoom's red wash and every tier-2 wash use the flat shader.
##   godot --path . --headless -s tests/cutscene/stage_budget_probe.gd     prints STAGE BUDGET OK

const PARTS := [
	[&"intro_van", "res://src/cutscene/IntroVan.tscn", {"crew_size": 4}, [0.0, 1.0, 1.9]],
	[&"intro_cabin", "res://src/cutscene/IntroCabin.tscn", {}, [0.0, 1.5, 2.9]],
	[&"truck_outro", "res://src/cutscene/TruckOutro.tscn", {"crew_size": 4}, [0.0, 3.0, 12.0]],
]
const MAX_LIGHTS: Array[int] = [4, 3, 2]
const MAX_RANGE_M := 25.0
const MAX_ALPHA_RADIUS_M := 2.0
const WIN := "res://src/cutscene/WinRoom.tscn"
const FAIL := "res://src/cutscene/FailRoom.tscn"

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	root.add_child(UIRouter.new())
	var base_cam := Camera3D.new()
	root.add_child(base_cam)
	base_cam.make_current()
	await process_frame
	for tier in 3:
		QualityManager.current_tier = tier
		for p: Array in PARTS:
			_stage_part(tier, p[0], p[1], p[2], p[3])
		_room_beats(tier)
	QualityManager.current_tier = 0
	if fails == 0:
		print("STAGE BUDGET OK")
	else:
		printerr("STAGE BUDGET FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


func _make(path: String, opts: Dictionary) -> Cutscene:
	var cs := (load(path) as PackedScene).instantiate() as Cutscene
	var o := {"seed": 4242, "manual": true}
	o.merge(opts, true)
	cs.configure(o)
	root.add_child(cs)
	if cs.on_stage:
		cs.global_position = Cutscene.STAGE_ORIGIN
	return cs


# --- the stage parts ---------------------------------------------------------------------------------------------------------------

func _stage_part(tier: int, id: StringName, path: String, opts: Dictionary, times: Array) -> void:
	var cs := _make(path, opts)
	cs.play()
	var worst_lights := 0
	var worst_range := 0.0
	var worst_alpha := 0.0
	for time: float in times:
		cs.step(maxf(time - cs.t, 0.0))
		var lights := 0
		for n in cs.find_children("*", "Light3D", true, false):
			var l := n as Light3D
			if not l.is_visible_in_tree():
				continue
			lights += 1
			_check(not (l is DirectionalLight3D), "%s tier %d: no DirectionalLight3D (it would light the whole level)" % [id, tier])
			worst_range = maxf(worst_range, l.omni_range if l is OmniLight3D else (l.spot_range if l is SpotLight3D else 0.0))
		worst_lights = maxi(worst_lights, lights)
		for n in cs.find_children("*", "GeometryInstance3D", true, false):
			var g := n as GeometryInstance3D
			if g.is_visible_in_tree() and _is_alpha(g):
				worst_alpha = maxf(worst_alpha, _radius(g))
	print("STAGE_BUDGET tier=%d %-12s lights=%d max_range=%.1f alpha_radius=%.1f" % [tier, id, worst_lights, worst_range, worst_alpha])
	_check(worst_lights <= MAX_LIGHTS[tier], "%s tier %d: %d visible lights, at most %d" % [id, tier, worst_lights, MAX_LIGHTS[tier]])
	_check(worst_range <= MAX_RANGE_M, "%s tier %d: a light reaches %.1f m, at most %.0f" % [id, tier, worst_range, MAX_RANGE_M])
	_check(tier == 0 or worst_alpha <= MAX_ALPHA_RADIUS_M, "%s tier %d: an alpha surface of radius %.1f m, at most %.0f" % [id, tier, worst_alpha, MAX_ALPHA_RADIUS_M])
	cs.abort()
	cs.free()


func _is_alpha(g: GeometryInstance3D) -> bool:
	var mats: Array[Material] = [g.material_override, g.material_overlay]
	var mesh: Mesh = null
	if g is MeshInstance3D:
		mesh = (g as MeshInstance3D).mesh
	elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh != null:
		mesh = (g as MultiMeshInstance3D).multimesh.mesh
	if mesh != null:
		for i in mesh.get_surface_count():
			mats.append(mesh.surface_get_material(i))
	for m in mats:
		if m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false


## Half the widest side of the mesh's own box, times the node's biggest scale.
func _radius(g: GeometryInstance3D) -> float:
	var box := AABB()
	if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
		box = (g as MeshInstance3D).mesh.get_aabb()
	elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh != null and (g as MultiMeshInstance3D).multimesh.mesh != null:
		box = (g as MultiMeshInstance3D).multimesh.mesh.get_aabb()
	return box.size[box.size.max_axis_index()] * 0.5 * g.global_transform.basis.get_scale()[g.global_transform.basis.get_scale().max_axis_index()]


# --- the in-room beats -------------------------------------------------------------------------------------------------------------

## A bare level: just the `UILayer/CutScreen` the two beats look for.
func _stub_level() -> Array:
	var level := Node.new()
	var ui := Node.new()
	ui.name = "UILayer"
	level.add_child(ui)
	var cut := CutScreen.new()
	cut.name = "CutScreen"
	ui.add_child(cut)
	root.add_child(level)
	return [level, cut]


func _reads_screen(cut: CutScreen) -> bool:
	return (cut.material as ShaderMaterial).shader.code.contains("hint_screen_texture")


func _room_beats(tier: int) -> void:
	var fix := _stub_level()
	var cut: CutScreen = fix[1]
	var win := _make(WIN, {"level": fix[0]}) as WinRoom
	win.play()
	_check(cut.blurs, "win tier %d: the beat tells CutScreen it blurs" % tier)
	var want := WinRoom.GAS_PARTICLES_TIER2 if tier >= 2 else WinRoom.GAS_PARTICLES
	_check(win._gas.amount == want, "win tier %d: %d gas particles (wanted %d)" % [tier, win._gas.amount, want])
	_check(win._gas.amount * 2 <= WinRoom.GAS_PARTICLES or tier < 2, "win tier 2: at most half of the %d gas particles" % WinRoom.GAS_PARTICLES)
	win.step(4.5)  # the gas is blurring the view
	_check(cut.active and (tier >= 2) != _reads_screen(cut), "win tier %d: the screen is read for the blur on tiers 0-1 only" % tier)
	win.abort()
	_check(not cut.blurs and not cut.active, "win tier %d: the beat puts the screen pass away" % tier)
	win.free()
	var fail := _make(FAIL, {"level": fix[0]})
	fail.play()
	fail.step(1.0)
	_check(cut.active and not _reads_screen(cut), "fail tier %d: the red wash blends over the screen, it does not read it" % tier)
	fail.abort()
	fail.free()
	(fix[0] as Node).free()
