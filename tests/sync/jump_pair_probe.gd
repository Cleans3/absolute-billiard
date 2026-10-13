extends SceneTree
## Two-peer jump probe (adhoc-1014a V4, run through tests/net/pair.sh): the client is the shooter and requests a 50 degree stroke at
## 0.5 power over the wire (the host's stock cue has the Jump), the host's Jolt ball hops, and the client presents the same hop: at every
## frame of the first second of the shot the position the client drew (BallReplica at the playback tick, through ENet, the codec and
## BallMotion) is within 5 mm of where the host's ball was at that tick, the client saw the ball rise, and the rest positions match.
##   tests/net/pair.sh tests/sync/jump_pair_probe.gd
## Prints `JUMPPAIR HOST OK` / `JUMPPAIR CLIENT OK`.

const GATE_M := 0.005
const WINDOW_SEC := 1.0  # the flight, the touch-down and the bounces after it
const MIN_HOP_M := 0.03

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var _rejected: StringName = &""
var _started := 0
var _ended := 0
var _rec := false
var _series := PackedStringArray()  # host: "tick x y z" of the cue ball, one per physics frame of the shot
var _client_series := PackedVector4Array()  # client: (tick, x, y, z) as the client drew it


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("JUMPPAIR %s FAIL: %s" % [role.to_upper(), msg])
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
	rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], _f: bool) -> void: _ended += 1)
	if role == "host":
		var gl: GameLoop = current_scene.get_node("GameLoop")
		await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		gl.advance()  # Round 1 starts: RoundDirector spawns the rack and push_racks it
	await _until(func() -> bool: return rd.get_balls().size() > 5 and rd.get("_round_active"), "rack on this peer")
	if role == "host":
		await _host()
	else:
		await _client()


func _cue(b_list: Array[Ball]) -> Ball:
	for b in b_list:
		if b.is_cue_ball:
			return b
	return null


## SceneTree's own tick: runs in the same phase as PhysicsSim's, so the position read here is the one an event of this tick carries.
func _physics_process(_delta: float) -> bool:
	if _rec and role == "host":
		var c := _cue(rd.get_balls())
		if c != null:
			_series.append("%d %f %f %f" % [Engine.get_physics_frames(), c.global_position.x, c.global_position.y, c.global_position.z])
	return false


func _host() -> void:
	var client_id := int(nm.get_roster()[1].peer_id)
	for i in 120:  # let the rack settle, and give the client time to spawn it
		await physics_frame
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	assert(rd.current_shooter_id == 1, "host shoots first")
	rd._set_shooter_rpc.rpc(client_id)
	await _until(func() -> bool: return rd.current_shooter_id == client_id, "set_shooter to the client")
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _rec = true)
	await table.sim.shot_started_net
	await table.sim.all_resting
	await create_timer(0.5).timeout
	_rec = false
	var f := FileAccess.open(_file("host_rest"), FileAccess.WRITE)
	f.store_string(_rest_dump())
	f.close()
	var g := FileAccess.open(_file("host_series"), FileAccess.WRITE)
	g.store_string("\n".join(_series))
	g.close()
	await _until(func() -> bool: return FileAccess.file_exists(_file("client_done")), "client verdict", 30.0)
	print("JUMPPAIR HOST OK")
	quit(0)


func _process(_delta: float) -> bool:
	if _rec and role == "client":
		var c := _cue(table.sim.get_balls())
		if c != null:
			var out := BallMotion.State.new()
			var t: float = table.sim.playback_tick_f()
			if table.sim._replica.sample(c.net_id, t, c.motion, out):  # what PhysicsSim._process draws, at the same instant
				_client_series.append(Vector4(t, out.pos.x, out.pos.y, out.pos.z))
	return false


