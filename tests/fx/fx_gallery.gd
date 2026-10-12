extends SceneTree

## Not a probe (needs a GPU window): plays one of each FX over a lit table and saves PNGs, to look at them.
##   godot --path . -s tests/fx/fx_gallery.gd -- <out_dir>
## Frames: hit_ball, hit_rail, pot, combo, trick, scratch (each ~0.15 s after its trigger, trick also at 1.2 s).

const TABLE := preload("res://src/gameplay/table/Table.tscn")

var table: Table
var director: RoundDirector
var fx: ImpactFx
var out := "/tmp"
var y: float


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		out = args[0]
	_run()


func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png("%s/fx_%s.png" % [out, name])
	print("saved fx_%s.png" % name)


func _run() -> void:
	await process_frame  # the root viewport exists once the first frame starts
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
	sun.light_energy = 0.7
	root.add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.04, 0.03, 0.06)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.45, 0.55)
	e.ambient_light_energy = 0.5
	env.environment = e
	root.add_child(env)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(-1.2, 2.2, table.spec.width_m * 0.5 + table.spec.rail_width_m + 2.3)
	cam.look_at(Vector3(0, table.spec.bed_height_m * 0.7, 0), Vector3.UP)
	cam.current = true
	cam.fov = 65.0
	root.get_viewport().set_size(Vector2i(1280, 720))
	await physics_frame
	director.start_round(NightConfig.new(), 1, 7)
	for i in 90:
		await physics_frame
	y = table.spec.bed_height_m + table.spec.ball_radius_m
	table.sim.shot_started_net.emit(1, 1, 0)
	var rest := table.global_position + Vector3(0, y, 0)

	fx._hit(FxHitTap.Kind.BALL, rest + Vector3(-0.3, 0, 0), Vector3.RIGHT, 8.0)
	await create_timer(0.15).timeout
	await _snap("hit_ball")
	await create_timer(0.8).timeout

	fx._hit(FxHitTap.Kind.RAIL, rest + Vector3(0.0, 0, -table.spec.width_m * 0.5 + 0.06), Vector3.BACK, 7.0)
	await create_timer(0.15).timeout
	await _snap("hit_rail")
	await create_timer(0.8).timeout

	var potted: Ball = null
	for b in director.get_balls():
		if director.value_of(b.ball_type) > 0 and potted == null:
			potted = b
	table.sim.ball_flag_applied.emit(potted, BallEventCodec.Flag.POCKETED)
	await create_timer(0.2).timeout
	await _snap("pot")
	await create_timer(1.0).timeout

	for i in 3:  # a chain of pots in one Shot: the third reads COMBO x4 once the streak is counted
		fx.combo.streak = 1
		table.sim.ball_flag_applied.emit(potted, BallEventCodec.Flag.POCKETED)
	await create_timer(0.25).timeout
	await _snap("combo")
	await create_timer(1.5).timeout

	director.trick_detected.emit(TrickShot.make(&"RailRunner", "g1"), "g1")
	await create_timer(0.2).timeout
	await _snap("trick")
	await create_timer(1.0).timeout
	await _snap("trick_late")
	await create_timer(2.0).timeout

	var cue: Ball = null
	for b in director.get_balls():
		if b.is_cue_ball:
			cue = b
	table.sim.ball_flag_applied.emit(cue, BallEventCodec.Flag.POCKETED)
	await create_timer(0.3).timeout
	await _snap("scratch")
	quit()
