extends SceneTree
## The wall TV and its two feeds (docs/plan/02 §3.2, 07 §2, 06 P33 U5, adhoc-1013c W4), the parts that need no renderer: placement and
## size against the south wall's decor, render layers (the frame on the mirror's room layer, the glass on no feed's mask, HEAD_LAYER in,
## ShotGuide's layer 12 out, the lamp out of the ceiling feed only), the feed cameras (the tripod follows its rig, the ceiling one looks
## down with the fitted fov), the draw gates (off screen, switched off, between periods), alternation and rates per quality tier, feed
## sizes, `set_feeds_on`, and a shader with no noise. The pictures themselves need a window: src/tools/screenshot_tv.gd.
##   godot --path . --headless -s tests/world/tv_probe.gd
## Prints TV OK, or the failing checks and TV FAIL (exit 1).

var fails := 0
var finished := false


func _init() -> void:
	create_timer(60.0).timeout.connect(func() -> void:
		if not finished:
			print("TV FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


## `n` frames of `delta` seconds with the TV in view (or not); returns the feed drawn per frame.
func _ticks(tv: StreamTv, n: int, on_screen: bool, delta := 1.0 / 60.0) -> Array[int]:
	var out: Array[int] = []
	for i in n:
		out.append(tv.tick(delta, on_screen))
	return out


func _count(a: Array[int], v: int) -> int:
	return a.count(v)


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_tv"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	var level := current_scene
	for i in 10:
		await process_frame
	var tv := level.get_node_or_null("Tv") as StreamTv
	_check(tv != null, "MainLevel has a Tv (a StreamTv)")
	var cams: CameraRigs = level.get_node("Cameras")
	tv.set_process(false)  # the probe drives `tick` itself; headless has no camera, so the notifier would say "off screen" anyway

	# --- placement: the south wall, wider than the old 2.5 m frame, clear of the wall's decor ---
	_check(tv.global_position.is_equal_approx(Vector3(0.0, 2.1, DecorPlan.HALF)), "on the south wall plane, centred, at y 2.1: %s" % tv.global_position)
	_check(tv.global_basis.z.is_equal_approx(Vector3.FORWARD), "faces into the room (local +Z = world -Z)")
	_check(StreamTv.FRAME.x > 2.5 and StreamTv.FRAME.x <= 4.2, "wider than the old 2.5 m frame, fits the wall zone: %s" % StreamTv.FRAME)
	_check(StreamTv.FRAME.y <= 1.6, "no taller than the wall zone: %s" % StreamTv.FRAME.y)
	_check(_near(StreamTv.HALF_ASPECT, StreamTv.SCREEN.x * 0.5 / StreamTv.SCREEN.y, 1e-6) and _near(StreamTv.HALF_ASPECT, 1.5, 0.01), "each half is 3:2 (the feed aspect, no crop): %.3f" % StreamTv.HALF_ASPECT)
	var frame_rect := Rect2(tv.global_position.x - StreamTv.FRAME.x * 0.5, tv.global_position.y - StreamTv.FRAME.y * 0.5, StreamTv.FRAME.x, StreamTv.FRAME.y)
	var zone: Rect2 = DecorPlan.wall_keep_clear()[&"S"][0]
	_check(zone.encloses(frame_rect), "DecorPlan's south keep-clear rect %s holds the TV frame %s" % [zone, frame_rect])
	var posters_ok := true
	for p: Array in DecorPlan.POSTERS:
		if p[4] == &"S":
			var w: float = p[7]
			var h: float = w * DecorPlan.CELL.y / (DecorPlan.CELL.x * p[3])
			var r := Rect2(p[5] - w * 0.5 - 0.05, p[6] - h * 0.5 - 0.05, w + 0.1, h + 0.1)  # the print and its frame
			posters_ok = posters_ok and not r.intersects(frame_rect)
	_check(posters_ok, "no south-wall poster (frame included) touches the TV frame")
	var under_ok := true
	for it: Array in DecorPlan.ITEMS:
		var at: Vector3 = it[3]
		if at.z > 6.0 and absf(at.x) < StreamTv.FRAME.x * 0.5 + 0.4 and it[5] == &"floor":
			under_ok = under_ok and (it[0] == &"speaker_l" or it[0] == &"speaker_r")  # the only floor items under the TV; 1.27 m tall, the frame starts at 1.36
	_check(under_ok, "nothing but the two speakers stands under the TV")

	# --- layers ---
	var frame := tv.get_node("Frame") as MeshInstance3D
	var screen := tv.get_node("Screen") as MeshInstance3D
	_check((frame.layers & Mirror.ROOM_LAYER) != 0 and (frame.layers & 1) != 0, "the frame is on layer 1 and the mirror's room layer (the cube keeps a TV on the wall)")
	_check(screen.layers == (StreamTv.SCREEN_LAYER | Mirror.ROOM_LAYER) and (screen.layers & 1) == 0, "the glass is on its own layer + the room layer, not layer 1")
	for i in 2:
		var mask := StreamTv.feed_mask(i)
		var cam := tv.get_node("Feed%s/Cam" % ("A" if i == 0 else "B")) as Camera3D
		_check(cam.cull_mask == mask, "feed %d camera uses feed_mask(%d)" % [i, i])
		_check((mask & Humanoid.HEAD_LAYER) != 0 and (mask & Humanoid.MIRROR_LAYER) != 0 and (mask & 1) != 0, "feed %d draws layer 1, the mirror layer and HEAD_LAYER (the shooter shows)" % i)
		_check((mask & ShotGuide.LAYER) == 0, "feed %d does not draw the shot guide (layer 12)" % i)
		_check((mask & StreamTv.SCREEN_LAYER) == 0 and (mask & Mirror.ROOM_LAYER) == 0, "feed %d does not draw the TV glass (no feedback) nor the room-capture layer" % i)
	_check((StreamTv.feed_mask(0) & CeilingCam.LAMP_LAYER) != 0 and (StreamTv.feed_mask(1) & CeilingCam.LAMP_LAYER) == 0, "the lamp's layer is in the tripod feed and out of the ceiling feed only")
	var player := level.get_node("PlayerSpawner").get_local_player() as Player
	_check((player.cam.cull_mask & ShotGuide.LAYER) != 0 and (player.cam.cull_mask & CeilingCam.LAMP_LAYER) != 0 and (player.cam.cull_mask & StreamTv.SCREEN_LAYER) != 0,
		"the player's own camera still sees the guide, the lamp and the TV glass")
	for l: Label3D in tv.find_children("Live*", "Label3D", false, false):
		_check(l.layers == StreamTv.SCREEN_LAYER and l.text.begins_with("LIVE"), "%s is a LIVE bug on the glass layer" % l.name)
	var lamp := level.get_node_or_null("BarRoom/Lamp") as MeshInstance3D
	if lamp != null:
		_check((lamp.layers & CeilingCam.LAMP_LAYER) != 0 and (lamp.layers & 1) == 0 and (lamp.layers & Mirror.ROOM_LAYER) != 0 and lamp.get_parent() == level.get_node("BarRoom"),
			"the baked room has the lamp on its own layer (+ the mirror's room layer), not in Geometry")
		_check(lamp.gi_mode == GeometryInstance3D.GI_MODE_STATIC, "...and still baked into the lightmap")
	else:
		print("NOTE: BarRoom has no Lamp node yet - the room is rebuilt by W5 (build_bar_room.gd); the builder source is checked instead")
	var builder := FileAccess.get_file_as_string("res://src/tools/build_bar_room.gd")
	_check(builder.contains("lamp_mi.layers = CeilingCam.LAMP_LAYER") and builder.contains("_lamp(s_lamp)"), "the room builder puts the lamp on its own mesh and layer")
	_check(not builder.contains("tv_screen") and not builder.contains("TV frame (south wall)") and not builder.contains("s_tv"), "the room builder no longer bakes a TV quad or frame")
	var screens := level.get_node_or_null("BarRoom/Geometry/Screens") as MeshInstance3D
	if screens != null and screens.mesh.get_surface_count() != 1:
		print("NOTE: the baked room still carries the old TV quad (Screens has %d surfaces) - W5's rebuild removes it" % screens.mesh.get_surface_count())

	# --- feed cameras ---
	QualityManager.current_tier = 0
	tv.apply_tier(0)
	tv.set_feeds_on(true)
	var rig := cams.rigs[0]
	rig.global_position = Vector3(1.0, 0.0, -6.0)
	rig.rotation.y = PI
	tv._accum = 1.0
	tv._next = 0
	_check(tv.tick(0.0, true) == 0, "the first feed drawn is the tripod's")
	var cam_a := tv.get_node("FeedA/Cam") as Camera3D
	var cam_b := tv.get_node("FeedB/Cam") as Camera3D
	_check(cam_a.global_transform.is_equal_approx(rig.feed_transform()) and _near(cam_a.fov, CameraRig.FEED_FOV), "the tripod feed camera sits on the rig's lens")
	_check((cam_a.global_position - rig.eye()).dot(rig.forward()) > 0.3, "...in front of the glass, so the body never fills the picture")
	rig.global_position = Vector3(-2.0, 0.0, -1.0)  # carried: the rig follows its holder
	tv._accum = 1.0
	tv.tick(0.0, true)  # the ceiling feed's turn
	tv._accum = 1.0
	tv.tick(0.0, true)
	_check(cam_a.global_transform.is_equal_approx(rig.feed_transform()), "a carried rig's picture follows it")
	var pod := cams.ceiling
	_check(cam_b.global_position.is_equal_approx(pod.eye()) and cam_b.global_basis.is_equal_approx(pod.look_basis()), "the ceiling feed camera is the pod's lens, looking straight down")
	_check(_near(cam_b.fov, pod.fit_fov(float(tv._vp[1].size.x) / tv._vp[1].size.y), 0.001) and cam_b.keep_aspect == Camera3D.KEEP_HEIGHT, "...with the fov that holds the table in its picture")

	# --- the gates, rates and alternation per tier ---
	for tier in 3:
		QualityManager.current_tier = tier
		tv.apply_tier(tier)
		tv.set_feeds_on(true)
		var before := tv.renders.duplicate()
		var off := _ticks(tv, 120, false)
		_check(off.count(-1) == 120 and tv.renders == before, "tier %d: off screen draws nothing in 2 s" % tier)
		_check(tv._vp[0].render_target_update_mode == SubViewport.UPDATE_DISABLED and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_DISABLED, "tier %d: both feeds are disabled while off screen" % tier)
		var drawn := _ticks(tv, 60, true)  # one second in view
		var a := _count(drawn, 0)
		var b := _count(drawn, 1)
		var want := roundi(1.0 / StreamTv.PERIOD[tier])  # passes in 1 s
		_check(absi(a + b - want) <= 1, "tier %d: %d passes in 1 s (period %.4f s): %d tripod + %d ceiling" % [tier, want, StreamTv.PERIOD[tier], a, b])
		if tier < 2:
			_check(absi(a - b) <= 1, "tier %d: the two feeds alternate evenly (%d / %d), each at %.0f Hz" % [tier, a, b, float(a)])
			_check(1.0 / StreamTv.PERIOD[tier] / 2.0 <= (15.0 if tier == 0 else 10.0) + 0.01, "tier %d: at most %.0f Hz per feed" % [tier, 15.0 if tier == 0 else 10.0])
			var seq := drawn.filter(func(v: int) -> bool: return v >= 0)
			var alternates := true
			for i in range(1, seq.size()):
				alternates = alternates and seq[i] != seq[i - 1]
			_check(alternates, "tier %d: tripod and ceiling take turns" % tier)
		else:
			_check(a == 0 and b >= want - 1, "tier 2: only the ceiling feed draws (5 Hz, one slow feed): %d / %d" % [a, b])
		_check(tv._lit == Vector2(1.0, 1.0) if tier < 2 else tv._lit.y == 1.0, "tier %d: a feed shows once it has drawn (lit %s)" % [tier, tv._lit])
		var expect := StreamTv.feed_size(tier)
		_check(tv._vp[1].size == expect and (tier == 2 or tv._vp[0].size == expect), "tier %d: sub viewports are %s" % [tier, expect])
		_check(bool(tv._mat.get_shader_parameter(&"wide")) == (tier >= 2), "tier %d: the glass is %s" % [tier, "one wide picture" if tier >= 2 else "two halves"])
		# back out of view: disabled at once, the pictures stay (a TV you look away from keeps its last frame)
		_ticks(tv, 2, false)
		_check(tv._vp[0].render_target_update_mode == SubViewport.UPDATE_DISABLED and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_DISABLED and tv._lit.y == 1.0,
			"tier %d: looking away disables the feeds and keeps the last picture" % tier)
	# a tier change resizes and blanks the glass until each feed has drawn again
	QualityManager.current_tier = 1
	tv.tick(1.0, true)
	_check(tv._tier == 1 and tv._vp[1].size == StreamTv.feed_size(1), "a tier change at run time resizes the feeds")
	QualityManager.current_tier = 0

	# --- sizes: aspect and pixel budget (07 §2 / A7) ---
	_check(StreamTv.feed_size(0) == Vector2i(640, 427) and StreamTv.feed_size(1) == Vector2i(400, 267) and StreamTv.feed_size(2) == Vector2i(512, 171), "feed sizes 640x427 / 400x267 / 512x171")
	_check(_near(float(StreamTv.feed_size(0).x) / StreamTv.feed_size(0).y, StreamTv.HALF_ASPECT, 0.005) and _near(float(StreamTv.feed_size(1).x) / StreamTv.feed_size(1).y, StreamTv.HALF_ASPECT, 0.005),
		"tier 0 and 1 pictures have the half-screen aspect")
	_check(_near(float(StreamTv.feed_size(2).x) / StreamTv.feed_size(2).y, StreamTv.WIDE_ASPECT, 0.02), "tier 2's picture has the whole glass's aspect")
	var px0 := 2 * StreamTv.feed_size(0).x * StreamTv.feed_size(0).y
	var px1 := 2 * StreamTv.feed_size(1).x * StreamTv.feed_size(1).y
	var px2 := StreamTv.feed_size(2).x * StreamTv.feed_size(2).y
	_check(px0 <= 560000 and px1 < px0 * 0.6 and px2 <= px0 * 0.3, "pixels per refresh pair fall by tier: %d / %d / %d" % [px0, px1, px2])
	_check(StreamTv.PERIOD.size() == 3 and StreamTv.PERIOD[0] >= 1.0 / 30.0 - 1e-6 and StreamTv.PERIOD[1] >= 1.0 / 16.0 - 1e-6 and StreamTv.PERIOD[2] >= 1.0 / 5.0 - 1e-6, "passes at most 30 / 16 / 5 per second")

	# --- set_feeds_on: a black glass, nothing drawn ---
	QualityManager.current_tier = 0
	tv.apply_tier(0)
	tv.set_feeds_on(true)
	_ticks(tv, 30, true)
	_check(tv._lit == Vector2(1.0, 1.0), "live: both pictures lit")
	var drawn_before := tv.renders.duplicate()
	tv.set_feeds_on(false)
	_check(tv._lit == Vector2.ZERO and (tv._mat.get_shader_parameter(&"lit") as Vector2) == Vector2.ZERO, "set_feeds_on(false): the glass is black (lit 0)")
	var off_run := _ticks(tv, 90, true)
	_check(off_run.count(-1) == 90 and tv.renders == drawn_before, "off: no pass is drawn even with the TV in view")
	_check(tv._vp[0].render_target_update_mode == SubViewport.UPDATE_DISABLED and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_DISABLED, "off: both feeds disabled")
	for l: Label3D in tv.find_children("Live*", "Label3D", false, false):
		_check(not l.visible, "off: the LIVE bugs are hidden")
	tv.set_feeds_on(true)
	_check(tv._lit == Vector2.ZERO, "switched on again: black until each feed has drawn")
	_ticks(tv, 30, true)
	_check(tv._lit == Vector2(1.0, 1.0), "...then both pictures are back")
	for l: Label3D in tv.find_children("Live*", "Label3D", false, false):
		_check(l.visible, "on: the LIVE bugs show")

	# --- warm (adhoc-1014b): the intro's black prepare draws every feed of the tier once, whatever the viewer sees; the glass stays black ---
	tv.apply_tier(0)
	tv.set_feeds_on(true)
	var warm_before := tv.renders.duplicate()
	_check(tv.is_in_group(Cutscene.WARM_GROUP) and tv.warm(), "warm: asks for the feeds")
	_check(tv.renders[0] == warm_before[0] + 1 and tv.renders[1] == warm_before[1] + 1, "warm: tier 0 draws both feeds once: %s -> %s" % [warm_before, tv.renders])
	_check(tv._vp[0].render_target_update_mode == SubViewport.UPDATE_ONCE and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_ONCE, "warm: both passes are requested")
	_check(tv._lit == Vector2.ZERO, "warm: the glass stays black (a feed is lit by a pass of the game's own timing)")
	_check(tv.tick(1.0, false) == -1 and tv._vp[0].render_target_update_mode == SubViewport.UPDATE_ONCE and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_ONCE, "warm: the TV off screen does not cancel them on the next frame")
	_check(tv.tick(1.0, false) == -1 and tv._vp[0].render_target_update_mode == SubViewport.UPDATE_DISABLED and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_DISABLED and tv._lit == Vector2.ZERO, "warm: the frame after is the gates' again, still black")
	QualityManager.current_tier = 2
	warm_before = tv.renders.duplicate()
	_check(tv.warm() and tv.renders[0] == warm_before[0] and tv.renders[1] == warm_before[1] + 1, "warm: tier 2 draws the one wide feed only")
	tv.tick(1.0, false)
	tv.tick(1.0, false)
	tv.set_feeds_on(false)
	_check(not tv.warm() and tv._vp[1].render_target_update_mode == SubViewport.UPDATE_DISABLED, "warm: nothing while the TV is off")
	QualityManager.current_tier = 0
	tv.apply_tier(0)
	tv.set_feeds_on(true)

	# --- the glass shader: the camera's picture, no noise, scanlines or time ---
	var code: String = preload("res://src/shaders/tv.gdshader").code
	_check(not code.contains("TIME") and not code.contains("hash") and not code.contains("noise") and not code.contains("rand") and not code.contains("sin("), "tv.gdshader has no noise, scanlines or time")
	_check(code.contains("uniform vec2 lit") and code.contains("source_color"), "...it blacks out an undrawn feed and reads the pictures as sRGB")
	QualityManager.current_tier = 0
	finished = true
	print("TV OK" if fails == 0 else "TV FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)
