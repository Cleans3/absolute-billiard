extends SceneTree
# PAIR_TIMEOUT=150
## The story over the network (REQ#adhoc-1011a:story S3, run through tests/net/pair.sh).
##   1. The intro cards are local: each peer opens its own, the client skipping its cards leaves the host's open and the
##      host reading its four never touches the client's.
##   2. The phone rings on both peers; the CLIENT answers: the host validates and both peers play Moe's call (the same
##      subtitle at the phone, blips from the phone, Gus silent); a second answer is refused with `already_answered`.
##   3. A peer that comes back from the background after the call (a rejoin) is told the phone was answered, silently:
##      it does not ring again and Moe does not speak again. The host's hook is `peers_away_changed`, which fires before
##      the first Round, when RoundDirector.send_full_state has nothing to send.
##   tests/net/pair.sh tests/story/story_pair_probe.gd
## Prints `STORY HOST OK` / `STORY CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var gl: GameLoop
var world: WorldInteractions
var director: StoryDirector
var cards: StoryCards
var phone: Phone
var gus: Bartender
var client_id := 0
var _rejected: Array = []


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("STORY %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 20.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _file(name: String) -> String:
	return OS.get_environment("PAIR_DIR") + "/" + name


func _flag(name: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string("1")
	f.close()


func _wait_flag(name: String, sec := 30.0) -> void:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, sec)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _run() -> void:
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	DirAccess.make_dir_recursive_absolute(dir + "/checkpoints")
	SaveManager.root = dir
	StoryDirector.auto_intro_cards = true  # the cards no longer open by themselves (06 P44); this probe is about them
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	if role == "host":
		nm.host(nm.Transport.ENET_DIRECT)
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		nm.start_game()
	else:
		nm.join_direct("127.0.0.1", port)
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
	await _until(func() -> bool: return current_scene != null and current_scene.name == "MainLevel", "MainLevel")
	level = current_scene
	gl = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	director = level.get_node("StoryDirector")
	cards = level.get_node("UILayer/StoryCards")
	gus = level.get_node("Bar/Bartender")
	client_id = int(nm.get_roster()[1].peer_id)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen ends")
	phone = get_first_node_in_group(&"story_phone") as Phone
	await _check(phone != null and phone.prop != null, "the wall phone and its use target exist on this peer")
	world.interaction_rejected.connect(func(k: StringName, r: StringName) -> void: _rejected.append([k, r]))
	if role == "host":
		world.player_position_source = func(_id: int) -> Vector3: return phone.prop.global_position + Vector3(1.0, 0.0, 0.0)
	var night1: StoryNight = gl.current_night().story
	await _cycle_cards(night1)
	await _cycle_call(night1)
	await _cycle_rejoin(night1)
	print("STORY %s OK" % role.to_upper())
	quit(0)


## 1: cards are local.
func _cycle_cards(night1: StoryNight) -> void:
	await _until(func() -> bool: return cards.is_open(), "this peer's Night 1 cards")
	await _check(cards.cards == night1.intro_cards, "each peer shows the Night's own cards")
	if role == "client":
		cards.close()
		_flag("client_skipped")
		await _wait_flag("host_read")
		await _check(not cards.is_open(), "the host reading its cards did not reopen the client's")
	else:
		await _wait_flag("client_skipped")
		await create_timer(0.4).timeout
		await _check(cards.is_open() and cards.index == 0, "the client skipping its cards did not close or move the host's")
		for i in night1.intro_cards.size():
			cards.advance()
		await _check(not cards.is_open(), "reading the last card closes the host's cards")
		_flag("host_read")


## 2: the phone rings on both peers; the client answers; both play the call.
func _cycle_call(night1: StoryNight) -> void:
	await _until(func() -> bool: return director.ringing and phone.is_ringing() and phone.prop.collision_layer == Interactable.LAYER, "the phone rings on this peer")
	if role == "client":
		phone.prop.try_use()
	await _until(func() -> bool: return director.answered and director.calling, "the call starts on this peer")
	await _check(not director.ringing and not phone.is_ringing(), "answering stops the ring on this peer")
	await _check(phone.bubble.text() == "Moe: " + night1.call[0], "the first subtitle at the phone: " + phone.bubble.text())
	await _check(gus.chat.is_holding(), "Gus holds his tongue on this peer")
	await _until(func() -> bool: return phone.voice.blips_played > 0, "Moe's blips on this peer")
	_flag(role + "_in_call")
	await _wait_flag(("client" if role == "host" else "host") + "_in_call")
	# a second answer, by the host this time, is refused
	if role == "host":
		world.request(&"answer_phone", 0)
		await _check(_rejected == [[&"answer_phone", &"already_answered"]], "a second answer is refused: %s" % [_rejected])
		await _check(WaitText.interaction(&"answer_phone", &"already_answered") == "Somebody already picked up", "and says so")
	for i in range(1, night1.call.size() + 1):
		director._call_left = 0.0  # skip the wait, not the line
		await create_timer(0.1).timeout
	await _until(func() -> bool: return not director.calling and not gus.chat.is_holding(), "the call ends and Gus may talk")
	_flag(role + "_call_done")
	await _wait_flag(("client" if role == "host" else "host") + "_call_done")


## 3: a peer back from the background is told, silently, that the phone was answered.
func _cycle_rejoin(_night1: StoryNight) -> void:
	if role == "client":
		director.answered = false  # as a freshly loaded level would be, it has its own Intermission to ring for
		director.ringing = true
		phone.set_ringing(true)
		await _check(phone.is_ringing(), "(the client's fresh state rings)")
		var blips := phone.voice.blips_played
		nm.set_backgrounded(true)
		await create_timer(0.3).timeout
		nm.set_backgrounded(false)
		await _until(func() -> bool: return director.answered, "the host's replay reaches the client")
		await _check(not director.ringing and not phone.is_ringing() and not director.calling, "back from the background: it does not ring again and Moe does not speak again")
		await _check(phone.voice.blips_played == blips and not gus.chat.is_holding(), "the replay is silent")
		_flag("client_replayed")
	else:
		await _wait_flag("client_replayed")
		await _check(director.answered and not director.ringing, "the host still has it answered and quiet")
