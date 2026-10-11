extends SceneTree
## Two-peer ENet throttle probe (tests/net/pair.sh, adhoc-1011a walkflake): both ends' ENet packet throttle must never be
## able to close, and must stay fully open while the host loads the level like a real join. By default ENet clamps a
## client's throttle to 1-4 of 32 in its first 1 s bandwidth pass and RTT jitter closes it further, which silently drops the
## 10 Hz pose stream (a puppet keeps its last mode: player_pair_probe timed out 2 runs in 3). The clamp depends on timing, so
## this pins the configuration (deceleration 0) as well as the measured value. Prints `THROTTLE HOST OK` / `THROTTLE CLIENT OK`.
##   tests/net/pair.sh tests/net/throttle_pair_probe.gd

const WATCH_SEC := 5.0  # past the 1 s bandwidth pass and its 1 s clamp, over several keepalive acks

var role := ""
var port := 0
var nm: Node


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("THROTTLE %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 15.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _run() -> void:
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	if role == "host":
		nm.host(nm.Transport.ENET_DIRECT)
		print("LISTENING")
	else:
		nm.join_direct("127.0.0.1", port)
	await _until(func() -> bool: return nm.get_roster().size() == 2, "roster == 2")
	if role == "host":
		nm.start_game()  # the level load stalls both main loops, as it does for every real join
	var enet := root.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	var lowest := ENetPacketPeer.PACKET_THROTTLE_SCALE
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < WATCH_SEC * 1000.0:
		await process_frame
		for p in enet.get_host().get_peers():
			if p.get_state() == ENetPacketPeer.STATE_CONNECTED:
				lowest = mini(lowest, int(p.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE)))
				if int(p.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_DECELERATION)) != 0:
					_fail("throttle deceleration is %d, the throttle can close" % int(p.get_statistic(ENetPacketPeer.PEER_PACKET_THROTTLE_DECELERATION)))
	print("throttle %s: lowest %d of %d over %.0f s" % [role, lowest, ENetPacketPeer.PACKET_THROTTLE_SCALE, WATCH_SEC])
	if lowest < ENetPacketPeer.PACKET_THROTTLE_SCALE:
		_fail("the packet throttle closed to %d of %d: unreliable packets are being dropped at the sender" % [lowest, ENetPacketPeer.PACKET_THROTTLE_SCALE])
	var mine := OS.get_environment("PAIR_DIR") + "/%s_done" % role
	var f := FileAccess.open(mine, FileAccess.WRITE)
	f.store_string("1")
	f.close()
	var other := OS.get_environment("PAIR_DIR") + "/%s_done" % ("client" if role == "host" else "host")
	await _until(func() -> bool: return FileAccess.file_exists(other), "the other peer's verdict", 20.0)
	print("THROTTLE %s OK" % role.to_upper())
	quit(0)
