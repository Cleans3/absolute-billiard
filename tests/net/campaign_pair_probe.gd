extends SceneTree
# PAIR_TIMEOUT=170
## Whole-game composition over the network (REQ#int-1, run through tests/net/pair.sh): host and client play
## Night 1 end to end with scripted intents through request_shot (shooters alternate, one whiff foul, aimed
## at real balls so pots happen), a checkpoint lands on both peers each Round, the client buys a shop item
## (magnetic_pockets) and a drink (bar_nuts) through request_purchase, both vote on the Events, the next
## Round applies the item on both peers. At every Round boundary round_state / cash / viewers / shooter /
## owned / live effects are equal on both peers. pair.sh fails the run on any SCRIPT ERROR in either log.
##   tests/net/pair.sh tests/net/campaign_pair_probe.gd
## Prints `CAMPAIGN HOST OK` / `CAMPAIGN CLIENT OK`.

const SHOTS := [4, 3, 3]  # per Round: the shot budget the host sets (natural end = `shots`)
const MAGNETIC := 1.1

var role := ""
var port := 0
var nm: Node
var level: Node
var gl: GameLoop
var rd: RoundDirector
var table: Table
var eco: EconomyManager
var fx: EffectManager
var ev: EventScheduler
var stream: StreamManager
var me := 0
var _dir := ""
var _started := 0
var _ended := 0
var _fouls := 0
var _pots := 0
var _my_shots := 0
var _offer: Array[StringName] = []
var _events_applied := 0
var _rejected: StringName = &""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("CAMPAIGN %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 30.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _file(name: String) -> String:
	return OS.get_environment("PAIR_DIR") + "/" + name


func _touch(name: String, text := "1") -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _has(name: String) -> bool:
	return FileAccess.file_exists(_file(name))


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _run() -> void:
	_dir = OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(_dir)
	SaveManager.root = _dir
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
	table = level.get_node("Table")
	eco = level.get_node("EconomyManager")
	fx = level.get_node("EffectManager")
	ev = level.get_node("EventScheduler")
	stream = level.get_node("StreamManager")
	me = root.multiplayer.get_unique_id()
	table.sim.shot_started_net.connect(func(_i: int, _s: int, _b: int) -> void: _started += 1)
	table.sim.shot_rejected.connect(func(r: StringName) -> void: _rejected = r)
	rd.shot_ended.connect(func(_i: String, _s: int, _p: int, _t: Array[StringName], foul: bool) -> void:
		_ended += 1
		_fouls += 1 if foul else 0)
	rd.ball_potted.connect(func(_b: Ball, _s: String, _p: StringName) -> void: _pots += 1)
	ev.event_offer_ready.connect(func(_r: int, _t: int, ids: Array[StringName]) -> void: _offer = ids)
	ev.event_applied.connect(func(_i: StringName, _t: int, _m: float) -> void: _events_applied += 1)
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	if role == "host":
		eco.add_cash(2000, &"probe")  # the shop item + drink must be affordable and the quota payable

	for r in 3:
		await _intermission(r)
		await _round(r)
		await _boundary(r + 1)
	# the Night is over: Reckoning on both peers, fouls and pots really happened
	await _check(_ended >= 10, "played %d shots" % _ended)
	await _check(_fouls >= 1, "no foul was seen")
	print("campaign %s: %d shots, %d fouls, %d pots, %d of them mine" % [role, _ended, _fouls, _pots, _my_shots])
	await _check(_pots >= 1, "scripted intents potted nothing")
	if role == "host":
		await _until(func() -> bool: return _has("client_done"), "client verdict", 30.0)
		print("CAMPAIGN HOST OK")
	else:
		_touch("client_done")
		print("CAMPAIGN CLIENT OK")
	quit(0)


## Between Rounds: Events vote (before Rounds 2 and 3), the client shops once, the host starts the Round.
func _intermission(r: int) -> void:
	if r > 0:
		# Night 1's tier-2 pool can be empty (every tier-2 Event has min_night > 1): Round 3 may have no vote
		var t0 := Time.get_ticks_msec()
		while _offer.is_empty() and Time.get_ticks_msec() - t0 < (15000 if r == 1 else 4000):
			await create_timer(0.1).timeout
		if r == 1:
			await _check(not _offer.is_empty(), "no event offer for Round 2")
		if not _offer.is_empty():
			var pick := _offer[0] if role == "host" else _offer[_offer.size() - 1]
			ev.submit_event_vote.rpc_id(1, pick)
			_offer = []
	if r == 1:
		if role == "client":
			eco.request_purchase.rpc_id(1, &"magnetic_pockets", 0)
			await _until(func() -> bool: return eco.count_of(&"magnetic_pockets") == 1, "shop item mirrored", 10.0)
			eco.request_purchase.rpc_id(1, &"bar_nuts", 0)
		await _until(func() -> bool: return eco.count_of(&"magnetic_pockets") == 1, "shop item owned on this peer", 10.0)
		var drinker := int(nm.get_roster()[1].peer_id)  # the client drinks: the Effect is scoped to that peer
		await _until(func() -> bool: return fx.is_live(&"nuts_hype", drinker) or fx.is_live(&"nuts_hype"), "drink effect live on this peer", 10.0)
	if role == "host":
		await _until(func() -> bool: return _has("ready_%d" % r) or r == 0, "client ready", 30.0) if r > 0 else null
		await create_timer(0.5).timeout
		gl.advance()
	else:
		if r > 0:
			_touch("ready_%d" % r)


func _round(r: int) -> void:
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.ROUND_LIVE and gl.round_index == r + 1, "Round %d live" % (r + 1), 30.0)
	if role == "host":
		gl.shots_left = SHOTS[r]
		gl._push_state()
	await _until(func() -> bool: return rd.get_balls().size() > 5 and table.sim.get_balls().size() > 5, "rack", 10.0)
	if r >= 1:  # the shop item applied to this Round on every peer, and the chosen Event ran
		await _until(func() -> bool: return is_equal_approx(table.pocket_radius_mult, MAGNETIC), "magnetic_pockets on this peer's table", 10.0)
		await _check(_events_applied >= 1, "no Event applied here by Round %d" % (r + 1))
	var idle_ticks := 0
	while gl.phase == GameLoop.Phase.ROUND_LIVE:
		if rd.current_shooter_id == me and not rd.shot_in_progress and table.sim.awake == 0:
			await _take_shot(r)
		await create_timer(0.25).timeout
		idle_ticks += 1
		if idle_ticks > 800:
			_fail("Round %d did not end (phase %d, shots_left %d)" % [r + 1, gl.phase, gl.shots_left])
			await create_timer(60).timeout


