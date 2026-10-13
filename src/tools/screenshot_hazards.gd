extends SceneTree

## One-shot: renders the table in the real bar room with each hazard of adhoc-1014a G live (06 P50-P53) from a few poses, through the
## same path a Round uses (EffectManager.begin_event with the host's HazardModel.roll, a RackDropper rack). Needs a window.
##   DISPLAY=:0 ~/work/.herdr/adhoc-1014a/winrun godot --path . -s src/tools/screenshot_hazards.gd -- <out_dir> [hazard,hazard] [seed]
## -> <out_dir>/<hazard>_<pose>.png. The viewport is LINEAR (the project has hdr_2d): every shot goes through linear_to_srgb before it
## is saved, or it looks far too dark.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const TABLE_POS := Vector3(0, 0, -3.5)
const SIZE := Vector2i(1280, 720)
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const BOARD := preload("res://src/gameplay/bar/Blackboard.tscn")
const ALL: Array[StringName] = [&"sunken_ship", &"vacation", &"pinball", &"double_ball", &"ice_rink", &"shaky_hands", &"lead_ball"]
const SCENE_POSES: Array[StringName] = [&"sunken_ship", &"vacation", &"pinball", &"double_ball"]  # the others are stat-only: the Blackboard is their picture

var table: Table
var fx: EffectManager
var cam: Camera3D
var board: Blackboard
var _balls: Array[Ball] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := args[0] if args.size() > 0 else "/tmp/hazard_shots"
	var which: Array[StringName] = []
	if args.size() > 1:
		for id in args[1].split(","):
			which.append(StringName(id))
	else:
		which = ALL
	var seed_ := int(args[2]) if args.size() > 2 else 4242
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = SIZE
	root.msaa_3d = Viewport.MSAA_2X
	root.add_child(ROOM.instantiate())
	table = TABLE.instantiate()
	table.position = TABLE_POS
	root.add_child(table)
	fx = EffectManager.new()
	fx.sim = table.sim
	root.add_child(fx)
	board = BOARD.instantiate()
	board.effects = fx
	board.position = Vector3(0.0, 1.8, 1.0)
	root.add_child(board)
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.05
	root.add_child(cam)
	cam.current = true
	await physics_frame
	for id in which:
		await _shoot(out_dir, id, seed_)
	quit()


func _shoot(out_dir: String, id: StringName, seed_: int) -> void:
	var e := FxCatalog.event(id)
	var params := HazardModel.roll(e.hazard, seed_, table.spec, table.layout) if e.hazard != &"" else PackedInt32Array()
	fx.begin_event(e, &"", params)
	var mult := fx.get_stat(&"object_ball_mult", EffectManager.ALL_PEERS, 1.0)
	var cfg := NightConfig.new()
	cfg.object_ball_count = 9
	cfg.unlocked_ball_types = [&"red_basic", &"blue_mid", &"gold_prize", &"black_penalty"]
	if SCENE_POSES.has(id):
		var rack := RackDropper.drop(table.spec, table.layout, cfg, seed_, 0, mult, fx.hazard_keepouts())
		var y := table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
		_spawn(CUE_T, Vector3(table.layout.spots.head.x, y, table.layout.spots.head.z))
		for entry in rack:
			_spawn(entry.type, Vector3(entry.pos.x, y, entry.pos.y))
	for i in 150:  # the balls settle, the shaders run
		await physics_frame
	var spec := table.spec
	var hl := spec.length_m * 0.5
	var hw := spec.width_m * 0.5
	var poses := {"board": [Vector3(0.0, 1.8, 3.4) - TABLE_POS, Vector3(0.0, 1.8, 1.0) - TABLE_POS]}
	if SCENE_POSES.has(id):
		poses.merge({
		"over": [Vector3(-0.4, spec.bed_height_m + 2.3, hw + 2.1), Vector3(0.2, spec.bed_height_m, 0.0)],
		"top": [Vector3(0.0, spec.bed_height_m + 1.7, 0.02), Vector3(0.0, spec.bed_height_m, 0.0)],
		"low": [Vector3(-hl - 1.4, spec.bed_height_m + 0.75, hw + 0.9), Vector3(0.4, spec.bed_height_m, -0.1)],
	})
	if id == &"sunken_ship":
		var m: HazardModel = fx._events[0].model
		var sg := Vector2(signf(m.corner_local.x), signf(m.corner_local.y))
		poses["corner"] = [Vector3(sg.x * (hl + 2.0), 1.35, sg.y * (hw + 1.7)), Vector3(sg.x * (hl + 0.1), 0.35, sg.y * (hw + 0.1))]
		poses["corner_top"] = [Vector3(sg.x * (hl - 0.2), spec.bed_height_m + 1.6, sg.y * (hw - 0.1)), Vector3(sg.x * (hl + 0.1), spec.bed_height_m, sg.y * (hw + 0.1))]
	for pose: String in poses:
		cam.global_position = table.to_global(poses[pose][0])
		cam.fov = 105.0 if pose == "top" else 62.0
		cam.look_at(table.to_global(poses[pose][1]), Vector3.FORWARD if pose.ends_with("top") else Vector3.UP)
		for i in 8:
			await process_frame
		var img := root.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		if root.use_hdr_2d:
			img.linear_to_srgb()
		var path := "%s/%s_%s.png" % [out_dir, id, pose]
		img.save_png(path)
		print("shot: %s" % path)
	fx._on_round_ended(&"timer", 0)
	for b in _balls:
		b.queue_free()
	_balls.clear()
	for i in 6:
		await physics_frame


func _spawn(type: BallType, pos: Vector3) -> void:
	var b: Ball = BALL.instantiate()
	b.ball_type = type
	b.spec = table.spec
	root.add_child(b)
	b.global_position = table.to_global(pos)
	table.sim.register(b)
	_balls.append(b)
