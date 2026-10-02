extends SceneTree
## Two-peer skins probe (run through tests/net/pair.sh, 06 P18): each peer equips its own skins in its own profile
## dir; the client's reach the host's roster (validated: an unknown id is refused), both peers dress the client's avatar
## in its character skin, and every Round's bar pick is one of the crew's bar skins, identical on both peers, equal to
## what the campaign seed dictates, and really on the room's materials and the felt.
##   tests/net/pair.sh tests/player/skins_pair_probe.gd
## Prints `SKINSPAIR HOST OK` / `SKINSPAIR CLIENT OK`.

const HOST_CHAR := &"pool_king"
const HOST_BAR := &"tiki"
const CLIENT_CHAR := &"high_roller"
const CLIENT_BAR := &"vaporwave"
const BARS: Array[StringName] = [HOST_BAR, CLIENT_BAR]

var role := ""
var port := 0
var nm: Node
var level: Node
var director: BarSkinDirector
var dir := ""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("SKINSPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _flag(name: String, text := "1") -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wait_flag(name: String, sec := 30.0) -> String:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, sec)
	return FileAccess.get_file_as_string(_file(name))


func _worn(peer_id: int) -> StringName:
	var slot := level.get_node("PlayerSlots").get_node_or_null(str(peer_id)) as PlayerSlot
	return slot.player.humanoid.skin().id


func _run() -> void:
	dir = "user://pair_skins_%s_%d" % [role, OS.get_process_id()]
	SaveManager.root = dir  # each peer its own profile: they would otherwise share one file
	if role == "host":
		SkinCatalog.equip_character(HOST_CHAR)
		SkinCatalog.equip_bar(HOST_BAR)
	else:
		SkinCatalog.equip_character(CLIENT_CHAR)
		SkinCatalog.equip_bar(CLIENT_BAR)
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	if role == "host":
		nm.host(nm.Transport.ENET_DIRECT)
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		await _until(func() -> bool: return nm.get_roster()[1].bar_skin == CLIENT_BAR, "the client's skins in the roster")
		var r: Array = nm.get_roster()
		if r[0].char_skin != HOST_CHAR or r[0].bar_skin != HOST_BAR or r[1].char_skin != CLIENT_CHAR or r[1].bar_skin != CLIENT_BAR:
			_fail("roster skins %s" % [r])
		nm.start_game()
	else:
		nm.join_direct("127.0.0.1", port)
		await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
		await _until(func() -> bool: return nm.get_roster()[1].bar_skin == CLIENT_BAR, "my skins in the mirrored roster")
		var r: Array = nm.get_roster()
		if r[0].char_skin != HOST_CHAR or r[1].char_skin != CLIENT_CHAR:
			_fail("mirrored roster skins %s" % [r])
	await _until(func() -> bool: return current_scene != null and current_scene.name == "MainLevel", "MainLevel")
	level = current_scene
	director = level.get_node("BarSkins")
	var gl: GameLoop = level.get_node("GameLoop")
	await _until(func() -> bool: return level.get_node("PlayerSlots").get_child_count() == 2, "both slots")
	var client_id := int(nm.get_roster()[1].peer_id)
	# avatars: the client wears its own skin on both peers, the host its own
	if _worn(client_id) != CLIENT_CHAR or _worn(1) != HOST_CHAR:
		_fail("avatars wear client=%s host=%s" % [_worn(client_id), _worn(1)])
	if role == "host":
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
	await _until(func() -> bool: return director.current != null, "the room's first bar skin")
	_check_room(gl, 0)
	var other_role := "client" if role == "host" else "host"
	await _same_bar("bar0", other_role)
	if role == "host":
		gl.advance()  # Round 1: a new (Night, Round) key, a new pick
	# the pick goes out before round_state on the same channel, so a client at round 1 has already applied it
	await _until(func() -> bool: return gl.round_index == 1, "Round 1")
	_check_room(gl, 1)
	await _same_bar("bar1", other_role)
	_flag("%s_done" % role)
	await _wait_flag("%s_done" % other_role)
	await create_timer(0.5).timeout
	DirAccess.remove_absolute(dir.path_join("profile.json"))
	DirAccess.remove_absolute(dir)
	print("SKINSPAIR %s OK" % role.to_upper())
	quit(0)


func _same_bar(tag: String, other_role: String) -> void:
	var mine := "%s:%d" % [director.current.id, director.current_owner]
	_flag("%s_%s" % [role, tag], mine)
	if (await _wait_flag("%s_%s" % [other_role, tag])) != mine:
		_fail("%s: this peer shows %s, the other shows something else" % [tag, mine])


## The shown skin is one of the crew's, is the one the seed dictates for this Round, and is on the room and the felt.
func _check_room(gl: GameLoop, round_index: int) -> void:
	var skin := director.current
	if not BARS.has(skin.id):
		_fail("bar skin %s is not one of the crew's %s" % [skin.id, BARS])
	if role == "host":  # clients never learn the campaign seed: they are checked against the host's pick by `_same_bar`
		var key := BarSkinDirector.round_key(gl.campaign_seed, gl.current_night().night_number, round_index)
		var want := BarSkinDirector.pick_entry(nm.get_roster(), key)
		if want.bar_skin != skin.id or want.peer_id != director.current_owner:
			_fail("Round %d shows %s (peer %d), the seed dictates %s (peer %d)" % [round_index, skin.id, director.current_owner, want.bar_skin, want.peer_id])
	var room: BarRoom = level.get_node("BarRoom")
	var table: Table = level.get_node("Table")
	if not room.get(&"_mats")[&"wall"].albedo_color.is_equal_approx(skin.wall_color) or not table.felt_color.is_equal_approx(skin.felt_color):
		_fail("room wall / felt do not carry %s" % skin.id)