func _take_shot(r: int) -> void:
	var cue: Ball = null
	var objs: Array[Ball] = []
	for b in rd.get_balls():
		if b.retired or b.is_pocketed:
			continue
		if b.is_cue_ball:
			cue = b
		elif b.ball_type.base_value > 0:
			objs.append(b)
	if cue == null or objs.is_empty():
		return
	var whiff := role == "host" and r == 0 and _my_shots == 1  # the scripted foul: too soft to reach anything
	var intent := ShotIntent.new()
	intent.shooter_id = me
	if whiff:
		var away := Vector3.ZERO
		var best := -1.0
		for a in 16:
			var dir := Vector3(cos(TAU * a / 16.0), 0.0, sin(TAU * a / 16.0))
			var nearest := INF
			for b in objs:
				nearest = minf(nearest, (b.global_position - cue.global_position).length() if (b.global_position - cue.global_position).normalized().dot(dir) > 0.7 else INF)
			if nearest > best:
				best = nearest
				away = dir
		intent.aim_dir = Vector2(away.x, away.z)
		intent.power = 0.06
	else:
		var aim := _pot_aim(cue, objs)
		intent.aim_dir = aim.dir
		intent.power = aim.power
	var before := _started
	_rejected = &""
	table.sim.request_shot(intent)
	var t0 := Time.get_ticks_msec()
	while _started == before and _rejected == &"" and Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	if _started > before:
		_my_shots += 1


## The ball/pocket pair with the gentlest cut and shortest run; aim at the ghost ball behind it.
func _pot_aim(cue: Ball, objs: Array[Ball]) -> Dictionary:
	var rad := table.spec.ball_radius_m
	var c := _flat(table.to_local(cue.global_position))
	var best := {dir = Vector2.RIGHT, power = 0.7}
	var best_score := -INF
	for b in objs:
		var p := _flat(table.to_local(b.global_position))
		for pk in table.layout.pockets:
			var pp := Vector2(pk.position.x, pk.position.z)
			var to_pocket := (pp - p).normalized()
			var ghost := p - to_pocket * 2.0 * rad
			var v := ghost - c
			if v.length() < rad:
				continue
			var cosine := v.normalized().dot(to_pocket)
			if cosine < 0.6:
				continue
			var run := v.length() + p.distance_to(pp)
			var score := 3.0 * cosine - run
			if score > best_score:
				best_score = score
				best = {dir = v.normalized(), power = clampf(0.45 + 0.18 * run, 0.5, 0.95)}
	return best


func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## A comparable line of everything the two peers must agree on at a Round boundary.
func _state() -> String:
	var owned := []
	for id in eco.owned:
		owned.append("%s=%d" % [id, eco.owned[id]])
	owned.sort()
	return "phase=%d night=%d round=%d shots=%d pts=%d cash=%d viewers=%d shooter=%d owned=%s fx=%d" % [
		gl.phase, gl.night_index, gl.round_index, gl.shots_left, gl.round_points, eco.cash, stream.viewers,
		rd.current_shooter_id, ",".join(owned), fx.live_count()]


func _boundary(n: int) -> void:
	await _until(func() -> bool: return gl.phase != GameLoop.Phase.ROUND_LIVE and gl.phase != GameLoop.Phase.ROUND_END and gl.round_index == n, "Round %d boundary" % n, 30.0)
	await create_timer(2.0).timeout  # the last reliable rows and the playback tail have landed
	var mine := _state()
	if role == "host":
		_touch("bd_%d" % n, mine)
		print("campaign boundary %d: %s" % [n, mine])
		await _until(func() -> bool: return _has("bd_%d_ok" % n), "client agrees at boundary %d" % n, 30.0)
	else:
		await _until(func() -> bool: return _has("bd_%d" % n), "host boundary %d" % n, 30.0)
		var host_state := FileAccess.get_file_as_string(_file("bd_%d" % n))
		var t0 := Time.get_ticks_msec()
		while mine != host_state and Time.get_ticks_msec() - t0 < 5000:
			await create_timer(0.25).timeout
			mine = _state()
		await _check(mine == host_state, "boundary %d differs:\n host   %s\n client %s" % [n, host_state, mine])
		_touch("bd_%d_ok" % n)
	# the Round's checkpoint is on this peer, and it holds this Round's numbers
	if n < 3:
		var listed := SaveManager.list_checkpoints()
		await _until(func() -> bool: return not SaveManager.list_checkpoints().is_empty(), "checkpoint on this peer", 10.0)
		var saved := SaveManager.load_checkpoint(SaveManager.list_checkpoints()[0].path)
		await _check(saved != null and saved.round_index == n and saved.crew_size == 2, "checkpoint after Round %d: %s" % [n, saved.to_dict() if saved != null else "null"])
