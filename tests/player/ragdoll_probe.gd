extends SceneTree
## Humanoid + triggered ragdoll (docs/plan/08 §2.7, 06 P15): body budget, idle bones, limp physics with joint
## limits, get-up blend, Player.knock (input ignored, camera on the head bone, CUE/CARRY left, stands at the pelvis),
## pose mode 3, the host/owner triggers (spawner knock, blast radius, thrown drink, hard landing).
##   godot --path . --headless -s tests/player/ragdoll_probe.gd
## Prints RAGDOLL OK, or the failing checks and RAGDOLL FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(150.0).timeout.connect(func() -> void:
		if not finished:
			print("RAGDOLL FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _until(cond: Callable, sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			return false
	return true


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _run() -> void:
	await process_frame
	await _humanoid()
	await _player()
	finished = true
	print("RAGDOLL OK" if fails == 0 else "RAGDOLL FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


# --- the body ------------------------------------------------------------------------------------------

func _angle_x(h: Humanoid, parent: int, child: int) -> float:
	var rel := h.bone_world(parent).basis.inverse() * h.bone_world(child).basis
	return atan2(rel.y.z, rel.y.y)


func _humanoid() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 8
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30, 1, 30)
	cs.shape = box
	cs.position.y = -0.5
	floor_body.add_child(cs)
	root.add_child(floor_body)
	var h := Humanoid.new()
	root.add_child(h)
	await process_frame
	var skel: Skeleton3D = h.get_node("Skeleton")
	# budget: 11 bones, 11 bodies, two skinned meshes sharing one material, one surface each
	_check(skel.get_bone_count() == 11 and h._pbs.size() <= 11, "11 bones / ≤ 11 physical bodies (%d)" % h._pbs.size())
	var meshes: Array[MeshInstance3D] = []
	for c in skel.get_children():
		if c is MeshInstance3D:
			meshes.append(c)
	_check(meshes.size() == 2, "two mesh instances = two draw calls (%d)" % meshes.size())
	_check(meshes.all(func(m: MeshInstance3D) -> bool: return m.mesh.get_surface_count() == 1 and m.skin != null and m.get_node_or_null(m.skeleton) == skel), "one skinned surface each")
	_check(meshes[0].material_override == meshes[1].material_override, "one shared material")
	# idle: nothing simulates and the bodies are out of the physics world's way
	_check(not h.is_ragdoll() and not h._sim.is_simulating_physics(), "idle: not simulating")
	var idle_ok := true
	for pb in h._pbs:
		idle_ok = idle_ok and PhysicsServer3D.body_get_collision_layer(pb.get_rid()) == 0 and PhysicsServer3D.body_get_collision_mask(pb.get_rid()) == 0
	_check(idle_ok, "idle: every physical bone is on no layer and sees no mask")
	# every hat builds
	var base: int = (meshes[1].mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	for hat: StringName in [&"cap", &"tophat", &"beanie", &"crown"]:
		var sk := CharacterSkin.new()
		sk.hat = hat
		h.apply_skin(sk)
		_check((meshes[1].mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() > base - 1 and meshes[1].get_aabb().size.y > 0.2, "hat %s builds" % hat)
	h.apply_skin(CharacterSkin.new())
	# stances move the bones
	var torso0 := skel.get_bone_pose_rotation(Humanoid.B.TORSO)
	h.stance = Humanoid.Stance.CUE
	await _wait(0.4)
	_check(skel.get_bone_pose_rotation(Humanoid.B.TORSO).angle_to(torso0) > 0.4, "CUE leans the torso")
	h.stance = Humanoid.Stance.STAND
	await _wait(0.4)
	# limp: thrown hard, spinning; joints hold, hinges fold the right way, it settles on the floor
	h.position = Vector3(0, 0, 0)
	var got := [0]
	h.got_up.connect(func() -> void: got[0] += 1)
	h.ragdoll(Vector3(4.0, 3.0, 1.0))
	_check(h.is_ragdoll() and h._sim.is_simulating_physics(), "ragdoll(): simulating")
	_check(h._pbs.all(func(pb: PhysicalBone3D) -> bool: return PhysicsServer3D.body_get_collision_layer(pb.get_rid()) == Humanoid.RAG_LAYER and PhysicsServer3D.body_get_mode(pb.get_rid()) == PhysicsServer3D.BODY_MODE_RIGID), "limp: rigid bodies on the ragdoll layer")
	var worst_gap := 0.0
	var knee_lo := 9.0
	var knee_hi := -9.0
	var elbow_lo := 9.0
	var elbow_hi := -9.0
	for i in 150:
		await physics_frame
		if i % 5 == 0:
			for b in range(1, 11):
				var p := Humanoid.PARENT[b]
				var want := h.bone_world(p) * Transform3D(Basis.IDENTITY, Humanoid.ORIGIN[b] - Humanoid.ORIGIN[p])
				worst_gap = maxf(worst_gap, want.origin.distance_to(h.bone_world(b).origin))
			for k in [[Humanoid.B.THIGH_R, Humanoid.B.SHIN_R], [Humanoid.B.THIGH_L, Humanoid.B.SHIN_L]]:
				var a := _angle_x(h, k[0], k[1])
				knee_lo = minf(knee_lo, a)
				knee_hi = maxf(knee_hi, a)
			for k in [[Humanoid.B.UARM_R, Humanoid.B.LARM_R], [Humanoid.B.UARM_L, Humanoid.B.LARM_L]]:
				var a := _angle_x(h, k[0], k[1])
				elbow_lo = minf(elbow_lo, a)
				elbow_hi = maxf(elbow_hi, a)
	_check(worst_gap < 0.08, "joints stay together (worst gap %.3f m)" % worst_gap)
	_check(knee_hi < 0.25 and knee_lo > -2.6, "knees only fold backward (%.2f .. %.2f rad)" % [knee_lo, knee_hi])
	_check(elbow_lo > -0.25 and elbow_hi < 2.7, "elbows only fold forward (%.2f .. %.2f rad)" % [elbow_lo, elbow_hi])
	var pelvis := h.pelvis_position()
	_check(pelvis.is_finite() and pelvis.x > 1.0 and pelvis.y < 0.45, "thrown along the impulse and down on the floor: %s" % pelvis)
	h.ragdoll(Vector3(0, 2, 0))  # a second hit while limp is just another shove
	_check(h.is_ragdoll(), "still limp after a second shove")
	await _wait(0.2)
	h.get_up()
	_check(not h.is_ragdoll() and not h._sim.is_simulating_physics() and got[0] == 1, "get_up(): stopped, got_up once")
	_check(h.pelvis_at_getup.distance_to(pelvis) < 1.5, "pelvis_at_getup is where it lay")
	h.global_position = Vector3(h.pelvis_at_getup.x, 0.0, h.pelvis_at_getup.z)
	await _wait(0.7)
	_check(absf(skel.global_transform.origin.y) < 0.01 and (skel.get_bone_global_pose(Humanoid.B.HEAD).origin.y - 1.48) < 0.05, "blended back to standing")
	h.queue_free()
	floor_body.queue_free()
	await process_frame


# --- the player ----------------------------------------------------------------------------------------

## The one place a probe waits for the level to be playable after pressing Solo (alpha swaps the body for
## `await SoloSupport.until_playable(self)` once the threaded loading screen lands).
func _until_playable() -> void:
	for i in 8:
		await process_frame


func _player() -> void:
	SaveManager.root = "user://test_ragdoll"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	var level := current_scene
	var rd: RoundDirector = level.get_node("RoundDirector")
	var spawner := level.get_node("PlayerSpawner")  # untyped: a -s probe compiles before the NetManager autoload exists
	var player := spawner.get_local_player() as Player
	var controls: TouchControls = level.get_node("UILayer/TouchControls")
	controls.touch = true
	var me := root.multiplayer.get_unique_id()
	var hum := player.humanoid
	level.get_node("GameLoop").advance()
	for i in 30:
		await process_frame
	await _wait(2.0)
	_check(player.humanoid != null and not player.is_ragdoll(), "the local player wears a Humanoid")
	_check(hum._head_mi.layers == Humanoid.HEAD_LAYER and (player.cam.cull_mask & Humanoid.HEAD_LAYER) == 0, "first person: head on its own layer, hidden from the camera")
	# C17: the local camera renders torso, arms and legs, never the head; the head still casts its shadow
	var arm_bones := [Humanoid.B.UARM_R, Humanoid.B.LARM_R, Humanoid.B.UARM_L, Humanoid.B.LARM_L]
	var leg_bones := [Humanoid.B.THIGH_R, Humanoid.B.SHIN_R, Humanoid.B.THIGH_L, Humanoid.B.SHIN_L]
	var arm_seen := false
	var legs_seen := false
	var head_seen := false
	var head_shadow := false
	var lid_seen := false
	for mi: MeshInstance3D in [hum._body_mi, hum._head_mi]:
		var shown := (mi.layers & player.cam.cull_mask) != 0 and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		var casts := mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and (mi.layers & 0xFFFFF) != 0
		var arrays := (mi.mesh as ArrayMesh).surface_get_arrays(0)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for v in verts.size():
			var b := bones[v * 4]
			if b in arm_bones:
				arm_seen = arm_seen or shown
			elif b in leg_bones:
				legs_seen = legs_seen or shown
			elif b == Humanoid.B.HEAD:
				head_seen = head_seen or shown
				head_shadow = head_shadow or casts
			elif b == Humanoid.B.TORSO and verts[v].y > 1.49 and normals[v].y > 0.9:
				lid_seen = lid_seen or shown
	_check(arm_seen, "arms are visible to the local camera's cull mask (C17)")
	_check(legs_seen, "legs and feet stay visible to the local camera")
	_check(lid_seen, "the trunk is closed at the top by a lid the local camera renders (no looking inside)")
	_check(not head_seen and head_shadow, "the head and hat are hidden from the local camera but still cast shadows")
	var bartender := level.get_node_or_null("Bar/Bartender") as Bartender
	_check(bartender != null and absf(bartender.global_position.x - 6.0) < 0.01 and absf(bartender.global_position.z - 2.5) < 0.01, "Bar/Bartender stands at (6, 0, 2.5)")
	_check(bartender != null and bartender.global_basis.z.is_equal_approx(Vector3.RIGHT), "...facing -X")

	# a plain knock: input is ignored, the camera rides the head, the pose carries mode 3
	player.global_position = Vector3(-3.0, 0.05, 3.0)
	player.rotation.y = 0.0
	await _wait(0.3)
	var start := player.global_position
	player.knock(Vector3(2.0, 1.0, 0.0), 1.2)
	await process_frame
	_check(player.is_ragdoll() and player.mode == Player.Mode.RAGDOLL, "knock: limp, mode RAGDOLL")
	Input.action_press(&"move_forward")
	var yaw := player.rotation.y
	player.look(0.5, 0.0)
	await _wait(0.4)
	Input.action_release(&"move_forward")
	_check(player.rotation.y == yaw and start.distance_to(player.global_position) < 0.01, "input ignored while limp")
	_check(player.cam.top_level and player.cam.global_position.distance_to(hum.eye_transform().origin) < 0.4, "camera rides the head bone (%.2f m off)" % player.cam.global_position.distance_to(hum.eye_transform().origin))
	var blob := player.pack_pose()
	var lying := hum.pelvis_position()
	_check((blob.decode_u16(14) >> 14) == 3 and absf(blob.decode_float(0) - lying.x) < 0.001 and absf(blob.decode_float(8) - lying.z) < 0.001, "pose: mode 3 at the pelvis")
	var up := [false]
	player.got_up.connect(func() -> void: up[0] = true, CONNECT_ONE_SHOT)
	_check(await _until(func() -> bool: return up[0], 4.0), "got_up after the duration")
	_check(player.mode == Player.Mode.WALK and not player.is_ragdoll(), "stands: mode WALK")
	var at := hum.pelvis_at_getup
	_check(Vector2(player.global_position.x - at.x, player.global_position.z - at.z).length() <= 0.2, "capsule at the pelvis XZ (%s vs %s)" % [player.global_position, at])
	await _wait(0.7)
	_check(not player.cam.top_level and player.cam.global_position.distance_to(player.head.global_position) < 0.01, "camera back on Head")
	await physics_frame
	var moved := player.global_position
	Input.action_press(&"move_forward")
	await _wait(0.4)
	Input.action_release(&"move_forward")
	_check(moved.distance_to(player.global_position) > 0.3, "input is back")

	# the host entry broadcasts to every peer, this one included; a second shove while limp extends it
	spawner.knock(me, Vector3(0.0, 1.0, 2.0), 0.6)
	await _wait(0.2)
	_check(player.is_ragdoll(), "PlayerSpawner.knock ragdolls the peer")
	await _until(func() -> bool: return not player.is_ragdoll(), 4.0)
	_check(not player.is_ragdoll() and player.mode == Player.Mode.WALK, "...and it stands again")

	# CUE is left cleanly (position restored), and the strike path is not poisoned
	var cue_ball: Ball
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue_ball = b
	await _until(func() -> bool: return level.get_node("Table").sim.awake == 0, 10.0)
	player.global_position = Vector3(cue_ball.global_position.x, 0.0, cue_ball.global_position.z + 2.5)
	player.velocity = Vector3.ZERO
	rd.current_shooter_id = me
	await _wait(0.3)
	_check(player.enter_cue() and player.mode == Player.Mode.CUE, "entered CUE")
	_check(hum._body_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, "CUE: the local body is shadow-only, out of the aiming view")
	player.knock(Vector3(1.0, 1.0, 0.0), 0.5)
	await process_frame
	_check(player.mode == Player.Mode.RAGDOLL and not player.cue.active, "knocked out of CUE")
	_check(hum._body_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "limp: the body shows again")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 4.0)
	_check(player.mode == Player.Mode.WALK and not player.cue.active, "back in WALK, not CUE")

	# CARRY is left too (the rig is asked down at the feet through the usual path)
	var cams: CameraRigs = level.get_node("Cameras")
	var rig := cams.rigs[0]
	player.global_position = rig.global_position + Vector3(-0.1, 0.05, -0.4)
	await _wait(0.3)
	var world: WorldInteractions = level.get_node("WorldInteractions")
	var fake_ms := [Time.get_ticks_msec()]
	world.clock = func() -> int: return fake_ms[0]
	player.interact()
	await _wait(0.2)
	_check(player.mode == Player.Mode.CARRY, "grabbed a rig: CARRY")
	fake_ms[0] += 6000  # past the grab's cooldown, so the host accepts the put-down
	player.knock(Vector3(0.0, 1.0, 1.0), 0.5)
	await process_frame
	_check(player.mode == Player.Mode.RAGDOLL, "knocked out of CARRY")
	await _wait(0.5)
	_check(rig.held_by == 0, "the carried rig was put down")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 4.0)
	_check(player.mode == Player.Mode.WALK, "stands after the carry knock")

	# triggers: a blast knocks only inside BLAST_RADIUS_M
	player.global_position = Vector3(-3.0, 0.05, 3.0)
	await _wait(0.3)
	spawner.knock_blast(player.global_position + Vector3(spawner.BLAST_RADIUS_M + 0.5, 0.0, 0.0))
	await _wait(0.2)
	_check(not player.is_ragdoll(), "a blast outside the radius leaves the player standing")
	spawner.knock_blast(player.global_position + Vector3(spawner.BLAST_RADIUS_M - 0.5, 0.0, 0.0))
	await _wait(0.2)
	_check(player.is_ragdoll(), "a blast inside the radius knocks the player down")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 5.0)
	# the real bomb path: a detonating ball (set down beside the player) knocks them through RoundDirector
	var bomb: Ball
	for b in rd.get_balls():
		if not b.is_cue_ball and not b.is_pocketed and not b.retired:
			bomb = b
	player.global_position = Vector3(-3.0, 0.05, 3.0)
	await _wait(0.3)
	bomb.global_position = player.global_position + Vector3(1.0, 0.9, 0.0)
	rd.shot_in_progress = true
	rd._detonate(bomb)
	rd.shot_in_progress = false
	await _wait(0.2)
	_check(player.is_ragdoll(), "a detonating bomb ball knocks the player within its blast")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 5.0)
	# the stumble stat: a Mystery debuff trips its drinker (a huge dt makes the Poisson roll certain)
	spawner._process(1000.0)
	await _wait(0.2)
	_check(not player.is_ragdoll(), "no stumble without the stat")
	var fx: EffectManager = level.get_node("EffectManager")
	fx.apply(&"static_stumble", me, me)
	await _wait(0.2)
	spawner._process(1000.0)
	await _wait(0.2)
	_check(player.is_ragdoll(), "player_stumble_per_min knocks its peer down")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 5.0)
	# a thrown drink: the shooter goes down, the thrower does not
	rd.current_shooter_id = me
	world._soak_shooter(me)
	await _wait(0.2)
	_check(not player.is_ragdoll(), "nobody soaks themselves")
	world._soak_shooter(me + 1)
	await _wait(0.2)
	_check(player.is_ragdoll(), "a drink thrown by someone else knocks the shooter")
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 5.0)
	# a hard landing (owner side)
	player.global_position = Vector3(-3.0, 0.6, 3.0)  # the room is too low to fall 7 m/s in: launch the player at the floor
	player.velocity = Vector3(0.0, -9.0, 0.0)
	var fell := await _until(func() -> bool: return player.is_ragdoll(), 3.0)
	_check(fell, "falling faster than %.0f m/s knocks the player down on landing" % Player.HARD_LAND_MPS)
	await _until(func() -> bool: return player.mode == Player.Mode.WALK, 5.0)
	player.global_position = Vector3(-3.0, 0.4, 3.0)  # a small hop does not
	player.velocity = Vector3.ZERO
	await _wait(0.6)
	_check(not player.is_ragdoll(), "a short fall does not")

	# a remote puppet: mode 3 in the stream ragdolls it, mode 0 stands it
	var puppet_player := load("res://src/gameplay/player/Player.tscn").instantiate() as Player
	root.add_child(puppet_player)
	puppet_player.make_puppet("Remote", Player.skin_for_seat(1))
	puppet_player.global_position = Vector3(2.0, 0.0, 3.0)
	var pose := player.pack_pose().duplicate()
	pose.encode_u16(14, (3 << 14) | 8191)
	puppet_player.apply_pose(pose)
	await _wait(0.4)
	_check(puppet_player.is_ragdoll(), "puppet goes limp on pose mode 3")
	var stood := PackedByteArray(pose)
	stood.encode_u16(14, 8191)
	stood.encode_float(0, 5.0)
	stood.encode_float(8, 1.0)
	puppet_player.apply_pose(stood)
	_check(await _until(func() -> bool: return not puppet_player.is_ragdoll(), 4.0), "...and stands when the stream says so")
	_check(puppet_player.global_position.distance_to(Vector3(5.0, puppet_player.global_position.y, 1.0)) < 0.5, "resynced to the owner's pose: %s" % puppet_player.global_position)
	puppet_player.queue_free()

