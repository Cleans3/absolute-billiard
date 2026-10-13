extends SceneTree

## One-shot (adhoc-1014a V4 / V7): the aim guide on the table and a jump shot in the air, to PNGs. A real `CueController` hangs under a `Head` that carries
## the camera exactly as `Player/Head` does (1.6 m up, 1.2 m behind the cue ball, yawed to the aim, pitched at the ball), so the guide is built in the
## condition that put it on the ceiling. Needs a window (run through winrun).
##   DISPLAY=:0 godot --path . -s src/tools/screenshot_cue.gd -- <out_dir> [before]
## Writes guide_flat.png (english, a cut on an object ball), guide_jump.png (a 60 degree stroke over a blocking ball), jump_side_guide.png (the same
## jump seen from the side, arc drawn), jump_side_apex.png and jump_side_land.png (the shot itself, off the cloth, and its first touch-down).
## `before` re-poses the guide at its Head transform, which is what the top_level bug did: the picture of the ceiling.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const BALL := preload("res://src/gameplay/balls/Ball.tscn")
const CUE_CTRL := preload("res://src/gameplay/cue/CueController.tscn")
const CUE_T := preload("res://src/resources/ball_types/cue.tres")
const RED_T := preload("res://src/resources/ball_types/red_basic.tres")
const SIZE := Vector2i(1280, 720)
const EYE_M := 1.6

var table: Table
var head: Node3D
var cam: Camera3D
var ctrl: CueController
var out_dir := "/tmp"
var before := false
var y := 0.0
var balls: Array[Ball] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	out_dir = args[0] if args.size() > 0 else "/tmp"
	before = args.size() > 1 and args[1] == "before"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = SIZE
	table = TABLE.instantiate()
	root.add_child(table)
	_world()
	await physics_frame
	y = table.spec.bed_height_m + table.spec.ball_radius_m + 0.002
	head = Node3D.new()
	root.add_child(head)
	cam = Camera3D.new()
	cam.fov = 75.0
	head.add_child(cam)
	cam.current = true
	ctrl = CUE_CTRL.instantiate()  # under the Head, like the Player's: the guide's _ready sees a moved parent
	head.add_child(ctrl)
	ctrl.table = table
	ctrl.shot_sink = table.sim.request_shot
	# 1. a cut on an object ball, english and some draw: the guide's ghost ring, the object ball's line, the cue ball past the contact
	_balls(Vector3(-1.2, y, 0.25), [Vector3(0.3, y, 0.0), Vector3(1.4, y, -0.35)])
	await _settle()
	_aim(Vector3(-1.2, y, 0.25), Vector2(1.0, -0.127), 0.62, Vector2(0.45, -0.25), 0.0)
	await _shoot("guide_flat")
	# 2. a 60 degree stroke at a ball that blocks the line: the arc, in the air colour, and its landing ring beyond the ball
	ctrl.end()
	_balls(Vector3(-1.6, y, 0.0), [Vector3(-1.05, y, 0.0)])
	await _settle()
	_aim(Vector3(-1.6, y, 0.0), Vector2.RIGHT, 0.7, Vector2.ZERO, 60.0)
	await _shoot("guide_jump")
	# 3. the same jump from the side: the arc the guide draws, then the ball on it
	_side_camera(-0.5)
	await _shoot("jump_side_guide")
	var cue := balls[0]
	ctrl.fire(0.7)
	var floor_y := cue.motion.floor_y
	var apex := 0.0
	var t := 0.0
	var landed := false
	var shot_apex := false
	while t < 3.0 and not landed:
		await physics_frame
		t += 1.0 / 120.0
		var h := cue.global_position.y - floor_y
		if h > apex:
			apex = h
		if not shot_apex and apex > 0.2 and cue.linear_velocity.y <= 0.15:
			shot_apex = true
			await _capture("jump_side_apex")
		if shot_apex and h < 0.012 and cue.linear_velocity.y < -0.5:
			landed = true
			await _capture("jump_side_land")
	print("screenshot_cue: apex %.0f mm, apex shot %s, landing shot %s, written to %s" % [apex * 1000.0, shot_apex, landed, out_dir])
	quit()


func _world() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.3
	root.add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.07, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	e.ambient_light_energy = 0.8
	env.environment = e
	root.add_child(env)


func _balls(cue_at: Vector3, others: Array) -> void:
	for b in balls:
		b.free()
	balls.clear()
	balls.append(_ball(CUE_T, cue_at))
	for p: Vector3 in others:
		balls.append(_ball(RED_T, p))


func _ball(t: BallType, pos: Vector3) -> Ball:
	var b: Ball = BALL.instantiate()
	b.ball_type = t
	b.spec = table.spec
	root.add_child(b)
	b.global_position = pos
	table.sim.register(b)
	return b


func _settle() -> void:
	for i in 90:
		await physics_frame
	while table.sim.awake > 0:
		await physics_frame


## The player's pose in CUE: the Head 1.2 m behind the ball on the aim line at eye height, yawed to the aim and pitched at the ball.
func _aim(ball_at: Vector3, dir: Vector2, power: float, spin: Vector2, elevation: float) -> void:
	var yaw := atan2(-dir.x, -dir.y)
	var fwd := Vector3(dir.x, 0.0, dir.y)
	var eye := Vector3(ball_at.x, EYE_M, ball_at.z) - fwd * CueController.BACK_M
	var pitch := atan2(ball_at.y - EYE_M, CueController.BACK_M + CueController.LOOK_AHEAD_M)
	head.global_transform = Transform3D(Basis.from_euler(Vector3(pitch, yaw, 0.0)), eye)
	ctrl.begin(balls[0], yaw)
	ctrl.power = power
	ctrl.set_spin(spin)
	ctrl.set_elevation(elevation)
	cam.make_current()


## From the long side, level with the ball, looking across the table.
func _side_camera(at_x: float) -> void:
	var c := Camera3D.new()
	c.fov = 42.0
	root.add_child(c)
	c.global_position = Vector3(at_x, 1.45, 3.6)
	c.look_at(Vector3(at_x, 1.1, 0.0), Vector3.UP)
	c.make_current()


func _shoot(name: String) -> void:
	for i in 4:
		await process_frame
	if before and ctrl.guide != null:
		ctrl.guide.global_transform = head.global_transform  # what top_level did before the fix
	await _capture(name)


func _capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	if root.use_hdr_2d:
		img.linear_to_srgb()  # the viewport texture is linear when the project has hdr_2d: a PNG of it looks far too dark
	var path := "%s/%s%s.png" % [out_dir, name, "_before" if before else ""]
	print("screenshot_cue: %s %s" % [path, "OK" if img.save_png(path) == OK else "ERROR"])
