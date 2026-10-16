extends SceneTree
# PAIR_TIMEOUT=120
## The cue rack over the network (docs/plan/08 §2.9, through tests/net/pair.sh). The client takes a cue, then the host does; both
## peers agree on every slot and on who holds what, each sees the other's stick in the other's hand, a second take is refused to the
## client; the host swings at the client standing in front of it and knocks it down (on both peers), then throws its cue at the client
## 3 m away and knocks it down again (step 2); a `reset_campaign` reaches the client; a client that leaves holding a cue puts it back on
## the host's rack.
##   tests/net/pair.sh tests/net/cue_rack_pair_probe.gd
## Prints `CUE RACK HOST OK` / `CUE RACK CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var world: WorldInteractions
var rack: CueRack
var client_id := 0
var rejected: Array[StringName] = []


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("CUE RACK %s FAIL: %s" % [role.to_upper(), msg])
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


func _put(name: String, text := "1") -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _read(name: String) -> String:
	await _until(func() -> bool: return FileAccess.file_exists(_file(name)), name, 40.0)
	await create_timer(0.1).timeout
	return FileAccess.get_file_as_string(_file(name))


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


## The held stick of `peer` is drawn on this peer.
func _stick_shown(peer: int) -> bool:
	var s := rack.get_node_or_null("Held%d" % peer) as MeshInstance3D
	return s != null and s.visible


func _run() -> void:
	CueRack.required = true
	var dir := OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(dir)
	SaveManager.root = dir
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
	var gl: GameLoop = level.get_node("GameLoop")
	world = level.get_node("WorldInteractions")
	rack = level.get_node("CueRack")
	client_id = int(nm.get_roster()[1].peer_id)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen to end")
	world.interaction_rejected.connect(func(k: StringName, why: StringName) -> void:
		if k == CueRack.KIND:
			rejected.append(why))
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	var at := (rack.get_node("Prop") as Node3D).global_position
	world.player_position_source = func(_id: int) -> Vector3: return at + Vector3(0.0, 0.0, 0.5)  # everyone stands at the rack
	_put("host_ready")
	await _until(func() -> bool: return rack.holds(client_id), "the client's take on the host")
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	await _until(func() -> bool: return rack.holds(1), "the host's own take")
	await _check(rack.held[client_id] == 1 and rack.held[1] == 2 and rack.slot_cue == PackedInt32Array([0, 0, 3, 4, 5]), "host: client holds 1, host 2, slots %s" % str(rack.slot_cue))
	_put("host_took")
	await _read("client_checked")
	await _until(func() -> bool: return _stick_shown(client_id), "the client's stick in its puppet's hand", 5.0)
	var p: Player = level.get_node("PlayerSpawner").call(&"get_player", client_id)
	var stick := rack.get_node("Held%d" % client_id) as MeshInstance3D
	await _check(p != null and stick.global_position.distance_to(p.global_position) < 1.2, "the client's stick is by the client's puppet")
	await _host_hits(p)
	rack.reset_campaign(2)
	await _check(rack.cues_on_rack() == 2 and rack.held.is_empty(), "host: two cues after reset_campaign(2)")
	_put("host_reset")
	await _read("client_holds_again")
	await _until(func() -> bool: return rack.holds(client_id), "the client's second take on the host")
	await _until(func() -> bool: return nm.get_roster().size() == 1, "the client to leave", 30.0)
	await _until(func() -> bool: return not rack.holds(client_id), "the leaver's cue back on the rack", 5.0)
	await _check(rack.cues_on_rack() == 2 and rack.slot_cue[0] == 1, "host: the leaver's cue 1 is in slot 1 again: %s" % str(rack.slot_cue))
	print("CUE RACK HOST OK")
	quit(0)


