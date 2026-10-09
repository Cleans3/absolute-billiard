extends SceneTree
## Enlarged shot controls (docs/plan/08 §2.3, adhoc-1010a C19): a tap on the small spin / elevation control opens its overlay;
## picking in the overlay lands in the ShotIntent (spin_offset, elevation_deg); Reset, OK, a tap outside, leaving CUE and a modal
## all close it; locked ranges show and the effective angle matches Ball.effective_elevation.
##   godot --path . --headless -s tests/ui/shot_controls_probe.gd     prints SHOT CONTROLS OK

var fails := 0
var tc: TouchControls
var cue: CueController


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


func _touch(node: Control, pos: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = pos
	e.pressed = pressed
	node._gui_input(e)


func _drag(node: Control, to: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 0
	e.position = to
	node._gui_input(e)


func _tap(node: Control, pos: Vector2) -> void:
	_touch(node, pos, true)
	_touch(node, pos, false)


func _run() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.disable_3d = true
	root.add_child(vp)
	tc = load("res://src/ui/TouchControls.tscn").instantiate()
	tc.touch = true
	vp.add_child(tc)
	cue = load("res://src/gameplay/cue/CueController.tscn").instantiate()
	cue.controls = tc
	root.add_child(cue)
	tc.spin_pad.changed.connect(cue.set_spin)  # the Player's wiring (player.gd)
	tc.elevation.changed.connect(cue.set_elevation)
	cue.begin(null, 0.0)
	cue.set_process(false)
	tc.set_mode(TouchControls.MODE_CUE)
	await process_frame
	await process_frame
	cue._push_ui()
	_spin()
	_elevation()
	_closing()
	vp.free()
	cue.free()
	print("SHOT CONTROLS OK" if fails == 0 else "SHOT CONTROLS FAIL (%d)" % fails)
	quit(fails)


func _spin() -> void:
	var ov := tc.spin_overlay
	_check(not ov.visible, "the spin overlay starts closed")
	_check(tc.spin_pad.size.x < 130.0, "the corner spin control stays small")
	_check(is_equal_approx(tc.spin_pad.miscue, cue.cue_spec.miscue_threshold), "the miscue ring is the cue's threshold")
	_tap(tc.spin_pad, Vector2(60, 60))
	_check(ov.visible, "a tap on the small spin control opens the enlarged ball")
	_check(absf(ov.face.size.y - 720.0 * 0.6) < 2.0 and ov.face.size.x == ov.face.size.y, "the enlarged ball is about 60%% of the screen height (%s)" % ov.face.size)
	var r := minf(ov.face.size.x, ov.face.size.y) * 0.5 - 2.0
	var c := ov.face.size * 0.5
	_touch(ov.face, c + Vector2(0.0, 0.5 * r), true)  # the lower part: draw
	_touch(ov.face, c + Vector2(0.0, 0.5 * r), false)
	_check(_near(cue.spin.x, 0.0) and _near(cue.spin.y, -0.5), "tap low on the ball = draw: %s" % cue.spin)
	cue._push_ui()
	var intent := cue.build_intent(0.5)
	_check(_near(intent.spin_offset.y, -0.5) and _near(intent.spin_offset.x, 0.0), "the ShotIntent carries the picked hit point: %s" % intent.spin_offset)
	_check(tc.spin_pad.spin == cue.spin, "the small control shows the new point")
	_check(ov.visible and (ov._readout.text.contains("Draw 50%")), "the overlay says what the point is: %s" % ov._readout.text)
	_touch(ov.face, c, true)
	_drag(ov.face, c + Vector2(0.3 * r, -0.4 * r))
	_touch(ov.face, c + Vector2(0.3 * r, -0.4 * r), false)
	_check(_near(cue.spin.x, 0.3) and _near(cue.spin.y, 0.4), "drag right and up = right English, follow: %s" % cue.spin)
	_touch(ov.face, c + Vector2(3.0 * r, 0.0), true)  # past the rim clamps to it
	_touch(ov.face, c, false)
	_check(_near(cue.spin.length(), 1.0), "a point past the rim clamps to the rim: %s" % cue.spin)
	_check(SpinOverlay.describe(Vector2(0.95, 0.0), 0.92).ends_with("MISCUE") and not SpinOverlay.describe(Vector2(0.5, 0.0), 0.92).contains("MISCUE"), "past the miscue ring the overlay warns")
	ov._reset.pressed.emit()
	_check(cue.spin == Vector2.ZERO and ov.visible, "Reset centres the ball and keeps the overlay open")
	_check(ov._readout.text == "Centre ball", "and says so: %s" % ov._readout.text)
	_tap(ov, Vector2(5, 5))
	_check(not ov.visible, "a tap outside the card closes it")
	_tap(tc.spin_pad, Vector2(60, 60))
	_tap(ov, Vector2(300, 300))  # inside the card, off the ball and the buttons: nothing happens
	_check(ov.visible, "a tap on the card's margin does not close it")
	ov._ok.pressed.emit()
	_check(not ov.visible, "OK closes it")
	# a drag that starts on the small control is not a tap
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.position = Vector2(10, 10)
	e.pressed = true
	tc.spin_pad._gui_input(e)
	e = InputEventScreenTouch.new()
	e.index = 0
	e.position = Vector2(100, 100)
	e.pressed = false
	tc.spin_pad._gui_input(e)
	_check(not ov.visible, "a swipe across the small control does not open the overlay")


func _elevation() -> void:
	var ov := tc.elevation_overlay
	cue.cue_spec = CueSpec.new()  # a fresh cue like EconomyManager.build_cue_spec() starts with: no Jump, no Masse
	cue.set_spin(Vector2.ZERO)
	cue.set_elevation(0.0)
	cue._push_ui()
	_check(not ov.visible, "the elevation overlay starts closed")
	_check(tc.elevation.size.x < 130.0, "the corner elevation control stays small")
	_tap(tc.elevation, Vector2(60, 36))
	_check(ov.visible, "a tap on the small elevation control opens the enlarged one")
	var at := func(deg: float, k := 0.8) -> Vector2:
		return ov._pivot + Vector2(-cos(deg_to_rad(deg)), -sin(deg_to_rad(deg))) * ov._radius * k
	_touch(ov, at.call(20.0), true)
	_touch(ov, at.call(20.0), false)
	_check(_near(cue.elevation_deg, 20.0), "tap on the protractor at 20 degrees: %f" % cue.elevation_deg)
	_check(_near(cue.build_intent(1.0).elevation_deg, 20.0), "the ShotIntent carries the picked angle")
	_touch(ov, at.call(30.0), true)
	_drag(ov, at.call(36.4, 0.5))
	_touch(ov, at.call(36.4, 0.5), false)
	_check(_near(cue.elevation_deg, 36.0), "a drag lands on whole degrees (36.4 -> 36): %f" % cue.elevation_deg)
	ov._plus.pressed.emit()
	ov._minus.pressed.emit()
	ov._minus.pressed.emit()
	_check(_near(cue.elevation_deg, 35.0), "+1 then -1 -1: %f" % cue.elevation_deg)
	_touch(ov, ov._pivot + Vector2(300.0, -300.0), true)  # beside the protractor: ignored
	_touch(ov, ov._pivot + Vector2(300.0, -300.0), false)
	_check(_near(cue.elevation_deg, 35.0), "a touch on the buttons' side does not move the angle")
	_touch(ov, ov._pivot + Vector2(-ov._radius * 0.5, 40.0), true)  # below level: 0, never negative
	_touch(ov, ov._pivot + Vector2(-ov._radius * 0.5, 40.0), false)
	_check(_near(cue.elevation_deg, 0.0), "below the table plane clamps to 0")
	_touch(ov, ov._pivot + Vector2(-5.0, -ov._radius * 0.9), true)  # nearly overhead: 80
	_touch(ov, ov._pivot + Vector2(-5.0, -ov._radius * 0.9), false)
	_check(_near(cue.elevation_deg, 80.0), "nearly overhead clamps to 80: %f" % cue.elevation_deg)
	# locked ranges: a fresh cue has no Jump, so it stops at 29 and the overlay says so
	cue._push_ui()
	_check(not cue.cue_spec.jump_unlocked and _near(tc.elevation.cap, Ball.effective_elevation(80.0, Vector2.ZERO, cue.cue_spec)), "cap = Ball.effective_elevation (%f)" % tc.elevation.cap)
	_check(_near(tc.elevation.cap, 29.0) and _near(tc.elevation.effective(), 29.0), "Jump locked: the cue is capped at 29 with 80 asked")
	_check(ov._reason.text.contains("Jump shots are locked") and ov._reason.text.contains("shot uses 29"), "the overlay names the lock and the angle the shot uses: %s / %s" % [ov._reason.text, ov._readout.text])
	var intent := cue.build_intent(1.0)
	_check(_near(Ball.effective_elevation(intent.elevation_deg, intent.spin_offset, cue.cue_spec), tc.elevation.effective()), "what the overlay shows is what Ball.strike uses")
	var spec := cue.cue_spec
	spec.jump_unlocked = true
	cue._push_ui()
	_check(_near(tc.elevation.cap, 80.0) and ov._reason.text == "", "Jump unlocked, soft English: nothing is shut")
	cue.set_spin(Vector2(0.7, 0.0))
	cue._push_ui()
	_check(_near(tc.elevation.cap, 44.0) and ov._reason.text.contains("Masse is locked") and ov._reason.text.contains("44"), "hard English without Masse caps at 44: %s" % ov._reason.text)
	spec.masse_unlocked = true
	cue._push_ui()
	_check(_near(tc.elevation.cap, 80.0), "Masse unlocked: open again")
	ov._reset.pressed.emit()
	_check(cue.elevation_deg == 0.0 and ov.visible, "Reset levels the cue and keeps the overlay open")
	_tap(ov, Vector2(5, 5))
	_check(not ov.visible, "a tap outside the card closes it")


func _closing() -> void:
	tc._open_overlay(tc.spin_overlay)
	tc.set_mode(TouchControls.MODE_WALK)
	_check(not tc.spin_overlay.visible, "leaving CUE closes the spin overlay")
	tc.set_mode(TouchControls.MODE_CUE)
	tc._open_overlay(tc.elevation_overlay)
	tc._on_modal_changed(true)
	_check(not tc.elevation_overlay.visible, "a modal (Pause) closes the elevation overlay")
	tc._on_modal_changed(false)
