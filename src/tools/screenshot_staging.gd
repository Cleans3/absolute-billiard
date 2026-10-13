extends SceneTree

## One-shot: the real MainLevel (Solo, a live Round), the Round's set-up and clean-up pictured at fixed instants, to PNGs. Needs a window.
##   godot --path . -s src/tools/screenshot_staging.gd -- <out_prefix> [setup|cleanup]
## Writes <prefix>_setup_vent.png (the louvres apart, the saucer coming out of the mouth), _setup_hover.png (the vent shut behind it, the saucer
## over the table), _setup_beam.png (mid-beam: half the rack is in, the cone on the next ball), _setup_farewell.png (the last ball in, the saucer
## dissolving), and _cleanup_open.png (the flaps dropping, balls riding them), _cleanup_fall.png (balls falling into the pit), _cleanup_pit.png
## (all gone, the pit open). The clock is driven by hand (RoundStaging.seek), so every frame is the same instant on every run.

const SETUP_SHOTS := [
	# name, set-up second, eye, look-at
	["vent", 0.85, Vector3(-0.6, 1.5, -0.6), Vector3(2.5, 3.0, -3.5)],
	["hover", 1.6, Vector3(-1.2, 1.7, -0.7), Vector3(0.5, 2.0, -3.5)],
	["beam", -1.0, Vector3(0.4, 1.9, -0.9), Vector3(0.0, 1.0, -3.5)],  # second < 0: halfway through the rack (see _beam_time)
	["farewell", -2.0, Vector3(0.4, 1.9, -0.9), Vector3(0.0, 1.5, -3.5)],
]
const CLEANUP_SHOTS := [
	["open", 0.55, Vector3(0.0, 2.9, -1.2), Vector3(0.0, 0.9, -3.5)],
	["fall", 0.75, Vector3(0.0, 2.9, -1.2), Vector3(0.0, 0.9, -3.5)],
	["pit", 1.1, Vector3(0.0, 2.9, -1.2), Vector3(0.0, 0.9, -3.5)],
]

var level: Node
var cam: Camera3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var prefix := args[0] if args.size() > 0 else "res://staging"
	var which := args[1] if args.size() > 1 else "all"
	SaveManager.root = "user://shot_staging"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)  # staging skipped: the rack is placed at once, this tool plays the stager by hand
	level = current_scene
	if is_instance_valid(lobby):
		lobby.queue_free()
	var rd: RoundDirector = level.get_node("RoundDirector")
	var stager: RoundStaging = level.get_node("Staging")
	level.get_node("GameLoop").advance()
	for i in 90:
		await process_frame  # the rack settles
	cam = Camera3D.new()
	cam.fov = 62.0
	level.add_child(cam)
	for cl: CanvasLayer in root.find_children("*", "CanvasLayer", true, false):
		cl.visible = false
	var balls := rd.get_balls()
	var n := balls.size()
	if which != "cleanup":
		for s in SETUP_SHOTS:
			stager.play_setup(balls, false)
			var t: float = s[1]
			if t < -1.5:
				t = StagingPlan.last_in(n) + 0.15
			elif t < 0.0:
				t = StagingPlan.reveal_start(int(n * 0.5), n) + 0.2
			stager.seek(t)
			await _shoot("%s_setup_%s.png" % [prefix, s[0]], s[2], s[3])
			stager.finish()
	if which != "setup":
		for s in CLEANUP_SHOTS:
			stager.play_cleanup(rd.get_balls(), false)
			stager.seek(float(s[1]))
			await _shoot("%s_cleanup_%s.png" % [prefix, s[0]], s[2], s[3])
			stager.finish()
			rd.start_round(rd.get("_config"), 1, 7)  # the next picture needs a rack again (skip_staging is on: placed at once)
			for i in 40:
				await process_frame
	quit(0)


func _shoot(path: String, eye: Vector3, target: Vector3) -> void:
	cam.global_position = eye
	cam.look_at(target)
	for i in 8:
		cam.current = true  # the player's camera reclaims current while it spawns
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
	print("saved ", path)