func _client() -> void:
	await _read("host_ready")
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	await _until(func() -> bool: return rack.holds(client_id), "my take")
	await _check(rack.held[client_id] == 1 and rack.cues_on_rack() <= 4, "client: I hold cue 1 (the host may already hold 2): held %s slots %s" % [str(rack.held), str(rack.slot_cue)])
	await _read("host_took")
	await _until(func() -> bool: return rack.holds(1), "the host's take on the client")
	await _check(rack.held[1] == 2 and rack.slot_cue == PackedInt32Array([0, 0, 3, 4, 5]), "client: the host holds 2, slots %s" % str(rack.slot_cue))
	await _until(func() -> bool: return _stick_shown(1), "the host's stick in its puppet's hand", 5.0)
	await _until(func() -> bool: return _stick_shown(client_id), "my own stick in my hand", 5.0)
	rejected.clear()
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	await _until(func() -> bool: return not rejected.is_empty(), "the refusal of a second take")
	await _check(rejected[0] == &"has_cue", "a second take is has_cue: %s" % str(rejected))
	_put("client_checked")
	await _client_gets_hit()
	await _read("host_reset")
	await _until(func() -> bool: return rack.cues_on_rack() == 2 and rack.held.is_empty(), "reset_campaign(2) on the client")
	await _check(not _stick_shown(client_id) and not _stick_shown(1), "no stick in anyone's hand after the reset")
	world.request(CueRack.KIND, 0, {&"op": &"take"})
	await _until(func() -> bool: return rack.holds(client_id), "my second take")
	_put("client_holds_again")
	await create_timer(0.5).timeout
	print("CUE RACK CLIENT OK")
	quit(0)


func _me() -> Player:
	return level.get_node("PlayerSpawner").call(&"get_local_player") as Player


## Host: swing at the client 1 m ahead, then throw at it 3 m ahead; both must land on it.
func _host_hits(puppet: Player) -> void:
	var me := _me()
	me.global_position = Vector3(0.0, 0.0, 2.0)
	me.rotation.y = PI  # facing +z
	me.head.rotation.x = 0.0
	me.velocity = Vector3.ZERO
	var outcome := {}
	world.interaction_applied.connect(func(_p: int, k: StringName, _t: int, pl: Dictionary) -> void:
		if k == CueRack.SWING_KIND or k == CueRack.THROW_KIND:
			outcome[k] = pl.duplicate())
	_put("host_at", "2.0")
	await _read("client_at_1")
	await _until(func() -> bool: return puppet.global_position.distance_to(Vector3(0.0, 0.0, 3.0)) < 0.3, "the client's puppet 1 m ahead")
	me.swing_cue()
	await _until(func() -> bool: return outcome.has(CueRack.SWING_KIND), "the swing applied")
	await _check(int(outcome[CueRack.SWING_KIND].hit) == client_id, "the swing hits the client: %s" % str(outcome[CueRack.SWING_KIND]))
	await _until(func() -> bool: return puppet.mode == Player.Mode.RAGDOLL, "the client's puppet knocked limp", 3.0)
	_put("host_swung")
	await _read("client_at_3")
	await _until(func() -> bool: return puppet.mode != Player.Mode.RAGDOLL and puppet.global_position.distance_to(Vector3(0.0, 0.0, 5.0)) < 0.3, "the client up, 3 m ahead", 10.0)
	await create_timer(0.3).timeout
	me.global_position = Vector3(0.0, 0.0, 2.0)
	me.rotation.y = PI
	me.head.rotation.x = 0.0
	for i in 3:
		await physics_frame
	me.throw_cue()
	await _until(func() -> bool: return outcome.has(CueRack.THROW_KIND), "the throw applied")
	await _check(int(outcome[CueRack.THROW_KIND].hit) == client_id, "the thrown cue hits the client: %s" % str(outcome[CueRack.THROW_KIND]))
	await _until(func() -> bool: return puppet.mode == Player.Mode.RAGDOLL, "the client's puppet knocked by the throw", 3.0)
	_put("host_threw")
	await _read("client_knocked_twice")


## Client: stand where the host can hit me, twice.
func _client_gets_hit() -> void:
	var me := _me()
	await _read("host_at")
	me.global_position = Vector3(0.0, 0.0, 3.0)
	me.velocity = Vector3.ZERO
	_put("client_at_1")
	await _until(func() -> bool: return me.mode == Player.Mode.RAGDOLL, "the swing to knock me down", 10.0)
	await _read("host_swung")
	await _until(func() -> bool: return me.mode == Player.Mode.WALK, "getting up", 10.0)
	me.global_position = Vector3(0.0, 0.0, 5.0)
	me.velocity = Vector3.ZERO
	_put("client_at_3")
	await _until(func() -> bool: return me.mode == Player.Mode.RAGDOLL, "the thrown cue to knock me down", 15.0)
	await _read("host_threw")
	await _until(func() -> bool: return me.mode == Player.Mode.WALK, "getting up again", 10.0)
	_put("client_knocked_twice")
