extends SceneTree
## Headless camera probe (docs/plan/02 §3.2; M5): view_quality terms, occlusion with balls ignored, best rig
## wins, Camera_Mult formula, award_shot_reward uses it, rig moves.
##   godot --path . --headless -s tests/economy/camera_probe.gd
## Prints CAMERA OK, or the failing checks and CAMERA FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		if not finished:
			print("CAMERA FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, eps := 0.001) -> bool:
	return absf(a - b) <= eps


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	await process_frame
	_math()
	SaveManager.root = "user://test_camera_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	await _scene()
	finished = true
	print("CAMERA OK" if fails == 0 else "CAMERA FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _math() -> void:
	_check(_near(CameraScorer.view_quality(2.0, 1.0, true), 1.0), "inside FULL_RANGE: full marks")
	_check(_near(CameraScorer.view_quality(CameraScorer.MAX_RANGE, 1.0, true), 0.0), "at MAX_RANGE: nothing")
	_check(_near(CameraScorer.view_quality(7.5, 1.0, true), 0.5), "halfway falloff")
	_check(_near(CameraScorer.view_quality(2.0, 0.6, true), 0.6), "facing_dot scales")
	_check(_near(CameraScorer.view_quality(2.0, -0.5, true), 0.0), "behind the camera: nothing")
	_check(_near(CameraScorer.view_quality(2.0, 1.0, false), 0.0), "occluded: nothing")
	_check(_near(CameraScorer.camera_mult(1.5, 1.0), 1.5) and _near(CameraScorer.camera_mult(1.25, 0.5), 1.125), "Camera_Mult = 1 + (tier−1) × q")
	_check(_near(CameraScorer.camera_mult(1.0, 1.0), 1.0), "tier 1 adds nothing")
	_check(_near(CameraScorer.camera_mult(1.5, 1.0, 1.2), 1.8), "stream_camera_bonus_mult multiplies")


func _scene() -> void:
	var level := current_scene
	var table: Table = level.get_node("Table")
	var cams: CameraRigs = level.get_node("Cameras")
	var eco: EconomyManager = level.get_node("EconomyManager")
	var stream: StreamManager = level.get_node("StreamManager")
	var pocket_id: StringName = table.pockets.keys()[0]
	var target := table.to_global(table.get_pocket(pocket_id).position) + Vector3.UP * CameraRigs.POCKET_LIFT
	_check(cams.rigs.size() == 2 and cams.rigs[0].camera_id == &"cam_1", "two rigs to start")
	# a rig one 'ideal' distance from the pocket, looking straight at it
	var rig := cams.rigs[0]
	var dir := Vector3(1, 0, 0)
	var run := (rig.EYE_HEIGHT - (target.y)) / tan(CameraRig.PITCH)
	var place := func(r: CameraRig, d: Vector3, yaw_from_dir: float) -> void:
		r.global_position = Vector3(target.x, 0, target.z) - d * run
		r.rotation.y = atan2(-d.x, -d.z) + yaw_from_dir
	place.call(rig, dir, 0.0)
	cams.rigs[1].global_position = Vector3(0, 0, 40)  # out of range: worthless
	var space := rig.get_world_3d().direct_space_state
	var none: Array[RID] = []
	await _frames(2)
	var q := CameraScorer.score(rig, target, space, none, 0xFFFFFFFF)
	_check(q > 0.9, "clear, close, facing: q=%s" % q)
	place.call(rig, dir, PI)
	_check(_near(CameraScorer.score(rig, target, space, none, 0xFFFFFFFF), 0.0), "facing away scores 0")
	place.call(rig, dir, 0.0)
	# cover between eye and pocket
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 3.0, 3.0)
	shape.shape = box
	wall.add_child(shape)
	level.add_child(wall)
	wall.global_position = Vector3(target.x, 0, target.z) - dir * (run * 0.5) + Vector3.UP * 1.0
	await _frames(3)
	_check(_near(CameraScorer.score(rig, target, space, none, 0xFFFFFFFF), 0.0), "a wall in the way scores 0")
	var ignore: Array[RID] = [wall.get_rid()]
	_check(CameraScorer.score(rig, target, space, ignore, 0xFFFFFFFF) > 0.9, "excluded bodies (the balls) are not cover")
	# best rig wins: rig 2 takes a clear spot on the far side
	place.call(cams.rigs[1], -dir, 0.0)
	await _frames(2)
	var win := CameraScorer.best(cams.rigs, target, space, none, 0xFFFFFFFF)
	_check(win.rig == cams.rigs[1] and win.quality > 0.9, "the clear rig beats the blocked one")
	# Camera_Mult through the real path
	stream.viewers = 500
	stream.hype = 0.0
	var mult := cams.camera_mult(pocket_id)
	_check(_near(mult, 1.0), "camera_mult on tier 1 is 1.0 (got %s)" % mult)
	eco.owned[&"lens_t3"] = 1
	eco.owned_changed.emit()
	_check(cams.rigs[0].tier == 3, "lens_t3 raises every rig")
	mult = cams.camera_mult(pocket_id)
	_check(cams.last_quality > 0.9 and _near(mult, 1.0 + 0.5 * cams.last_quality), "tier 3 clear view: ×%s (q=%s)" % [mult, cams.last_quality])
	var reward := eco.award_shot_reward(100, [] as Array[StringName], pocket_id)
	var expect := roundi(100 * mult * stream.viewer_scalar() * EconomyManager.POINT_TO_CASH_RATE)
	_check(reward == expect and reward > roundi(100 * stream.viewer_scalar() * 0.3), "award_shot_reward uses Camera_Mult: %d vs %d" % [reward, expect])
	_check(eco.award_shot_reward(100, [] as Array[StringName], &"") == roundi(100 * stream.viewer_scalar() * 0.3), "no pocket → Camera_Mult 1.0")
	# rigs move: grab (no spawner → reach not checked), then place
	cams.spawner = null
	var world: WorldInteractions = level.get_node("WorldInteractions")
	world.camera_move_requested.emit(1, 1, {})
	_check(cams.rigs[0].held_by == 1, "grab")
	world.camera_move_requested.emit(1, 1, {&"place_at": Vector3(2, 0, 2)})
	_check(cams.rigs[0].held_by == 0 and cams.rigs[0].global_position.is_equal_approx(Vector3(2, 0, 2)), "place")
	# spare tripods add rigs
	eco.owned[&"spare_tripod"] = 2
	eco.owned_changed.emit()
	_check(cams.rigs.size() == 4 and cams.rigs[3].tier == 3, "4 rigs after two spare tripods")
	DirAccess.remove_absolute("user://test_camera_%d" % OS.get_process_id())