func _client() -> void:
	var me := root.multiplayer.get_unique_id()
	await _until(func() -> bool: return table.sim.get_balls().size() > 5, "client balls registered")
	await _until(func() -> bool: return rd.current_shooter_id == me, "set_shooter to me")
	var cue := _cue(rd.get_balls())
	var intent := ShotIntent.new()
	intent.aim_dir = Vector2.LEFT  # toward the head rail, away from the rack: a hop of about a metre stays on the cloth
	intent.power = 0.5
	intent.elevation_deg = 50.0
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _rec = true)
	for i in 20:  # the rack may still be settling on the host: `balls_moving` outranks the rest
		_rejected = &""
		table.sim.request_shot(intent)
		await create_timer(0.5).timeout
		if _started == 1:
			break
	await _until(func() -> bool: return _started == 1, "shot_started_net")
	await _until(func() -> bool: return FileAccess.file_exists(_file("host_series")), "host series", 40.0)
	await create_timer(1.0).timeout  # playback trails the host by ~100 ms + latency
	_rec = false
	assert(_ended == 1, "shot_ended re-emitted on the client (got %d)" % _ended)
	# the host's cue ball, tick by tick, against what this client drew at that tick
	var host_t := PackedFloat64Array()
	var host_p := PackedVector3Array()
	for line in FileAccess.get_file_as_string(_file("host_series")).split("\n"):
		var q := line.split(" ")
		if q.size() == 4:
			host_t.append(float(q[0]))
			host_p.append(Vector3(float(q[1]), float(q[2]), float(q[3])))
	assert(host_t.size() > 60, "the host recorded the shot (%d ticks)" % host_t.size())
	var floor_y := cue.motion.floor_y
	var host_max_h := 0.0
	for p in host_p:
		host_max_h = maxf(host_max_h, p.y - floor_y)
	var worst := 0.0
	var seen_h := 0.0
	var compared := 0
	var t_start := host_t[0]
	var j := 1
	for v in _client_series:
		if v.x < t_start or v.x > t_start + WINDOW_SEC * PhysicsSim.LIVE_TICK:
			continue
		while j < host_t.size() - 1 and host_t[j] < v.x:
			j += 1
		var w := clampf((v.x - host_t[j - 1]) / maxf(host_t[j] - host_t[j - 1], 1e-6), 0.0, 1.0)
		var hp := host_p[j - 1].lerp(host_p[j], w)
		worst = maxf(worst, Vector3(v.y, v.z, v.w).distance_to(hp))
		seen_h = maxf(seen_h, v.z - floor_y)
		compared += 1
	print("jumppair: host hop %.0f mm, client drew %.0f mm; %d frames of the first %.1f s, worst client-vs-host error %.2f mm" % [host_max_h * 1000.0, seen_h * 1000.0, compared, WINDOW_SEC, worst * 1000.0])
	assert(host_max_h > MIN_HOP_M, "the host's ball hopped (%.0f mm)" % (host_max_h * 1000.0))
	assert(seen_h > MIN_HOP_M, "the client saw the ball rise (%.0f mm)" % (seen_h * 1000.0))
	assert(compared > 15, "enough client frames compared (%d)" % compared)
	assert(worst <= GATE_M, "client drew the ball %.2f mm from the host's" % (worst * 1000.0))
	var rest_worst := 0.0
	for line in FileAccess.get_file_as_string(_file("host_rest")).split("\n"):
		var p := line.split(" ")
		var b: Ball = table.sim._by_id[int(p[0])]
		if b == null or b.retired:
			continue
		var l := table.to_local(b.global_position)
		rest_worst = maxf(rest_worst, Vector2(l.x - float(p[1]), l.z - float(p[2])).length())
	print("jumppair: rest positions %.2f mm apart" % (rest_worst * 1000.0))
	assert(rest_worst <= GATE_M, "client rest positions off by %.2f mm" % (rest_worst * 1000.0))
	var d2 := FileAccess.open(_file("client_done"), FileAccess.WRITE)
	d2.store_string("1")
	d2.close()
	print("JUMPPAIR CLIENT OK")
	quit(0)
