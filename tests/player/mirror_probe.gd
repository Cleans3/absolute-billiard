extends SceneTree
## The wall mirror (C14, 06 P26, adhoc-1012a, 06 P33 U2), the parts that need no renderer: placement, the render layers (shell +
## table on the room capture, table + avatars + the local head + the cue stick on the window pass, balls on neither), the window
## camera's geometry, the gates (side, off screen; no range cut-off), every-frame drawing, the window pass sized to the glass on
## screen per tier, the cube face sizes and mipmaps, set_blood, the cube face table vs the shader. The capture itself needs a
## window: src/tools/screenshot_mirror.gd.
##   godot --path . --headless -s tests/player/mirror_probe.gd
## Prints MIRROR OK, or the failing checks and MIRROR FAIL (exit 1).

const FOCAL := 1000.0  ## pixels per metre at 1 m from the eye: a 1080 px tall view at about 56 degrees

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
	_check(view.size.y >= Mirror.VIEW_MIN_H and _near(float(view.size.x) / view.size.y, Mirror.SIZE.x / Mirror.SIZE.y, 0.001), "sub viewport %s, the glass's aspect" % view.size)
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
	_check((player.cue.cue_mesh.layers & Mirror.LAYER) != 0 and (player.cue.cue_mesh.layers & 1) != 0, "the local cue stick is on the mirror layer and still layer 1 (06 P33 U1)")
	player.humanoid.set_body_hidden(true)
	_check((hum._body_mi.layers & (cam.cull_mask)) != 0 and (hum._body_mi.layers & player.cam.cull_mask) == 0, "CUE: the local body is out of the player's camera, in the mirror's")
	player.humanoid.set_body_hidden(false)

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

	# gates (06 P33 U2): no range cut-off. In front of the glass it always draws; behind it, or off screen, never
	var across := Vector3(6.5, 1.6, -3.8)  # the far wall, 13.4 m from the glass: the old 8 m range froze the avatars and the table here
	_check(mirror.in_front(Vector3(-3.4, 1.6, -3.8)), "3.5 m in front: draws")
	_check(mirror.in_front(across), "13.4 m in front, across the room: still draws")
	_check(not mirror.in_front(Vector3(-7.5, 1.6, -3.8)), "behind the glass plane: no render")
	var drawn := 0
	var at := Vector3(-3.4, 1.6, -3.8)
	QualityManager.current_tier = 0
	for i in 120:
		drawn += 1 if mirror.tick(at, FOCAL) else 0
	_check(drawn == 120, "in front it draws every frame (a throttled reflection swims): %d/120" % drawn)
	drawn = 0
	for i in 60:
		drawn += 1 if mirror.tick(across, FOCAL) else 0
	_check(drawn == 60 and view.render_target_update_mode == SubViewport.UPDATE_ONCE, "...from across the room too: %d/60" % drawn)
	drawn = 0
	for i in 60:
		drawn += 1 if mirror.tick(Vector3(-7.5, 1.6, -3.8), FOCAL) else 0
		drawn += 1 if mirror.tick(Vector3.INF, FOCAL) else 0
	_check(drawn == 0 and view.render_target_update_mode == SubViewport.UPDATE_DISABLED, "behind the glass or off screen draws nothing")

	# the window pass is sized to the glass on the viewer's screen (SIZE.y * focal / distance px, rounded up to a step), per tier
	QualityManager.current_tier = 0
	_check(mirror.window_height(0.5, FOCAL) == 1024 and mirror.window_height(2.0, FOCAL) == 1024, "close up the glass fills the screen: the tier's tallest (1024)")
	_check(mirror.window_height(4.0, FOCAL) == 640 and mirror.window_height(10.0, FOCAL) == 256, "4 m: 600 px -> 640; 10 m: 240 px -> 256")
	_check(mirror.window_height(40.0, FOCAL) == Mirror.VIEW_MIN_H, "far away: the floor, %d px" % Mirror.VIEW_MIN_H)
	_check(mirror.window_height(4.0, 0.0) == 1024, "no focal given: the tier's tallest")
	var steady := true
	var prev := 99999
	for d in [0.3, 0.8, 1.5, 3.0, 5.0, 8.0, 12.0, 20.0]:
		var h := mirror.window_height(d, FOCAL)
		steady = steady and h <= prev
		prev = h
	_check(steady, "never taller further away")
	QualityManager.current_tier = 1
	_check(mirror.window_height(0.5, FOCAL) == 768, "tier 1: at most 768")
	QualityManager.current_tier = 2
	_check(mirror.window_height(0.5, FOCAL) == 384, "tier 2: at most 384")
	QualityManager.current_tier = 0
	mirror.tick(Vector3(-3.4, 1.6, -3.8), FOCAL)  # 3.5 m from the glass plane: 686 px -> 704
	_check(view.size == Mirror.view_size(704), "3.5 m away the pass is 704 px tall: %s" % view.size)
	mirror.tick(Vector3(-2.9, 1.6, -3.8), FOCAL)  # 4.0 m: wants 640, one step under: kept (no resizing at a boundary)
	_check(view.size.y == 704, "one step smaller is not worth a resize: %s" % view.size)
	mirror.tick(across, FOCAL)
	_check(view.size.y == 192, "across the room it shrinks: %s" % view.size)
	mirror.tick(Vector3(-5.9, 1.6, -3.8), FOCAL)  # 1 m: the glass is wider than the screen
	_check(view.size == Mirror.view_size(1024), "1 m from the glass it grows to the tier's tallest, sharp: %s" % view.size)
	QualityManager.current_tier = 2
	mirror.tick(Vector3(-5.9, 1.6, -3.8), FOCAL)
	_check(view.size.y == 384, "tier 2 caps the pass at 384: %s" % view.size)
	QualityManager.current_tier = 0

	# the room cube: 1024 / 768 / 512 px faces, mipmapped (the shader samples them with filter_linear_mipmap)
	_check(Mirror.FACE_PX.size() == 3 and Mirror.FACE_PX[0] == 1024 and Mirror.FACE_PX[1] == 768 and Mirror.FACE_PX[2] == 512, "cube faces 1024 / 768 / 512 by tier: %s" % [Mirror.FACE_PX])
	_check(FileAccess.get_file_as_string("res://src/gameplay/bar/mirror.gd").contains("generate_mipmaps"), "each face gets its mipmaps")
	_check(preload("res://src/shaders/mirror.gdshader").code.contains("filter_linear_mipmap"), "the shader samples the cube with mipmaps")

	# blood (06 P33 U2, for the failure cutscene): 0..1, a shader uniform, clamped, local
	_check(mirror.blood == 0.0, "clean glass at start")
	mirror.set_blood(0.5)
	_check(_near(mirror.blood, 0.5) and _near(float(mirror._mat.get_shader_parameter(&"blood")), 0.5), "set_blood(0.5) reaches the shader")
	mirror.set_blood(7.0)
	_check(mirror.blood == 1.0 and float(mirror._mat.get_shader_parameter(&"blood")) == 1.0, "clamped to 1")
	mirror.set_blood(-3.0)
	_check(mirror.blood == 0.0, "clamped to 0")
	_check(preload("res://src/shaders/mirror.gdshader").code.contains("uniform float blood"), "the shader has the blood uniform")

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
