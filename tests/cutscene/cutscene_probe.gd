extends SceneTree
## The cutscene framework and its standalone scenes (docs/plan/09 §4.4, adhoc-1013c F3a). Headless, on a manual clock:
##   every scene starts, its Camera3D is the current one, the shell is a modal that blocks input (UIRouter.blocking), Skip ends it
##   (open-ended TruckOutro: Skip brings the card, Continue ends it), the previous camera comes back, the picture is a pure function
##   of the seed and the time, the Rope's gag / blindfold / hood are fixed per seat by the seed, MonsterMouth fits a 3 m shaft,
##   CutscenePlayer chains the intro, acks with `played`, tells the host how long to wait, and gates the intro's Skip on a first watch.
##   godot --path . --headless -s tests/cutscene/cutscene_probe.gd     prints CUTSCENE OK

const VAN := "res://src/cutscene/IntroVan.tscn"
const CABIN := "res://src/cutscene/IntroCabin.tscn"
const TRUCK := "res://src/cutscene/TruckOutro.tscn"
const FALL := "res://src/cutscene/FallCam.tscn"
const INTRO_ROOM := "res://src/cutscene/IntroRoom.tscn"
const FAIL_ROOM := "res://src/cutscene/FailRoom.tscn"
const WIN_ROOM := "res://src/cutscene/WinRoom.tscn"
const MOUTH := "res://src/cutscene/MonsterMouth.tscn"
const SAMPLE_STATS := {
	"nights_cleared": 3, "pots": 58, "best_combo": 6, "trick_shots": 9, "best_shot": 1240, "cash_earned": 8420,
	"scratches": 2, "fines_paid": 70, "play_time": 3725.0,
}

