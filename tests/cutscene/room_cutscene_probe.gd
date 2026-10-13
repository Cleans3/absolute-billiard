extends SceneTree
## The in-room cutscenes wired into MainLevel (docs/plan/09 §3.8, 04 §5, adhoc-1013c F3b), one peer (Solo) on a manual clock:
##   - fixtures on their own: the door (swing, bolt, locked), the beacon (one realtime light), the sounds, the crew's choreography (at most
##     two bodies limp at once for a crew of four, the throw ends with everyone home and upright, the fall is monotonic inside the shaft);
##   - the intro plays ONCE on a fresh run, before Night 1 (the campaign waits for the ack), never on a Resume; Skip and a late peer end in the
##     same state (everyone home, the door shut and bolted); the host's wait ends on every ack or on the max wait;
##   - the failure: red alert (one realtime spot, a red wash), the TV goes black, the slot machine goes dark, the mirror bleeds, the crew is
##     pulled onto the Trapdoor, the Trapdoor opens with the monster in its Pit, FallCam starts exactly where the room beat stopped, the bodies fall,
##     the run's stats card is up on black in the SAME call FallCam ends in, Continue leaves; Skip jumps straight to the card;
##   - the win (Campaign only): green light, Gus cheers, the Vent opens, a bounded green plume, blur then black, the truck with the stats and the
##     ending cards as captions, Continue leaves; Skip on the room beat still plays the truck; Endless never wins;
##   - with cutscenes skipped nothing changes: the PhaseScreen shows Game over.
##   godot --path . --headless -s tests/cutscene/room_cutscene_probe.gd      prints ROOM CUTSCENE OK

const INTRO_ROOM := "res://src/cutscene/IntroRoom.tscn"
const PLAYER_SCENE := "res://src/gameplay/player/Player.tscn"

var fails := 0
var finished := false
var left := 0  ## times the director asked to leave the session
var level: Node
var loop: GameLoop
var director: CutsceneDirector
var cs: CutscenePlayer
var player: Player
var home := Vector3.ZERO
var tv: StreamTv
var mirror: Mirror
var trap: Trapdoor
var vent: Vent
var door: EntranceDoor
var gus: Bartender
var cut: CutScreen
var cards: StoryCards
var phase_screen: PhaseScreen


func _init() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		if not finished:
			print("ROOM CUTSCENE FAIL (script error or hang)")
			quit(1))
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _until(cond: Callable, sec: float) -> bool:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


## Steps the cutscene on the clock to `time` (it may end on the way: then it stops).
func _to(c: Cutscene, time: float, dt := 0.05) -> void:
	while c.playing and c.t < time - 0.0001:
		c.step(minf(dt, time - c.t))


## Steps whatever part is on until `cs` plays `want` (a Cutscene class check by id), by big steps.
func _until_part(want: StringName) -> void:
	var guard := 0
	while cs.is_playing() and (cs.current == null or cs.current.id() != want) and guard < 200:
		if cs.current != null:
			cs.current.step(0.5)
		guard += 1


func _run() -> void:
	await process_frame
	SaveManager.root = "user://test_room_cutscenes"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root.path_join("profile.json"))
	_fixtures()
	_crew_of_four()
	await _sounds_and_lights()
	CutsceneDirector.skip_cutscenes = false
	CutsceneDirector.manual_clock = true
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self, 60.0, true, true, false, true)
	level = current_scene
	loop = level.get_node("GameLoop")
	director = level.get_node("CutsceneDirector")
	cs = director.cutscenes
	player = level.get_node("PlayerSpawner").get_local_player() as Player
	home = player.global_position
	tv = level.get_node("Tv")
	mirror = level.get_node("Mirror")
	trap = level.get_node("Trapdoor")
	vent = level.get_node("Vent")
	door = level.get_node("EntranceDoor")
	gus = level.get_node("Bar/Bartender")
	cut = level.get_node("UILayer/CutScreen")
	cards = level.get_node("UILayer/StoryCards")
	phase_screen = level.get_node("UILayer/PhaseScreen")
	director.leave_handler = func() -> void: left += 1
	await _intro_once()
	await _intro_not_on_resume()
	await _intro_skip_and_late()
	await _wait_logic()
	await _failure()
	await _failure_skip_and_late()
	await _win()
	await _win_skip_late_endless()
	await _skipped_cutscenes_keep_the_screens()
	finished = true
	print("ROOM CUTSCENE OK" if fails == 0 else "ROOM CUTSCENE FAIL (%d)" % fails)
	quit(fails)


