extends SceneTree
## The shooter's body at the table (06 P33 U1, 08 §2.7): in CUE the camera is pinned behind the ball but the body stands outside the
## table's outline and holds the real stick.
##   - a grid of balls on the cloth x 8 aim yaws: no part of the lower body is inside the table's footprint (pelvis axis clear by
##     BODY_R_M + CLEAR_M, hips / legs / feet / trunk base clear wherever they are below the rail top), and wherever the solver says an
##     arm reaches the stick, the hand the skeleton ends up with is within 5 cm of it
##   - the local player's real CUE path (enter_cue -> CueController frames -> Player.pose_body) and a remote puppet's pose end the same way
##   - the SIT stance puts the hip on the seat, thighs level, shins hanging
##   godot --path . --headless -s tests/player/cue_stance_probe.gd
## Prints CUESTANCE OK, or the failing checks and CUESTANCE FAIL (exit 1).

const HAND_TOL_M := 0.05
const YAWS := 8
const GRID_X: Array[float] = [-2.3, -1.15, 0.0, 1.15, 2.3]
const GRID_Z: Array[float] = [-1.05, -0.5, 0.0, 0.5, 1.05]
const MIN_REACHED := 0.2  ## share of the grid at which both hands hold the stick (the table is wider than an arm: a wide ball is out of reach)

