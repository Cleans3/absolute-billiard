extends SceneTree
## The wall mirror (C14, 06 P26, adhoc-1012a), the parts that need no renderer: placement, the render layers (shell + table
## on the room capture, table + avatars + the local head on the window pass, balls on neither), the window camera's geometry, the
## gates (range, side, off screen), every-frame drawing, the cube face table vs the shader. The capture itself needs a
## window: src/tools/screenshot_mirror.gd.
##   godot --path . --headless -s tests/player/mirror_probe.gd
## Prints MIRROR OK, or the failing checks and MIRROR FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		if not finished:
			print("MIRROR FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


## The one place a probe waits for the level to be playable after pressing Solo: MainLevel loads on a thread
## behind the loading screen.
func _until_playable() -> void:
	await SoloSupport.until_playable(self)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_mirror"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await _until_playable()
	var level := current_scene
	level.get_node("GameLoop").advance()
	for i in 30:
		await process_frame
	var mirror := level.get_node_or_null("Mirror") as Mirror
	_check(mirror != null, "MainLevel has a Mirror")
	var cam: Camera3D = mirror.get_node("View/Cam")
	var view: SubViewport = mirror.get_node("View")
	_check(mirror.global_position.is_equal_approx(Vector3(-6.9, 1.4, -3.8)), "centred on the west wall at (-6.90, 1.4, -3.8): %s" % mirror.global_position)
	_check(mirror.global_basis.z.is_equal_approx(Vector3.RIGHT) and mirror.global_basis.y.is_equal_approx(Vector3.UP), "faces +x, upright")
	_check(view.size.y <= 384 and view.size == Mirror.VIEW_PX and _near(float(view.size.x) / view.size.y, Mirror.SIZE.x / Mirror.SIZE.y, 0.001), "sub viewport %s, <= 384 px tall, the glass's aspect" % view.size)
	_check(view.transparent_bg, "the window pass keeps a transparent background (the room capture shows through)")

	# render layers
	var geo_ok := true
	for mi: MeshInstance3D in level.get_node("BarRoom/Geometry").get_children():
		geo_ok = geo_ok and (mi.layers & Mirror.ROOM_LAYER) != 0 and (mi.layers & Mirror.LAYER) == 0 and (mi.layers & 1) != 0
	_check(geo_ok, "the room shell is on the room-capture layer only (and still layer 1)")
	var lm := level.get_node("BarRoom/Lightmap") as VisualInstance3D
	_check((lm.layers & Mirror.LAYER) != 0 and (lm.layers & Mirror.ROOM_LAYER) != 0, "the lightmap is on both mirror layers (a mask that misses it draws black)")
	var table_ok := false
	for mi: MeshInstance3D in level.get_node("Table").find_children("*", "MeshInstance3D", true, false):
		if not mi.get_parent() is RigidBody3D:
			table_ok = (mi.layers & Mirror.LAYER) != 0 and (mi.layers & Mirror.ROOM_LAYER) == 0
			if not table_ok:
				break
	_check(table_ok, "the table's meshes are on the window-pass layer only (too near the capture point to box-project)")
	var ball_hit := false
	for b: Ball in level.get_node("RoundDirector").get_balls():
		for mi: MeshInstance3D in b.find_children("*", "MeshInstance3D", true, false):
			ball_hit = ball_hit or (mi.layers & (Mirror.LAYER | Mirror.ROOM_LAYER)) != 0
	_check(not ball_hit, "balls are not drawn in the mirror")
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	var hum := player.humanoid
	_check((hum._body_mi.layers & Mirror.LAYER) != 0, "avatar body is on the mirror layer")
	_check(hum._head_mi.layers == Humanoid.HEAD_LAYER and (cam.cull_mask & Humanoid.HEAD_LAYER) != 0 and (player.cam.cull_mask & Humanoid.HEAD_LAYER) == 0,
		"the local head is on HEAD_LAYER: the mirror camera draws it, the player's own camera does not")
	_check(cam.cull_mask == (Mirror.LAYER | Humanoid.HEAD_LAYER), "the mirror camera draws the mirror layer and the head layer only")
	_check(level.get_node("Bar/Bartender/Humanoid")._body_mi.layers & Mirror.LAYER != 0, "the Bartender is in the mirror")

	# the reflected camera
	var eye := Vector3(-3.4, 1.6, -3.8)
	mirror.render_for(eye)
	await process_frame
	_check(cam.global_position.is_equal_approx(Vector3(-10.4, 1.6, -3.8)), "the eye is mirrored to the far side of the wall: %s" % cam.global_position)
	_check(cam.global_position.x < mirror.global_position.x, "the camera sits behind the glass plane")
	_check(_near(cam.near, eye.x - mirror.global_position.x), "near plane = the glass plane (distance %.2f)" % cam.near)
	var corners := {}
	for c: Vector2 in [Vector2(-1.8, 1.2), Vector2(1.8, -1.2)]:
		var p := mirror.global_position + mirror.global_basis.x * c.x + mirror.global_basis.y * c.y
		corners[c] = cam.unproject_position(p)
	var tl: Vector2 = corners[Vector2(-1.8, 1.2)]
	var br: Vector2 = corners[Vector2(1.8, -1.2)]
	_check(_near(tl.x, view.size.x, 1.0) and _near(tl.y, 0.0, 1.0) and _near(br.x, 0.0, 1.0) and _near(br.y, view.size.y, 1.0),
		"the glass fills the whole viewport (mirrored in x): %s %s" % [tl, br])
	# an eye off to the side and above: the glass still fills the view
	mirror.render_for(Vector3(-2.0, 2.4, -1.5))
	await process_frame
	tl = cam.unproject_position(mirror.global_position + mirror.global_basis.x * -1.8 + mirror.global_basis.y * 1.2)
	br = cam.unproject_position(mirror.global_position + mirror.global_basis.x * 1.8 + mirror.global_basis.y * -1.2)
	_check(_near(tl.x, view.size.x, 1.0) and _near(tl.y, 0.0, 1.0) and _near(br.x, 0.0, 1.0) and _near(br.y, view.size.y, 1.0),
		"...also for an eye off-axis: %s %s" % [tl, br])

	# gates, every-frame drawing, tier size
	_check(mirror.in_range(Vector3(-3.4, 1.6, -3.8)), "3.5 m in front: in range")
	_check(not mirror.in_range(Vector3(2.0, 1.6, -3.8)), "8.9 m away: out of range")
	_check(not mirror.in_range(Vector3(-7.5, 1.6, -3.8)), "behind the glass plane: no render")
	var drawn := 0
	var at := Vector3(-3.4, 1.6, -3.8)
	QualityManager.current_tier = 0
	for i in 120:
		drawn += 1 if mirror.tick(at) else 0
	_check(drawn == 120, "in range it draws every frame (a throttled reflection swims): %d/120" % drawn)
	_check(view.size == Mirror.VIEW_PX, "tier 0: full window size")
	QualityManager.current_tier = 2
	mirror.tick(at)
	_check(view.size == Mirror.VIEW_PX / 2, "tier 2 halves the window pass: %s" % view.size)
	QualityManager.current_tier = 0
	drawn = 0
	for i in 60:
		drawn += 1 if mirror.tick(Vector3(5.0, 1.6, -3.8)) else 0
		drawn += 1 if mirror.tick(Vector3.INF) else 0
	_check(drawn == 0 and view.render_target_update_mode == SubViewport.UPDATE_DISABLED, "out of range or off screen draws nothing")

	# cube faces: proper camera bases, and the shader's F/U arrays match Mirror.FACES
	var src: String = preload("res://src/shaders/mirror.gdshader").code
	var faces_ok := true
	var fs := PackedStringArray()
	var us := PackedStringArray()
	for face: Array in Mirror.FACES:
		var f: Vector3 = face[0]
		var u: Vector3 = face[1]
		var b := Basis(u.cross(-f), u, -f)
		faces_ok = faces_ok and b.is_conformal() and is_equal_approx(b.determinant(), 1.0)
		fs.append("vec3(%d, %d, %d)" % [f.x, f.y, f.z])
		us.append("vec3(%d, %d, %d)" % [u.x, u.y, u.z])
	_check(faces_ok, "every cube face is a right-handed orthonormal camera basis")
	_check(src.contains("const vec3 F[6] = { %s };" % ", ".join(fs)) and src.contains("const vec3 U[6] = { %s };" % ", ".join(us)),
		"mirror.gdshader's F/U face arrays match Mirror.FACES")
	_check(mirror.captures == 0, "headless: no capture attempted (needs a renderer)")
	finished = true
	print("MIRROR OK" if fails == 0 else "MIRROR FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)
