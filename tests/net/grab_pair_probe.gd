extends SceneTree
# PAIR_TIMEOUT=150
## Step 4 over the network (docs/plan/08 §2.9, through tests/net/pair.sh): the client grabs a ball in a live Round: both peers have it
## out and hidden, the host has it frozen without a collider; the client throws it: both peers see it back on the cloth, at the same
## spot once the host's rest frame lands. Then the client walks on the table: both peers print its steps; it takes the towel and wipes
## them: the host's picture is clean there too.
##   tests/net/pair.sh tests/net/grab_pair_probe.gd
## Prints `GRAB HOST OK` / `GRAB CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var level: Node
var world: WorldInteractions
var grab: BallGrab
var prints: Footprints
var rd: RoundDirector
var gl: GameLoop
var table: Table
var client_id := 0
var stand_at := Vector3.INF  # host: where it believes the client stands (the reach tests)


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("GRAB %s FAIL: %s" % [role.to_upper(), msg])
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


func _ball(net_id: int) -> Ball:
	for b in rd.get_balls():
		if b.net_id == net_id:
			return b
	return null


func _run() -> void:
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
	gl = level.get_node("GameLoop")
	rd = level.get_node("RoundDirector")
	world = level.get_node("WorldInteractions")
	grab = level.get_node("BallGrab")
	prints = level.get_node("Footprints")
	table = level.get_node("Table")
	client_id = int(nm.get_roster()[1].peer_id)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen to end")
	if role == "host":
		await _host()
	else:
		await _client()


func _host() -> void:
	world.player_position_source = func(id: int) -> Vector3: return stand_at if id == client_id else Vector3(0.0, 0.0, 6.0)
	await _read("client_ready")
	gl.advance()
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and not rd.staging and rd.table.sim.awake == 0, "a live Round at rest")
	var b: Ball = null
	for x in rd.get_balls():
		if not x.is_cue_ball:
			b = x
			break
	stand_at = Vector3(b.global_position.x, 0.0, b.global_position.z + 1.0)
	_put("host_ball", str(b.net_id))
	await _until(func() -> bool: return grab.out.has(b.net_id), "the client's grab on the host")
	await physics_frame
	await _check(not b.visible and b.freeze and (b.get_node("Shape") as CollisionShape3D).disabled and grab.held.get(client_id, -1) == b.net_id, "host: the ball is out, hidden, frozen, collider off, in the client's hand")
	_put("host_saw_grab")
	await _until(func() -> bool: return not grab.out.has(b.net_id), "the ball back on the host", 10.0)
	await _until(func() -> bool: return rd.table.sim.awake == 0, "the table at rest again", 6.0)
	await create_timer(1.5).timeout  # the rest-frame guard's beat
	var at := b.global_position
	_put("host_back", var_to_str(at))
	# footprints: the client walks on the table, then wipes
	await _read("client_walked")
	await create_timer(0.5).timeout
	var dirt := prints.dirt_fraction()
	await _check(dirt > 0.0005, "host: the client's walk on the table left prints here too (%.4f)" % dirt)
	_put("host_saw_prints", var_to_str(dirt))
	stand_at = (prints.get_node("Prop") as Node3D).global_position + Vector3(0.3, 0.0, 0.0)
	_put("host_towel_reach")
	await _until(func() -> bool: return prints.towel_holder == client_id, "the client's towel on the host")
	stand_at = table.to_global(Vector3(0.2, 0.0, table.spec.width_m * 0.5 + 0.5))
	_put("host_wipe_reach")
	await _read("client_wiped")
	await create_timer(0.5).timeout
	var left := prints.dirt_fraction()
	await _check(left < dirt * 0.7, "host: the client's wipes cleaned the host's picture too (%.4f -> %.4f)" % [dirt, left])
	_put("host_done")
	print("GRAB HOST OK")
	quit(0)


func _client() -> void:
	_put("client_ready")
	var id := int(await _read("host_ball"))
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and _ball(id) != null, "the live Round here")
	var b := _ball(id)
	world.request(BallGrab.GRAB, id, {})
	await _until(func() -> bool: return grab.out.has(id) and grab.holds(client_id), "my grab")
	await _check(not b.visible, "client: the grabbed ball is hidden here")
	await _read("host_saw_grab")
	grab.request_throw(Vector3(0.0, 0.2, 1.0))
	await _until(func() -> bool: return not grab.out.has(id) and b.visible, "the ball back here", 10.0)
	var host_at: Vector3 = str_to_var(await _read("host_back"))
	await _until(func() -> bool: return b.global_position.distance_to(host_at) < 0.005, "the ball at the host's spot (client %s, host %s)" % [b.global_position, host_at], 6.0)
	# walk on the table
	var me: Player = level.get_node("PlayerSpawner").call(&"get_local_player")
	var lid := table.spec.bed_height_m + table.spec.rail_height_m
	for i in 9:
		me.global_position = table.to_global(Vector3(-1.2 + i * 0.35, lid + 0.02, 0.3))
		me.velocity = Vector3.ZERO
		for k in 6:
			await process_frame
	await create_timer(0.3).timeout
	await _check(prints.dirt_fraction() > 0.0005, "client: my own walk left prints")
	_put("client_walked")
	await _read("host_saw_prints")
	me.global_position = Vector3(0.0, 0.0, 2.0)
	await _read("host_towel_reach")
	world.request(Footprints.TAKE, 0, {})
	await _until(func() -> bool: return prints.holds_towel(client_id), "the towel in my hand")
	await _read("host_wipe_reach")
	for k in 12:
		prints.request_wipe(table.to_global(Vector3(-1.2 + k * 0.28, table.spec.bed_height_m, 0.3)))
		await create_timer(0.4).timeout
	_put("client_wiped")
	await _read("host_done")
	print("GRAB CLIENT OK")
	quit(0)