var fails := 0
var finished := false
var table: Table


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("CUESTANCE FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _until(cond: Callable, sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			return false
		await process_frame
	return true


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_cue_stance"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	table = level.get_node("Table")
	var h := Humanoid.new()
	root.add_child(h)
	h.stance = Humanoid.Stance.CUE
	await process_frame
	_stick_length(level)
	_grid(h)
	_sit(h)
	h.queue_free()
	await _puppet(level)
	await _local(level)
	finished = true
	print("CUESTANCE OK" if fails == 0 else "CUESTANCE FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


## The puppet's stick and the local one are the same length (the puppet has no mesh to ask).
func _stick_length(level: Node) -> void:
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	_check(is_equal_approx((player.cue.cue_mesh.mesh as CylinderMesh).height, CueController.CUE_LEN_M) and is_equal_approx(player.cue._cue_len, CueController.CUE_LEN_M),
		"CueController.CUE_LEN_M equals the stick mesh's height")


func _dist_to_stick(p: Vector3, tip: Vector3, butt: Vector3) -> float:
	var s := clampf((p - tip).dot(butt), 0.0, CueController.CUE_LEN_M)
	return p.distance_to(tip + butt * s)


## Every sampled point of the legs, hips and trunk base that is below the rail top must be outside the footprint.
func _lower_body_points(h: Humanoid) -> Array[Vector3]:
	var pts: Array[Vector3] = []
	for sx in [-0.155, 0.155]:
		for sz in [-0.10, 0.10]:
			pts.append(h.bone_point(Humanoid.B.PELVIS, Vector3(sx, -0.07, sz)))
			pts.append(h.bone_point(Humanoid.B.PELVIS, Vector3(sx, 0.10, sz)))
			pts.append(h.bone_point(Humanoid.B.TORSO, Vector3(sx * 1.3, 0.0, sz * 1.1)))
	for pair in [[Humanoid.B.THIGH_R, Humanoid.B.SHIN_R], [Humanoid.B.THIGH_L, Humanoid.B.SHIN_L]]:
		pts.append(h.bone_point(pair[0]))
		pts.append(h.bone_point(pair[1]))
		pts.append(h.bone_point(pair[1], Vector3(0.0, -0.42, 0.0)))
		for sx in [-0.06, 0.06]:
			pts.append(h.bone_point(pair[1], Vector3(sx, -0.50, -0.17)))  # the toes
			pts.append(h.bone_point(pair[1], Vector3(sx, -0.50, 0.04)))   # the heels
	return pts


func _grid(h: Humanoid) -> void:
	var spec := table.spec
	var ball_y := spec.bed_height_m + spec.ball_radius_m
	var rail_top := table.global_position.y + spec.bed_height_m + spec.rail_height_m
	var half := CueStance.outline_half(spec)
	var inv := table.global_transform.affine_inverse()
	var samples := 0
	var both := 0
	var solid_hits := 0
	var axis_hits := 0
	var hand_bad := 0
	var nan_poses := 0
	var worst_hand := 0.0
	var worst_axis := 9.0
	for gx in GRID_X:
		for gz in GRID_Z:
			for k in YAWS:
				var yaw := TAU * k / YAWS
				var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
				var ball := table.to_global(Vector3(gx, ball_y, gz))
				var feet := CueStance.feet_for(table, ball, fwd, 0.0)
				var tip := ball - fwd * (spec.ball_radius_m + CueController.CUE_GAP_M)
				h.set_cue_rig(feet, yaw, tip, -fwd, CueController.CUE_LEN_M, CueController.BRIDGE_M)
				h.snap_pose()
				samples += 1
				if not (h.hand_world(0).is_finite() and h.hand_world(1).is_finite() and h.bone_point(Humanoid.B.HEAD).is_finite()):
					nan_poses += 1
					continue
				var pelvis := h.bone_point(Humanoid.B.PELVIS)
				var axis_gap := CueStance.outline_gap(inv * pelvis, half)
				worst_axis = minf(worst_axis, axis_gap)
				if axis_gap < CueStance.BODY_R_M + CueStance.CLEAR_M - 0.015:
					axis_hits += 1
				for p in _lower_body_points(h):
					if p.y <= rail_top + 0.005 and CueStance.outline_gap(inv * p, half) < CueStance.CLEAR_M * 0.6:  # the 0.3 m disc is a little short behind the heel
						solid_hits += 1
						break
				var reached := 0
				for side in 2:
					if h.rig_gap(side) < 0.0005:  # the solver says this arm reaches the stick: the skeleton must agree
						reached += 1
						var err := _dist_to_stick(h.hand_world(side), tip, -fwd)
						worst_hand = maxf(worst_hand, err)
						if err > HAND_TOL_M:
							hand_bad += 1
				both += 1 if reached == 2 else 0
	_check(nan_poses == 0, "no pose is non-finite (%d of %d)" % [nan_poses, samples])
	_check(axis_hits == 0, "the pelvis axis is %.2f m outside the footprint everywhere (worst %.3f m, %d samples short)" % [CueStance.BODY_R_M + CueStance.CLEAR_M, worst_axis, axis_hits])
	_check(solid_hits == 0, "no hip, leg or foot is inside the table's footprint: %d of %d samples" % [solid_hits, samples])
	_check(hand_bad == 0, "every arm the solver says reaches holds the stick within %d cm (worst %.1f cm, %d bad)" % [int(HAND_TOL_M * 100.0), worst_hand * 100.0, hand_bad])
	var share := float(both) / float(maxi(samples, 1))
	_check(share >= MIN_REACHED, "both hands hold the stick over %d%% of the grid (%.0f%%)" % [int(MIN_REACHED * 100.0), share * 100.0])
	print("cue_stance: %d samples, both hands on the stick in %.0f%%, worst hand %.1f cm, pelvis axis worst %.3f m outside" % [samples, share * 100.0, worst_hand * 100.0, worst_axis])


func _sit(h: Humanoid) -> void:
	h.clear_cue_rig()
	h.global_position = Vector3(2.0, 0.0, 3.0)
	for top in [Bar.STOOL_TOP, Bar.SOFA_TOP]:
		h.set_seat(top)
		h.stance = Humanoid.Stance.SIT
		h.snap_pose()
		var hip := h.bone_point(Humanoid.B.PELVIS)
		_check(absf(hip.y - Humanoid.sit_hip_y(top)) < 0.02, "SIT %.2f: the hip rides on the seat (%.3f vs %.3f)" % [top, hip.y, Humanoid.sit_hip_y(top)])
		var knee := h.bone_point(Humanoid.B.SHIN_R)
		_check(absf(knee.y - top) < 0.12 and knee.z < hip.z - 0.35, "SIT %.2f: the thigh is level and forward (knee y %.2f, %.2f m ahead)" % [top, knee.y, hip.z - knee.z])
		var ankle := h.bone_point(Humanoid.B.SHIN_R, Vector3(0.0, -0.42, 0.0))
		_check(knee.y - ankle.y > 0.35, "SIT %.2f: the shin hangs (%.2f m)" % [top, knee.y - ankle.y])
		var hand := h.hand_world(0)
		_check(absf(hand.y - (hip.y + 0.12)) < 0.1 and hand.z < hip.z - 0.15, "SIT %.2f: the hands rest on the thighs (%s)" % [top, hand])
	h.stance = Humanoid.Stance.STAND
	h.snap_pose()


## A remote shooter's pose (mode CUE at the pinned spot) puts a puppet on the rig: stick in the world and in the mirror, body outside the outline.
func _puppet(level: Node) -> void:
	var spec := table.spec
	var puppet := load("res://src/gameplay/player/Player.tscn").instantiate() as Player
	level.add_child(puppet)
	puppet.make_puppet("Remote", Player.skin_for_seat(1))
	var ball := table.to_global(Vector3(0.0, spec.bed_height_m + spec.ball_radius_m, 0.0))
	var at := Vector3(ball.x, 0.0, ball.z + CueController.BACK_M)  # aiming north (yaw 0): the shooter stands south of the ball
	var blob := PackedByteArray()
	blob.resize(Player.POSE_BYTES)
	blob.encode_float(0, at.x)
	blob.encode_float(4, at.y)
	blob.encode_float(8, at.z)
	blob.encode_u16(12, 0)
	blob.encode_u16(14, (Player.Mode.CUE << 14) | (Player.PITCH_MAX / 2))
	puppet.apply_pose(blob)
	await process_frame
	await process_frame
	var hum := puppet.humanoid
	_check(puppet._puppet_mode == Player.Mode.CUE and hum.stance == Humanoid.Stance.CUE and hum.has_cue_rig(), "puppet: mode CUE puts the body on the rig")
	_check(puppet._avatar_cue.visible and puppet._avatar_cue.top_level and (puppet._avatar_cue.layers & Humanoid.MIRROR_LAYER) != 0, "puppet: the stick is in the world and on the mirror layer")
	var tip := puppet._avatar_cue.global_position + puppet._avatar_cue.global_basis.y * (CueController.CUE_LEN_M * 0.5)
	var want := ball + Vector3(0.0, 0.0, spec.ball_radius_m + CueController.CUE_GAP_M)  # tip on the south face of the ball
	_check(tip.distance_to(want) < 0.01, "puppet: the stick's tip is on the ball (%s vs %s)" % [tip, want])
	var half := CueStance.outline_half(spec)
	var inv := table.global_transform.affine_inverse()
	_check(CueStance.outline_gap(inv * hum.bone_point(Humanoid.B.PELVIS), half) >= CueStance.BODY_R_M + CueStance.CLEAR_M - 0.015, "puppet: the body stands outside the table's outline")
	var butt := Vector3(0.0, 0.0, 1.0)
	for side in 2:
		if hum.rig_gap(side) < 0.0005:
			_check(_dist_to_stick(hum.hand_world(side), tip, butt) <= HAND_TOL_M, "puppet: hand %d on the stick" % side)
	_check(puppet._tag.global_position.distance_to(hum.bone_point(Humanoid.B.HEAD)) < 0.8 and puppet._tag.global_position.y > hum.bone_point(Humanoid.B.HEAD).y, "puppet: the name tag follows the head over the table")
	# back to WALK: the rig is off and the body hangs from the Player again
	blob.encode_u16(14, (Player.Mode.WALK << 14) | (Player.PITCH_MAX / 2))
	puppet.apply_pose(blob)
	await create_timer(0.5).timeout
	_check(puppet._puppet_mode == Player.Mode.WALK and not hum.has_cue_rig() and hum.transform == Transform3D.IDENTITY and not puppet._avatar_cue.visible, "puppet: WALK takes the rig off")
	puppet.queue_free()


## The local player's real path: enter_cue -> CueController frames -> pose_body. The camera stays pinned, the body does not.
func _local(level: Node) -> void:
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var rd: RoundDirector = level.get_node("RoundDirector")
	var loop: GameLoop = level.get_node("GameLoop")
	loop.advance()
	var me := root.multiplayer.get_unique_id()
	for i in 30:
		await process_frame
	_check(await _until(func() -> bool: return table.sim.awake == 0, 20.0), "the rack settles")
	var cue_ball: Ball
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue_ball = b
	rd.current_shooter_id = me
	player.global_position = Vector3(cue_ball.global_position.x, 0.0, cue_ball.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	await process_frame
	_check(player.enter_cue(), "the local player enters CUE")
	for i in 5:
		await process_frame
	var hum := player.humanoid
	var cue := player.cue
	_check(hum.has_cue_rig(), "local: the body is on the rig")
	var behind := Vector2(player.global_position.x - cue_ball.global_position.x, player.global_position.z - cue_ball.global_position.z).length()
	_check(absf(behind - CueController.BACK_M) < 0.01, "local: the camera is still pinned %.2f m behind the ball (%.3f)" % [CueController.BACK_M, behind])
	var spec := table.spec
	var inv := table.global_transform.affine_inverse()
	_check(CueStance.outline_gap(inv * hum.bone_point(Humanoid.B.PELVIS), CueStance.outline_half(spec)) >= CueStance.BODY_R_M + CueStance.CLEAR_M - 0.015, "local: the body stands outside the table's outline")
	for side in 2:
		if hum.rig_gap(side) < 0.0005:
			_check(_dist_to_stick(hum.hand_world(side), cue._tip, cue._butt) <= HAND_TOL_M, "local: hand %d on the real stick (%.1f cm)" % [side, _dist_to_stick(hum.hand_world(side), cue._tip, cue._butt) * 100.0])
	# power pulls the stick back through the bridge hand: the rear hand follows the butt, the bridge hand stays near its spot
	cue.power = 1.0
	cue.set_process(true)
	await process_frame
	await process_frame
	cue.power = 1.0
	for side in 2:
		if hum.rig_gap(side) < 0.0005:
			_check(_dist_to_stick(hum.hand_world(side), cue._tip, cue._butt) <= HAND_TOL_M, "local: full power, hand %d still on the stick" % side)
	_check(is_equal_approx(cue._bridge_s, CueController.BRIDGE_M + cue_ball.radius * CueController.PULLBACK_RADII), "the bridge hand's distance grows with the pull-back (%.3f)" % cue._bridge_s)
	cue.power = 0.0
	# elevation lifts the butt: hands follow it
	cue.set_elevation(40.0)
	await process_frame
	await process_frame
	for side in 2:
		if hum.rig_gap(side) < 0.0005:
			_check(_dist_to_stick(hum.hand_world(side), cue._tip, cue._butt) <= HAND_TOL_M, "local: 40 degrees up, hand %d still on the stick" % side)
	cue.set_elevation(0.0)
	player.exit_cue()
	await process_frame
	_check(not hum.has_cue_rig() and hum.transform == Transform3D.IDENTITY and player.mode == Player.Mode.WALK, "leaving CUE hangs the body from the Player again")
