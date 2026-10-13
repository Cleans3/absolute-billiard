extends SceneTree
# PAIR_TIMEOUT=180

## The new hazards over the wire (run through tests/net/pair.sh): the host starts a Round with each of Sunken Ship, Vacation, Pinball and
## Double Ball (the scheduler's `apply_event` rpc carries the host's roll), and the client must hold the same `hazard_state()`, the same
## physics object (pins, shoreline, tilt at the chosen pocket) and the same rack. Pinball then plays a real full-power shot on the host
## and the client's balls must end within a few mm of the host's: the pins, bounced on Jolt, are modelled in the client's BallMotion.
##   flock /tmp/ab-pair.lock bash tests/net/pair.sh tests/effects/hazard_pair_probe.gd
## Prints `HAZPAIR HOST OK` / `HAZPAIR CLIENT OK`.

const KINDS: Array[StringName] = [&"sunken_ship", &"vacation", &"pinball", &"double_ball"]
const END_MM := 6.0  ## client vs host after the shot (04 §2.4: events within 2 mm, the playback's own settling on top)

var role := ""
var port := 0
var nm: Node
var rd: RoundDirector
var table: Table
var fx: EffectManager
var loop: GameLoop
var sched: EventScheduler


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("HAZPAIR %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 40.0) -> void:
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


func _read(name: String) -> String:
	return FileAccess.get_file_as_string(_file(name))


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
	fx = current_scene.get_node("EffectManager")
	loop = current_scene.get_node("GameLoop")
	sched = current_scene.get_node("EventScheduler")
	if role == "host":
		await _until(func() -> bool: return loop.phase == GameLoop.Phase.INTERMISSION, "campaign at Intermission")
		await _host()
	else:
		await _client()


func _host() -> void:
	for kind in KINDS:
		sched._offer.clear()
		sched._chosen = FxCatalog.event(kind)
		loop.round_index = 1
		loop.phase = GameLoop.Phase.INTERMISSION
		loop.advance()
		await _until(func() -> bool: return rd.get_balls().size() > 5 and fx.hazard_state().get("id", "") == String(kind), "%s live on the host" % kind)
		for i in 60:
			await physics_frame
		_touch("state_%s" % kind, JSON.stringify({state = fx.hazard_state(), balls = rd.get_balls().size(), tilt = [table.sim.tilt_direction.x, table.sim.tilt_direction.y], pins = _pins_of(table.sim.hazard)}))
		if kind == &"pinball":
			await _shot()
		await _until(func() -> bool: return FileAccess.file_exists(_file("ok_%s" % kind)), "client verdict on %s" % kind)
		loop._end_round(&"timer")  # the client follows the round_state
		await _until(func() -> bool: return FileAccess.file_exists(_file("gone_%s" % kind)), "client dropped %s" % kind)
	print("HAZPAIR HOST OK")
	quit(0)


func _pins_of(h: HazardModel) -> Array:
	var out := []
	if h != null:
		for q in h.pins_local:
			out.append([q.x, q.y])
	return out


func _shot() -> void:
	await _until(func() -> bool: return table.sim.awake == 0, "table at rest")
	var cue: Ball = null
	var aim := Vector2.RIGHT
	for b in rd.get_balls():
		if b.is_cue_ball:
			cue = b
	var target := rd.get_balls()[1]
	var d := target.global_position - cue.global_position
	aim = Vector2(d.x, d.z).normalized()
	var intent := ShotIntent.new()
	intent.aim_dir = aim
	intent.power = 1.0
	table.sim.request_shot(intent)
	await rd.shot_ended
	await create_timer(1.2).timeout
	var pos := {}
	for b in rd.get_balls():
		if not b.retired:
			var p := table.to_local(b.global_position)
			pos[str(b.net_id)] = [p.x, p.y, p.z]
	_touch("shot_pinball", JSON.stringify(pos))


func _client() -> void:
	for kind in KINDS:
		await _until(func() -> bool: return FileAccess.file_exists(_file("state_%s" % kind)), "host state for %s" % kind)
		var want: Dictionary = JSON.parse_string(_read("state_%s" % kind))
		await _until(func() -> bool: return fx.hazard_state().get("id", "") == String(kind) and rd.get_balls().size() == int(want.balls), "%s live on the client with %d balls" % [kind, int(want.balls)])
		var got: Variant = JSON.parse_string(JSON.stringify(fx.hazard_state()))  # through JSON like the host's copy: ints become floats on both
		if got != want.state:
			_fail("%s: hazard_state differs: host %s client %s" % [kind, want.state, got])
		var sim := table.sim
		match kind:
			&"sunken_ship":
				var m: HazardModel = fx._events[0].model
				if m == null or String(m.corner) != str(want.state.corner) or m.tilt_dir.distance_to(Vector2(float(want.tilt[0]), float(want.tilt[1]))) > 1e-4:
					_fail("sunken_ship: the client's tilt direction %s is not the host's %s" % [m.tilt_dir if m != null else null, want.tilt])
			&"vacation":
				if sim.hazard == null or sim.hazard.shore_n == Vector2.ZERO:
					_fail("vacation: the client has no shoreline")
			&"pinball":
				if sim.hazard == null or sim.hazard.pins_local.size() != 4:
					_fail("pinball: the client has no pins")
				for i in 4:
					if sim.hazard.pins_local[i].distance_to(Vector2(float(want.pins[i][0]), float(want.pins[i][1]))) > 1e-4:
						_fail("pinball: pin %d differs" % i)
		for b in rd.get_balls():
			if b.motion.hazard != sim.hazard:
				_fail("%s: ball %d does not model the live hazard" % [kind, b.net_id])
		if kind == &"pinball":
			await _until(func() -> bool: return FileAccess.file_exists(_file("shot_pinball")), "the host's shot")
			await _until(func() -> bool: return not rd.shot_in_progress and table.sim.awake == 0, "the shot over on the client", 60.0)
			await create_timer(1.0).timeout
			var host_pos: Dictionary = JSON.parse_string(_read("shot_pinball"))
			var worst := 0.0
			for b in rd.get_balls():
				if b.retired or not host_pos.has(str(b.net_id)):
					continue
				var p := table.to_local(b.global_position)
				var h: Array = host_pos[str(b.net_id)]
				worst = maxf(worst, p.distance_to(Vector3(h[0], h[1], h[2])))
			print("hazpair: pinball shot: worst client-host error at rest %.2f mm over %d balls" % [worst * 1000.0, host_pos.size()])
			if worst * 1000.0 > END_MM:
				_fail("pinball: the client ended %.1f mm from the host (limit %.0f)" % [worst * 1000.0, END_MM])
		_touch("ok_%s" % kind)
		await _until(func() -> bool: return fx.hazard_state().is_empty() and table.sim.hazard == null, "%s gone with the Round" % kind, 60.0)
		_touch("gone_%s" % kind)
	print("HAZPAIR CLIENT OK")
	quit(0)