var fails := 0
var base_cam: Camera3D
var router: UIRouter


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	SaveManager.root = "user://cutscene_probe"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	router = UIRouter.new()
	root.add_child(router)
	base_cam = Camera3D.new()
	root.add_child(base_cam)
	base_cam.make_current()
	await process_frame
	_check(root.get_camera_3d() == base_cam and not UIRouter.blocking(), "the level's camera is current and nothing blocks input to begin with")
	_dress_rules()
	# the in-room beats run with no level here (their fixtures are null): lifecycle only, the real level is tests/cutscene/room_cutscene_probe.gd
	for sc: Array in [[&"intro_van", VAN, IntroVan.LENGTH_SEC], [&"intro_cabin", CABIN, IntroCabin.LENGTH_SEC], [&"fall", FALL, FallCam.LENGTH_SEC],
			[&"intro_room", INTRO_ROOM, IntroRoom.LENGTH_SEC], [&"fail_room", FAIL_ROOM, FailRoom.LENGTH_SEC], [&"win_room", WIN_ROOM, WinRoom.LENGTH_SEC]]:
		_lifecycle(sc[0], sc[1], sc[2])
	_truck()
	_crew_sizes_and_dress()
	_determinism()
	_fall_in_a_room()
	_mouth()
	_hud_group()
	_stats_card_compact()
	await _player()
	if fails == 0:
		print("CUTSCENE OK")
	else:
		printerr("CUTSCENE FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


func _make(path: String, opts := {}) -> Cutscene:
	var cs := (load(path) as PackedScene).instantiate() as Cutscene
	var o := {"seed": 4242, "manual": true}
	o.merge(opts, true)
	cs.configure(o)
	root.add_child(cs)
	if cs.on_stage:
		cs.global_position = Cutscene.STAGE_ORIGIN
	return cs


## Steps until it ends or `cap` seconds pass; returns the seconds stepped.
func _run_out(cs: Cutscene, dt: float, cap: float) -> float:
	var n := 0
	while cs.playing and n * dt < cap:
		cs.step(dt)
		n += 1
	return n * dt


func _names(ids: Array[StringName]) -> Array:
	var out: Array = []
	for i in ids:
		out.append(String(i))
	return out


func _camera_back(what: String) -> void:
	_check(root.get_camera_3d() == base_cam and not UIRouter.blocking(), "%s: the previous camera is back and the input is free" % what)


# --- who wears what ----------------------------------------------------------------------------------------------------------------

func _dress_rules() -> void:
	var signatures := {}
	for sd in [0, 1, 42, 99999, -5, 7, 8, 9, 10, 11, 12, 13]:
		var sig := ""
		var seen := {}
		for seat in 8:
			var k := CrewDress.kind_for(sd, seat)
			_check(k >= 0 and k <= 2 and k == CrewDress.kind_for(sd, seat), "seed %d seat %d: a stable kind (%d)" % [sd, seat, k])
			_check(seat < 4 or k == CrewDress.kind_for(sd, seat - 4), "seed %d: seat %d wraps to seat %d" % [sd, seat, seat - 4])
			if seat < 4:
				seen[k] = true
				sig += str(k)
		_check(seen.size() == 3, "seed %d: a crew of four wears a gag, a blindfold and a hood between them (%s)" % [sd, sig])
		signatures[sig] = true
	_check(signatures.size() >= 4, "different seeds dress the seats differently (%d distinct)" % signatures.size())


func _crew_sizes_and_dress() -> void:
	for n in [1, 2, 3, 4]:
		var cs := _make(VAN, {"seed": 1234, "crew_size": n})
		cs.play()
		var van := cs as IntroVan
		_check(van._crew.size() == n, "the van seats exactly the roster: %d" % n)
		for i in van._crew.size():
			var h: Humanoid = van._crew[i]
			var att := h.get_node_or_null(^"Skeleton/Dress") as BoneAttachment3D
			_check(att != null and att.bone_name == "head", "seat %d wears something on its head bone" % i)
			if att == null:
				continue
			var kind := CrewDress.kind_for(1234, i)
			var lone := Humanoid.new()  # the same skin, dressed with the kind the seed names
			lone.apply_skin(h.skin())
			root.add_child(lone)
			var mark := CrewDress.dress(lone, kind)
			var want := ((mark.get_child(0) as MeshInstance3D).mesh as ArrayMesh).get_aabb().size
			var got := ((att.get_child(0) as MeshInstance3D).mesh as ArrayMesh).get_aabb().size
			_check(got.is_equal_approx(want), "seat %d wears its %s" % [i, CrewDress.kind_name(kind)])
			lone.free()
			_check(not h.is_physics_processing(), "seat %d does not read a rocking van as walking" % i)
		cs.abort()
		cs.free()
	# the same seed dresses the same way in a second scene, another seed need not
	var a := _make(VAN, {"seed": 555}) as IntroVan
	a.play()
	var b := _make(VAN, {"seed": 555}) as IntroVan
	b.play()
	for i in 4:
		var ma := ((a._crew[i].get_node("Skeleton/Dress").get_child(0) as MeshInstance3D).mesh as ArrayMesh).get_aabb().size
		var mb := ((b._crew[i].get_node("Skeleton/Dress").get_child(0) as MeshInstance3D).mesh as ArrayMesh).get_aabb().size
		_check(ma.is_equal_approx(mb), "seat %d: two peers with one seed dress it alike" % i)
	b.abort()
	a.abort()
	a.free()
	b.free()
	_camera_back("two cutscenes started and aborted in turn")


# --- start, run, skip, restore -----------------------------------------------------------------------------------------------------

func _lifecycle(id: StringName, path: String, length: float) -> void:
	var cs := _make(path)
	var ends: Array = []
	cs.finished.connect(func(skipped: bool) -> void: ends.append(skipped))
	_check(cs.id() == id and absf(cs.length_sec() - length) < 0.001, "%s: knows its id and its length" % id)
	cs.play()
	_check(cs.playing and cs.camera.is_current() and root.get_camera_3d() == cs.camera, "%s: its own camera is the current one" % id)
	_check(cs.shell.is_visible_in_tree() and UIRouter.blocking() and cs.shell.skip_button.visible, "%s: the shell is up, it blocks the game's input, Skip shows" % id)
	var took := _run_out(cs, 0.05, length + 2.0)
	_check(not cs.playing and ends == [false] and absf(took - length) < 0.11, "%s: runs its %.1f s (%.2f) and ends, not skipped" % [id, length, took])
	_camera_back("%s ends" % id)
	cs.free()
	# Skip
	var sk := _make(path)
	var skips: Array = []
	sk.finished.connect(func(skipped: bool) -> void: skips.append(skipped))
	sk.play()
	sk.step(0.3)
	sk.shell.skip_button.pressed.emit()
	_check(not sk.playing and skips == [true], "%s: the Skip button ends it, skipped" % id)
	_camera_back("%s skipped" % id)
	sk.step(1.0)  # a stray step after the end changes nothing
	_check(skips == [true], "%s: finished fires once" % id)
	sk.free()
	# not skippable: Skip does nothing, Esc (go_back) does nothing, abort still ends it
	var ns := _make(path, {"skippable": false})
	ns.play()
	ns.step(0.2)
	ns.skip()
	ns.shell.go_back()
	_check(ns.playing and not ns.shell.skip_button.visible, "%s: not skippable means no button and no effect" % id)
	ns.abort()
	_check(not ns.playing, "%s: abort() ends it anyway" % id)
	_camera_back("%s aborted" % id)
	ns.free()


func _truck() -> void:
	var two: Array[String] = ["One.", "Two."]
	var three: Array[String] = ["One.", "Two.", "Three."]
	var cs := _make(TRUCK, {"stats": SAMPLE_STATS, "captions": two})
	var truck := cs as TruckOutro
	cs.play()
	_check(truck.length_sec() == 0.0 and cs.camera.is_current(), "truck: open-ended, its camera is current")
	cs.step(2.0)
	_check(cs.shell.caption.visible and cs.shell.caption.text == "One.", "truck: the ending text plays as captions first")
	_check(not truck._card.visible, "truck: the stats card waits for the captions")
	var z0 := truck._chunks[0].position.z
	var spin0 := truck._wheels[0].rotation.x
	cs.step(0.1)
	_check(not is_equal_approx(truck._chunks[0].position.z, z0) and not is_equal_approx(truck._wheels[0].rotation.x, spin0), "truck: the world scrolls and the wheels turn while the truck stays put")
	var lane_seen := 0.0
	var moved := false
	for i in 400:  # 20 s: the truck shakes and makes its small manoeuvres but stays in its lane
		cs.step(0.05)
		if absf(truck._truck.position.x) > 0.05:
			moved = true
		lane_seen = maxf(lane_seen, absf(truck._truck.position.x))
	_check(moved and lane_seen < 0.8, "truck: lane manoeuvres of %.2f m at most" % lane_seen)
	_check(cs.playing and truck._card.visible, "truck: after 22 s it is still riding, with the card up")
	cs.abort()
	cs.free()
	_camera_back("truck aborted")
	# Skip jumps to the card, does not end
	var cs2 := _make(TRUCK, {"stats": SAMPLE_STATS, "captions": three})
	var t2 := cs2 as TruckOutro
	cs2.play()
	cs2.step(1.5)
	var ended: Array = []
	cs2.finished.connect(func(skipped: bool) -> void: ended.append(skipped))
	cs2.shell.skip_button.pressed.emit()
	cs2.step(0.8)
	_check(cs2.playing and ended.is_empty() and t2._card.visible and not cs2.shell.caption.visible, "truck: Skip brings the stats card up and drops the captions, the ride goes on")
	_check(not cs2.shell.skip_button.visible, "truck: no Skip once the card is up")
	var card := t2._card
	_check((card.get_node("%Close") as Button).text == "Continue" and (card.get_node("%Close") as Button).visible, "truck: the card's button says Continue")
	_check((card.get_node("%Grade") as Label).text == RunStats.grade_of(SAMPLE_STATS), "truck: the grade of the run is on the card")
	_check(cs2.shell.dock.offset_top < -CutsceneShell.DOCK_HEIGHT * 0.99, "truck: the card has slid fully into the bottom dock")
	(card.get_node("%Close") as Button).pressed.emit()
	_check(not cs2.playing and ended == [false], "truck: Continue ends the ride, not skipped")
	_camera_back("truck")
	cs2.free()
	# no captions: the card comes by itself
	var cs3 := _make(TRUCK, {"stats": SAMPLE_STATS})
	cs3.play()
	cs3.step(TruckOutro.CARD_AT_SEC + 0.8)
	_check((cs3 as TruckOutro)._card.visible, "truck: with no captions the card comes up after %.1f s" % TruckOutro.CARD_AT_SEC)
	cs3.abort()
	cs3.free()
	_camera_back("truck without captions")


func _determinism() -> void:
	for path: String in [VAN, CABIN, TRUCK, FALL]:
		var poses: Array[Transform3D] = []
		for run in [[20, 0.05], [10, 0.1], [20, 0.05]]:
			var cs := _make(path, {"seed": 99})
			cs.play()
			for i in int(run[0]):
				cs.step(float(run[1]))
			poses.append(cs.camera.transform)
			cs.abort()
			cs.free()
		_check(poses[0].is_equal_approx(poses[1]) and poses[0].is_equal_approx(poses[2]), "%s: one seed, one picture at t=1 whatever the step size" % path.get_file())
		var other: Array[Transform3D] = []
		for sd in [1, 2]:
			var cs2 := _make(path, {"seed": sd})
			cs2.play()
			cs2.step(0.6)
			other.append(cs2.camera.transform)
			cs2.abort()
			cs2.free()
		if path == VAN:
			_check(not other[0].is_equal_approx(other[1]), "%s: another seed shakes differently" % path.get_file())


func _fall_in_a_room() -> void:
	var mouth := MonsterMouth.new()
	root.add_child(mouth)
	mouth.global_position = Vector3(10.0, -4.0, 3.0)
	var cs := _make(FALL, {"mouth": mouth, "drop_height": 5.0, "caption": "So close.", "crew_size": 3})
	var fall := cs as FallCam
	_check(not fall.on_stage and fall._fallers.is_empty(), "fall: given a mouth it plays in the room, with no duplicate bodies")
	cs.play()
	cs.step(0.1)
	_check(absf(cs.camera.global_position.y - (mouth.global_position.y + 5.0)) < 0.2, "fall: the camera starts drop_height above the lip")
	cs.step(1.5)
	_check(cs.camera.global_position.y < mouth.global_position.y + 2.0, "fall: it is dropping")
	_run_out(cs, 0.05, 3.0)
	_check(not cs.playing, "fall: ends at %.1f s" % FallCam.LENGTH_SEC)
	_check(cs.shell.fade.color.a >= 0.999 and cs.shell.caption.visible and cs.shell.caption.text == "So close.", "fall: ends on black with its caption up")
	_check(mouth.close_amount >= 0.999, "fall: the teeth have shut")
	_camera_back("fall in a room")
	cs.free()
	mouth.free()
	# alone (preview): a demo shaft and the rest of the crew falling with the camera
	var demo := _make(FALL, {"crew_size": 3}) as FallCam
	demo.play()
	_check(demo.on_stage and demo._fallers.size() == 2 and demo.mouth != null, "fall: with no mouth it builds a demo and two falling bodies")
	demo.abort()
	demo.free()


func _mouth() -> void:
	var m := (load(MOUTH) as PackedScene).instantiate() as MonsterMouth
	root.add_child(m)
	var lip := m.get_node("Lip") as MeshInstance3D
	var throat := m.get_node("Throat") as MeshInstance3D
	var tongue := m.get_node("Tongue") as MeshInstance3D
	var teeth := m.get_node("Teeth") as MultiMeshInstance3D
	_check(lip.get_aabb().size.x <= 3.0 and throat.get_aabb().size.x <= 3.0 and absf(MonsterMouth.WIDTH_M - lip.get_aabb().size.x) < 0.1, "mouth: %.2f m across, fits a 3 m shaft" % lip.get_aabb().size.x)
	_check(throat.get_aabb().position.y <= -MonsterMouth.DEPTH_M and tongue.mesh != null and teeth.multimesh.instance_count == 50, "mouth: a %.1f m throat, a tongue, 50 teeth in one MultiMesh" % MonsterMouth.DEPTH_M)
	_check(throat.material_override is ShaderMaterial and lip.material_override is ShaderMaterial, "mouth: the wet flesh shader")
	var open_tooth := m.tooth_xf[0]  # (a headless MultiMesh cannot be asked)
	m.close_amount = 1.0
	var shut_tooth := m.tooth_xf[0]
	_check(not open_tooth.is_equal_approx(shut_tooth) and shut_tooth.origin.length() < open_tooth.origin.length(), "mouth: closing pulls the outer teeth in over the throat")
	m.close_amount = 0.0
	var a := tongue.position
	m.pose(1.3)
	_check(not a.is_equal_approx(tongue.position), "mouth: the tongue moves with time")
	m.pose(1.3)
	var b := tongue.position
	m.pose(1.3)
	_check(b.is_equal_approx(tongue.position), "mouth: pose(t) is a pure function of t")
	m.free()


func _hud_group() -> void:
	var hud := Control.new()
	hud.add_to_group(Cutscene.HIDE_GROUP)
	root.add_child(hud)
	var cs := _make(VAN)
	cs.play()
	_check(not hud.visible, "a HUD root in group cutscene_hides is hidden while a cutscene plays")
	cs.abort()
	_check(hud.visible, "...and shown again after")
	cs.free()
	hud.free()


func _stats_card_compact() -> void:
	var card := RunStatsCard.make()
	card.show_stats(SAMPLE_STATS, "Paid in full", true, "Continue", true)
	root.add_child(card)
	_check((card.get_node("%Rows") as GridContainer).columns == 2, "stats card: compact lays the rows out in two columns, so all eight fit the dock")
	_check((card.get_node("%Close") as Button).text == "Continue", "stats card: the button text is settable")
	card.free()


# --- the player ---------------------------------------------------------------------------------------------------------------------

func _player() -> void:
	_check(CutscenePlayer.length_sec(&"intro") == IntroVan.LENGTH_SEC + IntroCabin.LENGTH_SEC + IntroRoom.LENGTH_SEC, "player: the intro is the van, the cabin, then the bar (%.1f s)" % CutscenePlayer.length_sec(&"intro"))
	_check(_names(CutscenePlayer.parts_of(&"fail")) == ["fail_room", "fall"] and _names(CutscenePlayer.parts_of(&"win")) == ["win_room", "truck_outro"], "player: fail = alert then fall, win = gas then truck")
	_check(CutscenePlayer.is_open_ended(&"win") and CutscenePlayer.is_open_ended(&"truck_outro") and not CutscenePlayer.is_open_ended(&"fail") and CutscenePlayer.max_wait_sec(&"win") == 0.0, "player: the win ends on the truck's Continue, the host has no length to wait for")
	_check(CutscenePlayer.max_wait_sec(&"intro") == CutscenePlayer.length_sec(&"intro") + CutscenePlayer.ACK_MARGIN_SEC, "player: the host waits the sequence plus %.0f s for the acks" % CutscenePlayer.ACK_MARGIN_SEC)
	_check(CutscenePlayer.max_wait_sec(&"fall") == FallCam.LENGTH_SEC + CutscenePlayer.ACK_MARGIN_SEC and CutscenePlayer.max_wait_sec(&"truck_outro") == 0.0, "player: the fall has its own wait, the open-ended truck has none")
	for id in [&"intro", &"intro_van", &"intro_cabin", &"intro_room", &"truck_outro", &"fall", &"fail_room", &"fail", &"win_room", &"win"]:
		_check(CutscenePlayer.ids().has(id) and not CutscenePlayer.parts_of(id).is_empty(), "player: knows '%s'" % id)
	_check(CutscenePlayer.parts_of(&"nope").is_empty(), "player: an unknown id has no parts")
	var player := CutscenePlayer.new()
	root.add_child(player)
	var events: Array = []
	player.started.connect(func(id: StringName) -> void: events.append("start " + String(id)))
	player.played.connect(func(id: StringName, skipped: bool) -> void: events.append("played %s %s" % [id, skipped]))
	# a first watch: not skippable; plays van then cabin to the end; the ack fires once; the intro is now seen
	_check(not SaveManager.cutscene_seen(&"intro"), "player: this player has not seen the intro yet")
	_check(player.play(&"intro", {"seed": 31, "crew_size": 2, "manual": true}), "player: starts the intro")
	_check(player.is_playing() and player.current is IntroVan and not player.current.skippable, "player: first part is the van, and a first watch cannot be skipped")
	player.skip()
	_check(player.is_playing() and player.current is IntroVan, "player: Skip is ignored on a first watch")
	_check(not player.play(&"fall"), "player: one thing at a time")
	var steps := 0
	var parts: Array[String] = []
	while player.is_playing() and steps < 600:
		if player.current != null and (parts.is_empty() or parts[-1] != String(player.current.id())):
			parts.append(String(player.current.id()))
		player.current.step(0.05)
		steps += 1
	_check(parts == ["intro_van", "intro_cabin", "intro_room"], "player: the van, the cabin, then the bar on the same cut (%s)" % [parts])
	_check(events == ["start intro", "played intro false"], "player: one start, one ack, not skipped (%s)" % [events])
	_check(absf(steps * 0.05 - CutscenePlayer.length_sec(&"intro")) < 0.3, "player: the intro takes about %.1f s (%.2f)" % [CutscenePlayer.length_sec(&"intro"), steps * 0.05])
	_check(player.current == null and not player.is_playing() and SaveManager.cutscene_seen(&"intro"), "player: nothing left running, the intro is marked seen")
	_camera_back("the intro")
	for child in player.get_children():
		_check(child.is_queued_for_deletion(), "player: a finished cutscene is queued for deletion")
	await process_frame
	_check(player.get_child_count() == 0, "player: ...and gone")
	# a second watch can be skipped, and skipping skips the whole chain
	events.clear()
	player.play(&"intro", {"seed": 31, "manual": true})
	_check(player.current.skippable, "player: the intro is skippable after the first watch")
	player.current.step(0.5)
	player.skip()
	_check(not player.is_playing() and player.current == null and events == ["start intro", "played intro true"], "player: Skip ends the whole intro, one ack, skipped (%s)" % [events])
	_camera_back("a skipped intro")
	await process_frame
	# abort works on anything (a cutscene that cannot be skipped), the ack still comes
	events.clear()
	player.play(&"fall", {"manual": true, "skippable": false})
	player.current.step(0.3)
	player.abort()
	_check(not player.is_playing() and events == ["start fall", "played fall true"], "player: abort() acks as skipped (%s)" % [events])
	_camera_back("an aborted fall")
	await process_frame
	# a peer that was away: no scene, only the ack, delivered after play() returns
	events.clear()
	player.play(&"intro", {"instant": true})
	_check(player.current == null and player.is_playing(), "player: an instant play starts nothing")
	await process_frame
	_check(not player.is_playing() and events == ["start intro", "played intro true"], "player: ...and acks as skipped on the next frame (%s)" % [events])
	_check(player.get_child_count() == 0, "player: no scene was made for it")
	player.free()