# --- fixtures on their own -------------------------------------------------------------------------------------------------------------

func _fixtures() -> void:
	var d := EntranceDoor.new()
	root.add_child(d)
	_check(d.is_locked() and d.openness == 0.0 and d.bolt == 1.0, "door: made shut and bolted")
	_check(not d._void.visible, "door: a shut door shows no doorway quad")
	d.set_openness(1.0)
	_check(d._void.visible and not d.is_locked(), "door: open it shows the dark doorway and is no longer locked")
	var tip: Vector3 = d._hinge.global_transform * Vector3(EntranceDoor.HALF_W * 2.0, 0.0, 0.0)
	_check(tip.z > EntranceDoor.QUAD_Z + 1.0 and tip.z < -5.0 and tip.x < 0.0, "door: flung open it lies inside the room's kept-clear swing, against the west side (%s)" % tip)
	d.set_openness(0.0)
	d.set_bolt(0.0)
	_check(is_equal_approx(d._bar.position.x, EntranceDoor.BOLT_DRAWN) and not d.is_locked(), "door: a drawn bolt is not locked")
	d.set_bolt(1.0)
	_check(is_equal_approx(d._bar.position.x, EntranceDoor.BOLT_SHOT) and d.is_locked(), "door: shot bolt, shut door = locked")
	d.free()
	# the beacon is ONE realtime light (07 §2: the room has two, this is the third)
	var a := AlertLight.new()
	root.add_child(a)
	a.pose(0.3, Color.RED, 1.0)
	_check(a.find_children("*", "Light3D", true, false).size() == 1, "beacon: exactly one realtime light")
	var e0 := (a.find_child("Sweep", true, false) as SpotLight3D).light_energy
	a.pose(0.3, Color.GREEN, 0.0)
	_check((a.find_child("Sweep", true, false) as SpotLight3D).light_energy == 0.0 and e0 > 0.0, "beacon: power 0 is dark")
	a.pose(1.0, Color.RED, 1.0)
	var turn1 := a._head.rotation.y
	a.pose(1.0, Color.RED, 1.0)
	_check(is_equal_approx(turn1, a._head.rotation.y), "beacon: pose(t) is a pure function of t")
	a.free()
	# the sounds exist, loop where they should, and are not silent
	for kind in [CutsceneSfx.Kind.SLAM, CutsceneSfx.Kind.CLUNK, CutsceneSfx.Kind.THUD, CutsceneSfx.Kind.ALARM, CutsceneSfx.Kind.HISS]:
		var w := CutsceneSfx.stream(kind)
		_check(w.data.size() == int(CutsceneSfx.SECONDS[kind] * CutsceneSfx.MIX_RATE) * 2 and w.data.size() > 0, "sfx %d: rendered, %d bytes" % [kind, w.data.size()])
		_check((w.loop_mode == AudioStreamWAV.LOOP_FORWARD) == CutsceneSfx.LOOPING.has(kind), "sfx %d: loops only if it is the alarm or the gas" % kind)
		var loud := false
		for i in range(0, w.data.size(), 2):
			if absi(w.data.decode_s16(i)) > 2000:
				loud = true
				break
		_check(loud, "sfx %d: not silent" % kind)
	_check(CutsceneSfx.stream(CutsceneSfx.Kind.SLAM) == CutsceneSfx.stream(CutsceneSfx.Kind.SLAM), "sfx: rendered once, then cached")
	_check(WinRoom.GAS_PARTICLES <= 64, "gas: a bounded plume (%d particles)" % WinRoom.GAS_PARTICLES)
	# the Trapdoor ring and the fall stay inside the 3 m shaft
	for n in [1, 2, 3, 4]:
		for i in n:
			var spot := RoomCutscene.pull_spot(i, n)
			_check(absf(spot.x - Trapdoor.HOLE_CENTER.x) <= RoomCutscene.SPOT_R + 0.001 and absf(spot.z - Trapdoor.HOLE_CENTER.z) <= RoomCutscene.SPOT_R + 0.001, "pull spot %d of %d is on the hole: %s" % [i, n, spot])
	_check(RoomCutscene.pull_spot(0, 1).is_equal_approx(Trapdoor.HOLE_CENTER), "a crew of one stands at the hole's middle")
	_check(FailRoom.LENGTH_SEC == 5.0, "failure: the floor opens after 5 s (U17)")
	_check(IntroRoom.limp_at(4, 0.0) == 0, "intro: nobody is limp before the first lands")
	var worst := 0
	var t := 0.0
	while t <= IntroRoom.LENGTH_SEC:
		worst = maxi(worst, IntroRoom.limp_at(4, t))
		t += 0.01
	_check(worst == 2, "intro: a crew of four has two limp bodies at most, and does reach two (%d)" % worst)
	_check(IntroRoom.T_SLAM > IntroRoom.THROW_AT + IntroRoom.THROW_GAP * 3.0 + 0.1, "intro: the door slams only after the last body is through")
	_check(IntroRoom.T_BACK < IntroRoom.LENGTH_SEC and IntroRoom.T_BOLT + IntroRoom.BOLT_SEC < IntroRoom.T_BACK, "intro: the bolt shoots and the beat of silence fits before the cut back")


