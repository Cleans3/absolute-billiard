extends SceneTree
## Two-peer gimmick probe (tests/net/pair.sh): the host sets a custom rack, fires a hard shot into a
## bomb_ball (scatter + self-remove), then a potted split_ball spawns a red and a shuffle re-rolls a ball.
## Every outcome must reach the client through the event stream or the rack/spawn/reroll RPCs: final
## positions ≤ 5 mm, retired flags and BallTypes identical per wire id.
##   tests/net/pair.sh tests/sync/gimmick_pair_probe.gd
## Prints `GIMMICKPAIR HOST OK` / `GIMMICKPAIR CLIENT OK`.

const GATE_M := 0.005

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var _rejected: StringName = &""
var _started := 0
var _ended := 0
var _foul := false
var _potted := 0


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("GIMMICKPAIR %s FAIL: %s" % [role.to_upper(), msg])
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


func _rest_dump() -> String:
	var lines := PackedStringArray()
	for b in rd.get_balls():
		var p := table.to_local(b.global_position)
		lines.append("%d %f %f" % [b.net_id, p.x, p.z])
	return "\n".join(lines)


func _run() -> void:
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
	rd = current_scene.get_node("RoundDirector")
	table = current_scene.get_node("Table")
	table.sim.shot_rejected.connect(func(r: StringName) -> void: _rejected = r)
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _started += 1)
	rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], f: bool) -> void:
		_ended += 1
		_foul = f)
	if role == "host":
		var gl: GameLoop = current_scene.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()  # Round 1 starts: RoundDirector spawns the rack and push_racks it
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	if role == "host":
		await _host()
	else:
		await _client()


func _dump() -> String:
	var lines := PackedStringArray()
	for b in rd.get_balls():
		var p := table.to_local(b.global_position)
		lines.append("%d %f %f %s %d" % [b.net_id, p.x, p.z, b.ball_type.id, 1 if b.retired else 0])
	return "\n".join(lines)


func _write(name: String, text: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Host: replace the Round's balls with `types` at `spots` (table-local), and push that rack.
func _custom_rack(types: Array, spots: Array) -> Array[Ball]:
	rd._clear_balls()
	var head: Vector3 = table.layout.spots.head
	rd._cue_ball = rd._spawn(RoundDirector.CUE_TYPE, Vector2(head.x, head.z), 0)
	var out: Array[Ball] = []
	for i in types.size():
		out.append(rd._spawn(RackDropper.ball_type(StringName(types[i])), spots[i], i + 1))
	rd._next_net_id = types.size() + 1
	rd._push_rack_rpc.rpc(rd._round_id, rd._seed, rd._rack_blob())
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "custom rack at rest")
	return out


func _host() -> void:
	for i in 120:
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	# phase 1: a hard shot into a bomb with a neighbour inside the blast radius and one far outside
	await _custom_rack(["bomb_ball", "red_basic", "red_basic"], [Vector2(-0.3, 0.0), Vector2(-0.3, 0.55), Vector2(1.3, -0.9)])
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.RIGHT
	intent.power = 1.0
	table.sim.request_shot(intent)
	await table.sim.all_resting  # request_shot strikes synchronously; shot_started_net already fired
	await create_timer(0.5).timeout
	_write("p1", _dump())
	await _until(func() -> bool: return FileAccess.file_exists(_file("p1_ok")), "client phase 1", 30.0)
	# phase 2: split spawn + shuffle over the wire
	var objs := await _custom_rack(["split_ball", "red_basic", "red_basic", "red_basic"], [Vector2(-0.4, 0.3), Vector2(0.6, -0.3), Vector2(0.9, 0.5), Vector2(0.2, -0.7)])
	var split := objs[0]
	rd._rest_pos[split] = rd._local(split)
	split.is_pocketed = true
	split.retire()  # a pot, as far as the wire is concerned: POCKETED-then-RETIRED flags
	rd._potted = [split] as Array[Ball]
	rd._spawn_splits()
	rd._potted = [] as Array[Ball]
	rd._shuffle(2)
	await create_timer(0.8).timeout
	_write("p2", _dump())
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("GIMMICKPAIR HOST OK")
	quit(0)


func _compare(name: String) -> float:
	var worst := 0.0
	var seen := 0
	for line in FileAccess.get_file_as_string(_file(name)).split("\n"):
		var p := line.split(" ")
		var mine: Ball = null
		for b in rd.get_balls():
			if b.net_id == int(p[0]):
				mine = b
		assert(mine != null, "%s: client has no ball %s" % [name, p[0]])
		assert(mine.ball_type.id == p[3], "%s: ball %s is %s on the client, %s on the host" % [name, p[0], mine.ball_type.id, p[3]])
		assert((1 if mine.retired else 0) == int(p[4]), "%s: retired flag of ball %s differs" % [name, p[0]])
		if int(p[4]) == 0:
			var l := table.to_local(mine.global_position)
			worst = maxf(worst, Vector2(l.x - float(p[1]), l.z - float(p[2])).length())
		seen += 1
	assert(seen == rd.get_balls().size(), "%s: client has %d balls, host %d" % [name, rd.get_balls().size(), seen])
	return worst


func _client() -> void:
	await _until(func() -> bool: return FileAccess.file_exists(_file("p1")), "host phase 1", 40.0)
	await create_timer(1.5).timeout
	var w1 := _compare("p1")
	var bomb: Ball = null
	for b in rd.get_balls():
		if b.ball_type.id == "bomb_ball":
			bomb = b
	assert(bomb != null and bomb.retired and not bomb.is_pocketed, "bomb removed itself on the client")
	print("gimmickpair: phase 1 worst error %.2f mm" % (w1 * 1000.0))
	assert(w1 <= GATE_M, "phase 1 positions off by %.2f mm" % (w1 * 1000.0))
	_write("p1_ok", "1")
	await _until(func() -> bool: return FileAccess.file_exists(_file("p2")), "host phase 2", 40.0)
	await create_timer(1.0).timeout
	var w2 := _compare("p2")
	print("gimmickpair: phase 2 worst error %.2f mm" % (w2 * 1000.0))
	assert(w2 <= GATE_M, "phase 2 positions off by %.2f mm" % (w2 * 1000.0))
	_write("client_done", "1")
	print("GIMMICKPAIR CLIENT OK")
	quit(0)
