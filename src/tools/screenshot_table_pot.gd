extends SceneTree

## One-shot: a ball rolls into a corner and a side pocket in the real bar room; every 0.1 s of the roll is
## captured from two rigs (diagonal-high, side-low) and tiled into one contact sheet per pocket + rig.
## Needs a window (adhoc-1011a T0 before / T2 after):
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_table_pot.gd -- <out_dir> <tag> [speed_mps] [offset_r]
## -> <out_dir>/<tag>_<pocket>_<rig>.png ; offset_r = lateral miss in ball radii (0 = dead centre).

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")

const TABLE_POS := Vector3(0, 0, -3.5)  # screenshot_bar_room.gd: the same room placement as MainLevel
const FRAME_SIZE := Vector2i(480, 300)
const TILES := 10
const STEP_TICKS := 12  # 0.1 s at the 120 Hz live tick
const COLS := 5

var table: Table
var cam: Camera3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir := args[0] if args.size() > 0 else "/tmp"
	var tag := args[1] if args.size() > 1 else "shot"
	var speed := float(args[2]) if args.size() > 2 else 1.6
	var offset_r := float(args[3]) if args.size() > 3 else 0.0
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.add_child(ROOM.instantiate())
	table = TABLE.instantiate()
	table.position = TABLE_POS
	root.add_child(table)
	cam = Camera3D.new()
	cam.fov = 62.0
	root.add_child(cam)
	cam.current = true
	root.size = Vector2i(FRAME_SIZE)
	root.msaa_3d = Viewport.MSAA_2X
	await physics_frame
	for pocket_id in [&"corner_se", &"side_s"]:
		for rig in [&"high", &"low"]:
			await _shoot(out_dir, tag, pocket_id, rig, speed, offset_r)
	print("screenshot_table_pot OK")
	quit()


func _shoot(out_dir: String, tag: String, pocket_id: StringName, rig: StringName, speed: float, offset_r: float) -> void:
	var ps := table.get_pocket(pocket_id)
	var s := table.spec
	var y := s.bed_height_m + s.ball_radius_m + s.clearance_margin_m
	var p := Vector3(ps.position.x, 0.0, ps.position.z)
	var dir := Vector3(-signf(ps.position.x), 0.0, -signf(ps.position.z)).normalized() if pocket_id.begins_with("corner") else Vector3(0, 0, signf(ps.position.z))
	dir = -dir  # toward the pocket
	var side := dir.cross(Vector3.UP).normalized()
	var start := p - dir * 0.55 + side * offset_r * s.ball_radius_m
	var b: Ball = BALL.instantiate()
	b.ball_type = RED_T
	b.spec = s
	root.add_child(b)
	b.global_position = table.to_global(Vector3(start.x, y, start.z))
	table.sim.register(b)
	await physics_frame
	_place_cam(rig, ps, dir, side)
	b.freeze = false
	b.is_resting = false
	b.linear_velocity = dir * speed
	b.angular_velocity = Vector3(dir.z, 0, -dir.x) * (speed / b.radius)
	table.sim._on_struck(b, ShotIntent.new())
	var tiles: Array[Image] = []
	for _i in 3:
		await process_frame  # the first frame after a camera move renders black
	var next := Engine.get_physics_frames()
	while tiles.size() < TILES:
		await process_frame
		if Engine.get_physics_frames() >= next:
			next += STEP_TICKS
			tiles.append(root.get_texture().get_image())
	var sheet := Image.create(FRAME_SIZE.x * COLS, FRAME_SIZE.y * ceili(float(TILES) / COLS), false, Image.FORMAT_RGB8)
	for i in tiles.size():
		tiles[i].convert(Image.FORMAT_RGB8)
		sheet.blit_rect(tiles[i], Rect2i(Vector2i.ZERO, FRAME_SIZE), Vector2i(i % COLS, i / COLS) * FRAME_SIZE)
	var path := "%s/%s_%s_%s.png" % [out_dir, tag, pocket_id, rig]
	print("pot sheet ", path, " ", "OK" if sheet.save_png(path) == OK else "ERR", " pocketed=", b.is_pocketed, " retired=", b.retired)
	root.remove_child(b)
	b.free()
	await physics_frame
	table.sim.awake = 0


func _place_cam(rig: StringName, ps: PocketSpec, dir: Vector3, side: Vector3) -> void:
	var at := table.to_global(Vector3(ps.position.x, table.spec.bed_height_m, ps.position.z))
	if rig == &"high":  # down the pocket line, above the cloth
		cam.global_position = at - dir * 0.95 + Vector3(0, 0.55, 0)
		cam.look_at(at - dir * 0.05 - Vector3(0, 0.02, 0), Vector3.UP)
	else:  # across the mouth, low: shows the ball's height against the cloth plane
		var back := 0.45 if ps.id.begins_with("corner") else 0.2
		cam.global_position = at - dir * back + side * 0.6 + Vector3(0, 0.2, 0)
		cam.look_at(at - dir * 0.12, Vector3.UP)