## The choreography with four real Player nodes and no level: the throw's limp count, its end state, the fall.
func _crew_of_four() -> void:
	var fakes: Array[Player] = []
	var members: Array = []
	for i in 4:
		var p := (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
		root.add_child(p)
		var h := Vector3(-1.5 + float(i), 0.0, 1.2)
		p.global_position = h
		fakes.append(p)
		members.append({"player": p, "seat": i, "local": false, "home": h})
	var room := (load(INTRO_ROOM) as PackedScene).instantiate() as IntroRoom
	room.configure({"seed": 5, "manual": true})
	root.add_child(room)
	room.play()
	room.members = members
	var worst := 0
	var seen_in_air := 0
	var t := 0.0
	while room.playing and t < IntroRoom.LENGTH_SEC - 0.05:
		t += 0.02
		room.step(0.02)
		var limp := 0
		for p in fakes:
			if p.visible and (p.humanoid.transform.basis * Vector3.UP).y < 0.5:
				limp += 1
			if p.visible and p.global_position.y > 1.2 and p.global_position.z > -4.5 and p.global_position.z < -1.5:
				seen_in_air += 1
			_check(p.visible or p.global_position.z < -7.3, "intro: a body that is not yet thrown waits outside, unseen (%s)" % p.global_position)
		worst = maxi(worst, limp)
		_check(limp <= IntroRoom.limp_at(4, room.t), "intro: %d limp at %.2f s, the plan says %d" % [limp, room.t, IntroRoom.limp_at(4, room.t)])
	_check(worst == 2, "intro: four bodies were never more than two limp at once, and it did get to two (%d)" % worst)
	_check(seen_in_air > 0, "intro: the throws go over the table (a body above 1.2 m between the door and the middle)")
	room.step(1.0)  # the end
	_check(not room.playing, "intro room: ended")
	for i in 4:
		var p := fakes[i]
		_check(p.global_position.is_equal_approx(Vector3(-1.5 + float(i), 0.0, 1.2)) and p.visible, "intro: seat %d ends at its spawn spot" % i)
		_check(p.humanoid.transform.is_equal_approx(Transform3D.IDENTITY), "intro: seat %d ends upright" % i)
	room.free()
	# the fall: monotonic, inside the shaft, ring closing in
	var last_y := 1.0
	for k in 60:
		var time := float(k) * 0.07
		RoomCutscene.drop_member(members[1], 1, 4, time)
		var pos := fakes[1].global_position
		_check(pos.y <= last_y + 0.0001, "fall: seat 1 only goes down (%.2f at %.2f s)" % [pos.y, time])
		_check(Vector2(pos.x - Trapdoor.HOLE_CENTER.x, pos.z - Trapdoor.HOLE_CENTER.z).length() <= RoomCutscene.SPOT_R + 0.001, "fall: seat 1 stays in the shaft")
		last_y = pos.y
	_check(last_y <= -Trapdoor.SHAFT_DEPTH - RoomCutscene.THROAT_M + 0.01, "fall: it ends down the monster's throat (%.2f)" % last_y)
	for p in fakes:
		p.free()


func _sounds_and_lights() -> void:
	await process_frame
	var sm := SlotMachine.new()
	root.add_child(sm)
	await process_frame
	sm.set_power(false)
	_check(float(sm._mat.get_shader_parameter(&"glow")) == 0.0 and not sm._led.visible and not sm._title.visible, "slot machine: set_power(false) is dark")
	sm.set_power(true)
	_check(float(sm._mat.get_shader_parameter(&"glow")) > 0.0 and sm._led.visible and sm._title.visible, "slot machine: ...and comes back")
	sm.free()


# --- the intro ------------------------------------------------------------------------------------------------------------------------

func _intro_once() -> void:
	_check(await _until(func() -> bool: return cs.is_playing(), 10.0), "the intro starts with the level")
	_check(cs.playing_id == &"intro" and cs.current is IntroVan, "a fresh run starts with the intro's van")
	_check(not cs.current.skippable, "the first watch cannot be skipped")
	_check(loop.campaign_seed == 0 and not cards.is_open() and director._waiting, "Night 1 has not started: the campaign waits for the intro's acks")
	_check(not (level.get_node("UILayer/HUD") as Control).visible, "the HUD is hidden while a cutscene plays")
	_check(UIRouter.blocking(), "the cutscene blocks the game's input")
	_check(door.is_locked(), "the door begins bolted")
	var seed_used := cs.current.cut_seed
	_until_part(&"intro_room")
	var room := cs.current as IntroRoom
	_check(room != null and room.members.size() == 1 and bool(room.members[0].local), "the bar part sees the local player")
	_check(room.cut_seed == seed_used, "all three parts share one seed")
	_check(not player.visible and not player.is_physics_processing() and not player.humanoid.is_physics_processing(), "outside the door, the walker is out of the game's hands")
	var tripod := (level.get_node("Cameras") as CameraRigs).rigs[0].get_node("Model") as Node3D
	_check(not tripod.visible, "the base tripod, which stands dead in front of the door, is hidden for the beat")
	_to(room, 0.45)
	_check(door.bolt < 0.01 and door.openness > 0.0, "the bolt is drawn and the door bursts open")
	_to(room, 1.05)
	_check(player.visible and player.global_position.z > -4.0 and player.global_position.z < -2.0 and player.global_position.y > 1.2, "mid-flight the body is over the table: %s" % player.global_position)
	_to(room, 2.2)
	_check(player.global_position.is_equal_approx(home) and (player.humanoid.transform.basis * Vector3.UP).y < 0.3, "it lands at its spawn spot, on its back")
	_to(room, IntroRoom.T_SLAM + 0.4)
	_check(door.openness < 0.001 and door.bolt < 0.01, "the door is slammed, the bolt not yet shot")
	_to(room, IntroRoom.T_BOLT + IntroRoom.BOLT_SEC + 0.05)
	_check(door.is_locked(), "...then the bolt shoots: locked")
	_check(not tripod.visible, "...and still hidden for the lock's close-up")
	_to(room, IntroRoom.T_BACK + 0.1)
	_check(tripod.visible, "...back in the room at the cut to the player's eye")
	_check(room.camera.global_transform.is_equal_approx(player.cam.global_transform), "the last shot is the player's own eye")
	_check((player.humanoid.transform.basis * Vector3.UP).y > 0.99, "...and they are on their feet")
	_to(room, IntroRoom.LENGTH_SEC - 0.05)
	_check(room.playing, "still running 50 ms before its end")
	room.step(0.1)
	_check(not cs.is_playing() and SaveManager.cutscene_seen(&"intro"), "the intro ends and is marked seen")
	_check(loop.campaign_seed == seed_used and loop.phase == GameLoop.Phase.INTERMISSION, "the host starts Night 1 with the intro's seed, in the same call")
	_check(cards.is_open(), "...and Night 1's story cards follow")
	_check(player.global_position.is_equal_approx(home) and player.is_physics_processing() and player.humanoid.is_physics_processing() and player.visible and tripod.visible, "everyone is home and back in the game, the tripod too")
	_check(player.humanoid.transform.is_equal_approx(Transform3D.IDENTITY) and door.is_locked(), "...upright, the door shut and bolted for the whole session")
	cards.close()
	await _frames(2)
	_check((level.get_node("UILayer/HUD") as Control).visible, "the HUD is back (it hides itself under the story cards, so after they close)")
	loop._begin_night()  # the next Night: no second intro
	await _frames(3)
	_check(not cs.is_playing() and not director.is_busy(), "the intro plays once: Night 2 does not replay it")
	cards.close()


func _intro_not_on_resume() -> void:
	SaveManager.pending_resume = loop.build_profile()
	level._start()  # the host's kick-off with a checkpoint waiting
	await _frames(3)
	_check(not cs.is_playing() and not director.is_busy() and SaveManager.pending_resume == null, "a Resume never replays the intro")
	cards.close()
	await _frames(1)


func _intro_skip_and_late() -> void:
	# a second watch can be skipped, and the world is then in the end state
	director.cutscene_cue(&"intro", 4242)
	_check(cs.is_playing() and cs.current.skippable, "the intro is skippable after the first watch")
	cs.current.step(0.2)
	cs.skip()
	_check(not cs.is_playing(), "Skip ends the whole intro")
	_check(player.global_position.is_equal_approx(home) and door.is_locked() and (level.get_node("UILayer/HUD") as Control).visible, "...with the crew home and the door bolted")
	director.cutscene_cue(&"intro", 4242)
	_until_part(&"intro_room")
	var room := cs.current as IntroRoom
	_to(room, 1.3)
	_check(player.global_position.distance_to(home) > 0.5, "skipping mid-throw: the body is in the air")
	cs.skip()
	_check(not cs.is_playing() and player.global_position.is_equal_approx(home) and player.visible, "...Skip puts it home")
	_check((level.get_node("Cameras") as CameraRigs).rigs[0].get_node("Model").visible, "...and the tripod back")
	_check(player.humanoid.transform.is_equal_approx(Transform3D.IDENTITY) and door.is_locked() and player.is_physics_processing(), "...upright, the door shut and bolted, the walker back in the game")
	await _frames(1)
	# a late peer: no scene, only the ack
	var acks: Array = []
	cs.played.connect(func(id: StringName, skipped: bool) -> void: acks.append([id, skipped]))
	director._resumed_msec = Time.get_ticks_msec()
	director.cutscene_cue(&"intro", 77)
	_check(cs.is_playing() and cs.current == null, "a peer just back from the background plays no scene")
	await _frames(2)
	_check(not cs.is_playing() and acks == [[&"intro", true]], "...it only acks, as skipped (%s)" % [acks])
	director._resumed_msec = -1000000


## The host's wait: every ack, or the max wait, whichever first; an ack from a peer that is not connected is not needed.
func _wait_logic() -> void:
	var fired := [0]
	director._open_wait(&"probe_a", 99.0, func() -> void: fired[0] += 1)
	await _frames(3)
	_check(fired[0] == 0 and director._waiting, "wait: nothing acked, nothing fires")
	director._record_ack(&"probe_a", 4242)  # a stranger
	_check(fired[0] == 0, "wait: an ack from a peer that is not in the room does not release it")
	director._record_ack(&"probe_a", 1)
	_check(fired[0] == 1 and not director._waiting, "wait: the host's own ack, alone in the room, releases it")
	director._open_wait(&"probe_b", 0.4, func() -> void: fired[0] += 1)
	Cutscene.time_scale = 50.0
	await _frames(4)
	Cutscene.time_scale = 1.0
	_check(fired[0] == 2 and not director._waiting, "wait: the max wait releases it with no ack at all")
	_check(CutscenePlayer.max_wait_sec(&"intro") == CutscenePlayer.length_sec(&"intro") + CutscenePlayer.ACK_MARGIN_SEC, "wait: the intro's max wait is its length plus the margin")
	# an ack that arrives before the host opens its wait is kept (a faster client's Continue)
	director._record_ack(&"probe_c", 1)
	director._open_wait(&"probe_c", 99.0, func() -> void: fired[0] += 1)
	director._check_wait()
	_check(fired[0] == 3, "wait: an early ack counts")


# --- the failure ----------------------------------------------------------------------------------------------------------------------

func _reset_world() -> void:
	director._close_card()
	trap.set_openness(0.0)
	tv.set_feeds_on(true)
	mirror.set_blood(0.0)
	cut.clear()
	player.global_position = home
	player.visible = true
	player.humanoid.transform = Transform3D.IDENTITY
	player.humanoid.clear_hand(0)
	player.humanoid.clear_hand(1)
	player.set_physics_process(true)
	player.humanoid.set_physics_process(true)
	if director._mouth != null:
		director._mouth.visible = false
	for sm in get_nodes_in_group(&"slot_machine"):
		(sm as SlotMachine).set_power(true)


func _failure() -> void:
	_reset_world()
	left = 0
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	await _frames(2)
	_check(cs.playing_id == &"fail" and cs.current is FailRoom, "Game over plays the failure sequence, from the phase alone")
	_check(not phase_screen.visible, "...and the Game over screen does not open under it")
	var room := cs.current as FailRoom
	_check(room.skippable, "the failure can be skipped")
	_check(room.mouth != null and room.mouth == director._mouth and room.mouth.get_parent() == trap.pit() and not room.mouth.visible, "the monster waits hidden in the Trapdoor's Pit")
	_check(tv.feeds_on and mirror.blood == 0.0 and not trap.is_open, "before: the TV is on, the mirror clean, the floor shut")
	_to(room, 0.8)
	_check(room._alert.power > 0.99 and room._alert._spot.visible and room._alert._spot.light_color.r > 0.9 and room._alert._spot.light_color.g < 0.3, "a red alert light is on in the middle of the room")
	_check(room._alert.find_children("*", "Light3D", true, false).size() == 1, "...one realtime light")
	_check(cut.active, "...the screen is washed red")
	_check(absf(room._alert.global_position.x - AlertLight.MOUNT.x) < 0.001 and absf(room._alert.global_position.z - AlertLight.MOUNT.z) < 0.001, "...in the middle of the ceiling")
	var turn := room._alert._head.rotation.y
	_to(room, 0.9)
	_check(not is_equal_approx(turn, room._alert._head.rotation.y), "...and it spins")
	_to(room, 1.1)
	_check(tv.feeds_on, "the TV is still on at 1.1 s")
	_to(room, 1.3)
	_check(not tv.feeds_on, "Tv.set_feeds_on(false): the TV is black")
	_to(room, 1.8)
	var slot := get_first_node_in_group(&"slot_machine") as SlotMachine
	_check(slot != null and float(slot._mat.get_shader_parameter(&"glow")) == 0.0 and not slot._led.visible, "the slot machine's screen goes dark")
	_to(room, 2.6)
	_check(mirror.blood > 0.3 and mirror.blood < 0.7, "the mirror is bleeding (%.2f)" % mirror.blood)
	_to(room, 4.0)
	_check(mirror.blood > 0.99, "...and bloody")
	_check(not trap.is_open, "the floor is still shut before the 5 s are up")
	_to(room, 4.9)
	_check(Vector2(player.global_position.x - Trapdoor.HOLE_CENTER.x, player.global_position.z - Trapdoor.HOLE_CENTER.z).length() < 0.01, "the crew has been pulled onto the Trapdoor")
	_check(not player.is_physics_processing(), "...the walker is not simulating")
	_to(room, FailRoom.LENGTH_SEC - 0.01)
	_check(room.playing and not trap.is_open, "5 s: not yet")
	room.step(0.02)
	var last_origin := room.camera.global_transform.origin
	var last_basis := room.camera.global_transform.basis
	_check(trap.is_open and director._mouth.visible, "5 s: Trapdoor.open() and the monster shows in its Pit")
	_check(cs.current is FallCam, "...and FallCam takes over on the same call")
	var fall := cs.current as FallCam
	_check(fall.camera.global_transform.origin.distance_to(last_origin) < 0.05 and fall.camera.global_transform.basis.is_equal_approx(last_basis), "FallCam's first frame is exactly where the room beat's last one stood: no jump in the cut")
	_check(fall.mouth == director._mouth and is_equal_approx(fall.drop_height, CutsceneDirector.DROP_HEIGHT), "FallCam falls into the Pit's monster from head height")
	_to(fall, 1.0)
	_check(player.global_position.y < -1.0, "the body drops through the open floor (%.2f)" % player.global_position.y)
	_to(fall, 2.0)
	_check(player.global_position.y < -9.0, "...down the monster's throat (%.2f)" % player.global_position.y)
	_to(fall, FallCam.LENGTH_SEC - 0.01)
	_check(director.card == null, "no card while the fall is on")
	fall.step(0.02)
	_check(not cs.is_playing(), "the fall ends")
	_check(director.card != null and director.card.visible and director.card.fade.color.a >= 0.999, "the run's card is up on black in the very call FallCam ended in")
	_check(UIRouter.blocking(), "...as a modal")
	var stats: RunStatsCard = null
	for c in director.card.get_children():
		if c is RunStatsCard:
			stats = c
	_check(stats != null, "the card is a RunStatsCard")
	_check((stats.get_node("%Grade") as Label).text == RunStats.grade_of(loop.run_stats.to_dict()), "...with the run's grade")
	_check(RunStatsCard.rows(loop.run_stats.to_dict()).size() == RunStatsCard.MAX_ROWS, "...and at most eight rows")
	_check((stats.get_node("%Close") as Button).text == "Continue" and (stats.get_node("%Close") as Button).visible and left == 0, "Continue, and nobody has left yet")
	(stats.get_node("%Close") as Button).pressed.emit()
	_check(left == 1, "Continue leaves the session (the main menu): solo, at once")
	_reset_world()


func _failure_skip_and_late() -> void:
	left = 0
	loop._set_phase(GameLoop.Phase.GAME_OVER)  # also the Endless ending: both modes fail the same way
	await _frames(2)
	_check(cs.current is FailRoom, "a second Game over plays the failure again")
	var room := cs.current as FailRoom
	_to(room, 1.5)
	cs.skip()
	_check(not cs.is_playing() and director.card != null and director.card.visible, "Skip jumps straight to the stats card on black")
	_check(not trap.is_open and not cut.active, "...with the floor still shut and no red wash")
	var stats: RunStatsCard = null
	for c in director.card.get_children():
		if c is RunStatsCard:
			stats = c
	(stats.get_node("%Close") as Button).pressed.emit()
	_check(left == 1, "...and Continue leaves")
	_reset_world()
	# a peer just back from the background goes straight to the card
	left = 0
	director._resumed_msec = Time.get_ticks_msec()
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	await _frames(2)
	_check(not cs.is_playing() and director.card != null, "a late peer sees no failure scene, only the card")
	director._resumed_msec = -1000000
	director._close_card()
	director._over = true
	_reset_world()


# --- the win --------------------------------------------------------------------------------------------------------------------------

func _win() -> void:
	left = 0
	loop.night_index = 2  # the finale: the only Night with ending cards
	var story: StoryNight = loop.current_night().story
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _frames(2)
	_check(cs.playing_id == &"win" and cs.current is WinRoom, "Campaign won plays the win sequence, from the phase alone")
	_check(not phase_screen.visible and not cards.is_open(), "...no Campaign won screen, no ending cards over it: the truck has them")
	var room := cs.current as WinRoom
	_check(not vent.is_open and not gus.celebrating, "before: the vent is shut, Gus is at his counter")
	_to(room, 0.7)
	var spot := room._alert._spot
	_check(spot.visible and spot.light_color.g > 0.9 and spot.light_color.r < 0.3, "the light turns green")
	_to(room, 1.1)
	_check(gus.celebrating, "Gus celebrates")
	_to(room, 1.4)
	_check(gus._humanoid.position.y >= 0.0 and gus._humanoid.position.y <= 0.15, "...hopping behind the counter")
	_to(room, 2.6)
	_check(vent.is_open, "Vent.open()")
	_check(not room._gas.emitting, "the gas has not started yet")
	_to(room, 3.0)
	_check(room._gas.emitting and room._gas.amount == WinRoom.GAS_PARTICLES, "...then it sprays green gas, a bounded plume")
	_check(room._gas.global_transform.origin.is_equal_approx(vent.mouth_transform().origin), "...out of the vent's mouth")
	_to(room, 4.5)
	var mat := cut.material as ShaderMaterial
	_check(float(mat.get_shader_parameter(&"blur")) > 0.3, "the view blurs")
	var tint: Color = mat.get_shader_parameter(&"tint")
	_check(tint.g > tint.r and float(mat.get_shader_parameter(&"amount")) > 0.3, "...in green")
	_to(room, 6.3)
	_check(float(mat.get_shader_parameter(&"dark")) > 0.9, "...then black")
	_to(room, WinRoom.LENGTH_SEC - 0.01)
	room.step(0.02)
	_check(cs.current is TruckOutro and cs.playing_id == &"win", "the truck follows on the same call")
	_check(not gus.celebrating and not cut.active, "...the room's effects are put away")
	var truck := cs.current as TruckOutro
	_check(truck.stats == loop.run_stats.to_dict() and truck.captions.size() == story.ending_cards.size() and truck.captions[0] == story.ending_cards[0], "the truck gets the run's stats and the Night's ending cards as captions")
	_check(not truck._card.visible, "the stats card waits for the captions")
	_to(truck, 20.0)
	_check(truck._card.visible and left == 0, "the stats card is up on the truck")
	(truck._card.get_node("%Close") as Button).pressed.emit()
	_check(not cs.is_playing() and left == 1, "Continue ends the ride and leaves the session")
	_reset_world()


func _win_skip_late_endless() -> void:
	left = 0
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _frames(2)
	var room := cs.current as WinRoom
	_to(room, 1.5)
	cs.skip()
	_check(cs.is_playing() and cs.current is TruckOutro and cs.playing_id == &"win", "Skip on the room beat still plays the truck (it carries the stats)")
	_check(not gus.celebrating and not cut.active, "...with the room put away")
	cs.abort()
	_check(left == 1, "...and leaving the truck leaves the session")
	_reset_world()
	# a late peer rides the truck at once
	left = 0
	director._resumed_msec = Time.get_ticks_msec()
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _frames(2)
	_check(cs.playing_id == &"truck_outro" and cs.current is TruckOutro, "a late peer skips the room beat and rides the truck")
	director._resumed_msec = -1000000
	cs.abort()
	await _frames(1)
	_reset_world()
	# Endless never wins
	loop.mode = GameLoop.MODE_ENDLESS
	loop._set_phase(GameLoop.Phase.CAMPAIGN_WON)
	await _frames(3)
	_check(not cs.is_playing(), "Endless has no win cutscene")
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	await _frames(2)
	_check(cs.playing_id == &"fail", "...but fails like the Campaign")
	cs.abort()
	loop.mode = GameLoop.MODE_CAMPAIGN
	loop.night_index = 0
	director._close_card()
	director._over = true
	_reset_world()


# --- cutscenes skipped ------------------------------------------------------------------------------------------------------------------

func _skipped_cutscenes_keep_the_screens() -> void:
	CutsceneDirector.skip_cutscenes = true
	_check(not CutsceneDirector.plays_endings(), "skip_cutscenes: the endings are not cutscenes")
	loop._set_phase(GameLoop.Phase.GAME_OVER)
	await _frames(3)
	_check(not cs.is_playing() and director.card == null, "skip_cutscenes: Game over plays nothing")
	_check(phase_screen.visible and phase_screen._title.text == "Game over", "...and the PhaseScreen shows Game over as before")
	var begun := [0]
	director.start_run(func(seed_value: int) -> void: begun[0] = begun[0] + 1 + seed_value)
	_check(begun[0] == 1 and not cs.is_playing(), "skip_cutscenes: a fresh run starts at once (seed 0 = draw one)")
	CutsceneDirector.skip_cutscenes = false
