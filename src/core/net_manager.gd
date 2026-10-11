extends Node
## The one autoload (docs/plan/04 §4, D7). Owns the MultiplayerPeer, the transport, the roster and the
## session start. Solo = host with zero peers: OfflineMultiplayerPeer, no `if singleplayer` anywhere.

enum Transport { ENET_DIRECT, ENET_NORAY, STEAM }

signal session_started(is_host: bool)
signal roster_changed()
signal session_failed(reason: StringName)
signal session_ended(reason: StringName)  ## reason &"left" = this player left; any other = the session was cut
signal connect_step_changed(step: StringName)  ## what the connecting wait is on now (`connect_step`); the Lobby words it and times it
signal peers_away_changed()  ## host: a client's app went to / came back from the background
signal loading_changed()  ## the host's load count reached us (`loading_done`)
signal all_peers_ready()  ## host only; main_level.gd starts the campaign on it
signal app_paused()  ## this app went to the background (phone); PhysicsSim / RoundDirector stop trusting streams
signal app_resumed()
signal host_away_changed(away: bool)  ## client: the host's app is in the background (UI shows "host away")

const LOBBY := "res://src/levels/Lobby.tscn"
const MAIN_LEVEL := "res://src/levels/MainLevel.tscn"
const LOADING_SCREEN := preload("res://src/ui/LoadingScreen.tscn")
const HOST_ID := 1
const STEAM_TRANSPORT := "res://src/core/transport_steam.gd"  # loaded by path: phone builds must not parse it
## An ENet header naming no peer and carrying no command: every ENet receiver drops it silently.
const PUNCH_PACKET: PackedByteArray = [0x0f, 0xff]
const PUNCH_COUNT := 20
const PUNCH_INTERVAL_SEC := 0.1

var config: NetConfig = preload("res://src/resources/net_config.tres")
var transport := Transport.ENET_DIRECT
var lobby_code := ""
var session_seed := 0
var in_session := false  ## true once start_session ran; late joiners are refused after this

var backgrounded := false  ## this app is paused (04 §6): no sends, streams ignored, full state asked on resume
var host_away := false  ## client mirror of the host's `backgrounded`

var last_notice := &""  ## why the last session ended; the Lobby shows it once via take_notice()
var connect_step := &""  ## relay | lookup | direct | tunnel | steam while a host/join is in flight, else empty
var host_away_since_msec := 0  ## client: when the host's app went to the background
var loading_done := PackedInt32Array()  ## peers whose MainLevel is up while a session loads (the host's barrier, mirrored)

var _roster: Array[Dictionary] = []  # {peer_id, name, seat, ready, char_skin, bar_skin}; host writes, clients mirror
var _level_ready: Dictionary = {}  # peer_id -> true, host only, this session
var _peers_away: Dictionary = {}  # peer_id -> true, host only: that client's app is in the background
var _loading: LoadingScreen  # the root overlay from start_session until the local player stands in the bar
var _timeout: SceneTreeTimer
var _steam: Node  # SteamTransport instance, PC + addon + Steam running only
var _noray: NorayClient  # keeps the host's control connection (= its lobby registration) alive
var _tunnel: NorayClient  # host's registration with the tunnel relay; closing it frees its tunnels
var _gen := 0  # bumped by _reset(); an async join/host from an older generation must stand down


func _ready() -> void:
	Settings.load_all()  # volume, key bindings: the one boot-time load (docs/plan/06 P11)
	_init_steam()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_connected.connect(_tune_peer)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func() -> void: _fail(&"connection_failed"))
	multiplayer.server_disconnected.connect(func() -> void: _end(&"host_left"))


## Opens a lobby and stays in the Lobby scene (roster UI). Solo uses host_solo().
func host(p_transport := Transport.ENET_NORAY) -> void:
	_reset()
	transport = p_transport
	if transport == Transport.ENET_NORAY:
		_host_noray()
		return
	if transport == Transport.STEAM:
		_host_steam()
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(config.direct_port, config.max_players - 1, config.channel_count)
	if err != OK:
		session_failed.emit(&"host_port_busy" if err == ERR_CANT_CREATE else &"host_failed")
		return
	_install_host(peer)


## Straight into MainLevel with zero peers (Lobby "Solo").
func host_solo() -> void:
	_reset()
	transport = Transport.ENET_DIRECT
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_roster = [_host_entry()]
	session_started.emit(true)
	roster_changed.emit()
	start_game()


func join_direct(address: String, port: int) -> void:
	_reset()
	transport = Transport.ENET_DIRECT
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, port, config.channel_count) != OK:
		session_failed.emit(&"join_failed")
		return
	_install_client(peer)


func join_code(code: String) -> void:
	_reset()
	transport = Transport.ENET_NORAY
	_join_noray(code)


## True when the Steam button may show: PC build, addons present, Steam client running.
func steam_available() -> bool:
	return _steam != null


## Overlay friend picker for the current Steam lobby.
func steam_invite() -> void:
	if _steam != null:
		_steam.invite_overlay()


## Leave a lobby or session, or cancel a host/join still connecting; the Lobby UI resets on `session_ended(&"left")`.
func leave() -> void:
	_reset()
	session_ended.emit(&"left")
	_show_lobby()


func _show_lobby() -> void:
	if get_tree().current_scene == null or get_tree().current_scene.scene_file_path != LOBBY:
		get_tree().change_scene_to_file(LOBBY)


func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func get_roster() -> Array[Dictionary]:
	return _roster


## Host: this client's app is in the background, so a ready-up (GO LIVE) does not wait for it.
func is_peer_away(peer_id: int) -> bool:
	return _peers_away.has(peer_id)


## Peer ids by seat: host 0, then join order. RoundDirector rotates shooters with it.
func seat_order() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for e in _roster:
		ids.append(e.peer_id)
	return ids


func share_link() -> String:
	return "%s/j/%s" % [config.share_base_url, lobby_code]


func take_notice() -> StringName:
	var n := last_notice
	last_notice = &""
	return n


## Host: every peer loads MainLevel with one shared seed.
func start_game() -> void:
	assert(is_host(), "only the host starts the game")
	start_session.rpc(randi())


## Called by main_level.gd `_ready` on every peer, after it connected `all_peers_ready`.
func main_level_ready() -> void:
	if _loading != null:
		_loading.set_stage(LoadingScreen.Stage.WAITING)
		_refresh_loading()
	if is_host():
		_mark_ready(HOST_ID)
	else:
		peer_ready.rpc_id(HOST_ID)


@rpc("any_peer", "call_remote", "reliable", 3)
func peer_ready() -> void:
	if is_host():
		_mark_ready(multiplayer.get_remote_sender_id())


@rpc("authority", "call_local", "reliable", 3)
func start_session(p_seed: int) -> void:
	session_seed = p_seed
	in_session = true
	_level_ready.clear()
	loading_done = PackedInt32Array()
	if is_host() and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.refuse_new_connections = true
	if is_host() and _steam != null:
		_steam.lock()
	_load_main_level()


## Threaded load behind a root overlay (it survives the scene change): "Loading the bar" with the loader's
## progress, "Building the room" while MainLevel's _ready runs, then "Waiting for players" until the local
## player stands in the bar (the overlay ends itself). `_gen` stands the load down when the session is left.
func _load_main_level() -> void:
	var gen := _gen
	_close_loading()
	_loading = LOADING_SCREEN.instantiate()
	_loading.cancelled.connect(leave)
	get_tree().root.add_child(_loading)
	if ResourceLoader.load_threaded_request(MAIN_LEVEL) != OK:
		_fail(&"load_failed")
		return
	var progress := []
	var status := ResourceLoader.load_threaded_get_status(MAIN_LEVEL, progress)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		_loading.set_progress(float(progress[0]))
		await get_tree().process_frame
		if gen != _gen:
			return
		status = ResourceLoader.load_threaded_get_status(MAIN_LEVEL, progress)
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		_fail(&"load_failed")
		return
	_loading.set_stage(LoadingScreen.Stage.BUILDING)
	await get_tree().process_frame  # a frame must draw the new stage before _ready blocks the next ones
	await get_tree().process_frame
	if gen != _gen:
		return
	get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(MAIN_LEVEL))


func _close_loading() -> void:
	if _loading != null and is_instance_valid(_loading):
		_loading.queue_free()
	_loading = null


## Host → everyone: whose MainLevel is up. The overlay words it ("Waiting for players 2/3", who is still loading).
@rpc("authority", "call_local", "reliable", 3)
func loading_state(done: PackedInt32Array) -> void:
	loading_done = done
	_refresh_loading()
	loading_changed.emit()


func _refresh_loading() -> void:
	if _loading != null and is_instance_valid(_loading):
		_loading.set_players(loading_done, _roster)


@rpc("authority", "call_remote", "reliable", 3)
func _push_roster(roster: Array) -> void:
	_roster.assign(roster)
	roster_changed.emit()


## Noray host path replaces this with a relay-registered peer; both end in _install_host.
func _install_host(peer: MultiplayerPeer) -> void:
	_set_step(&"")
	_cap_bandwidth(peer)
	multiplayer.multiplayer_peer = peer
	_roster = [_host_entry()]
	session_started.emit(true)
	roster_changed.emit()


func _install_client(peer: MultiplayerPeer) -> void:
	if connect_step == &"":
		_set_step(&"direct")  # join_direct / the Steam join come straight here
	multiplayer.multiplayer_peer = peer
	_timeout = get_tree().create_timer(config.timeout_sec)
	_timeout.timeout.connect(func() -> void:
		if multiplayer.multiplayer_peer != null and \
				multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
			_fail(&"timeout"))


## Registers with Noray, then serves ENet from the very port the registrar saw, so the lobby code
## (= OID, 6-char Crockford by relay config) reaches this host directly or through the relay.
func _init_steam() -> void:
	var script: GDScript = load(STEAM_TRANSPORT)
	if not script.supported():
		return
	var t: Node = script.new()
	if not t.init_steam():
		t.free()
		return
	_steam = t
	add_child(t)
	t.join_requested.connect(join_steam)


func _host_steam() -> void:
	var gen := _gen
	_set_step(&"steam")
	var peer: MultiplayerPeer = await _steam.host(config.max_players, config.timeout_sec)
	if gen != _gen:
		return
	if peer == null:
		_fail(&"host_failed")
		return
	_install_host(peer)


## Called by a Steam invite (overlay or friends list), from anywhere: leaves whatever we were in.
func join_steam(lobby_id: int) -> void:
	_reset()
	transport = Transport.STEAM
	var gen := _gen
	_set_step(&"steam")
	var peer: MultiplayerPeer = await _steam.join(lobby_id, config.timeout_sec)
	if gen != _gen:
		return
	if peer == null:
		_fail(&"join_failed")
		return
	_install_client(peer)
	if get_tree().current_scene == null or get_tree().current_scene.scene_file_path != LOBBY:
		get_tree().change_scene_to_file(LOBBY)


func _host_noray() -> void:
	var gen := _gen
	var nc := await _noray_register()
	if nc == null or gen != _gen:
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(nc.local_port, config.max_players - 1, config.channel_count) != OK:
		_fail(&"host_failed")
		return
	_noray = nc
	lobby_code = nc.oid
	_install_host(peer)
	_host_handshakes(nc, peer, gen)


## Host half of both handshakes (04 §2.3). Noray says where a joiner will appear from
## (`connect <ip:port>`); the tunnel relay hands out one UDP port per joiner (`tunnel <port> <token>`).
## A burst from ENet's own socket opens this side's NAT toward the joiner, or teaches the tunnel this
## side's address.
func _host_handshakes(nc: NorayClient, peer: ENetMultiplayerPeer, gen: int) -> void:
	var tun := NorayClient.new()  # the tunnel relay speaks Noray's line framing
	if await tun.open(_tunnel_host(), config.tunnel_tcp_port, config.timeout_sec):
		tun.send("host " + nc.oid)
	else:
		push_warning("NetManager: tunnel relay unreachable; only direct joins will work")
	if gen != _gen:
		tun.close()
		return
	_tunnel = tun
	var tunnel_ip := IP.resolve_hostname(_tunnel_host(), IP.TYPE_IPV4)
	while gen == _gen and _noray == nc:
		var direct := nc.take_command("connect")
		if direct != "":
			var sep := direct.rfind(":")
			_punch(peer, direct.substr(0, sep), int(direct.substr(sep + 1)), PUNCH_PACKET, gen)
		var tunnel := tun.take_command("tunnel")
		if tunnel != "":
			_punch(peer, tunnel_ip, int(tunnel.get_slice(" ", 0)), _tunnel_token(tunnel), gen)
		await get_tree().process_frame


func _punch(peer: ENetMultiplayerPeer, address: String, port: int, packet: PackedByteArray, gen: int) -> void:
	for i in PUNCH_COUNT:
		if gen != _gen or peer.host == null:
			return
		peer.host.socket_send(address, port, packet)
		await get_tree().create_timer(PUNCH_INTERVAL_SEC).timeout


func _tunnel_host() -> String:
	return config.relay_host if config.tunnel_host.is_empty() else config.tunnel_host


## `<port> <token>` from the tunnel relay → the datagram that teaches it our address on that port.
static func _tunnel_token(answer: String) -> PackedByteArray:
	return ("AB" + answer.get_slice(" ", 1)).to_ascii_buffer()


func _join_noray(code: String) -> void:
	var gen := _gen
	var oid := LobbyCode.normalize(code)
	if oid == "":
		session_failed.emit(&"bad_code")
		return
	var nc := await _noray_register()
	if nc == null or gen != _gen:
		return
	_noray = nc
	_set_step(&"lookup")
	nc.send("connect " + oid)
	var target := await nc.wait_command("connect", config.timeout_sec)
	if gen != _gen:
		return
	if target == "":
		_fail(&"unknown_code")
		return
	# Direct first (our outbound packet punches our own NAT, the host punches back).
	_set_step(&"direct")
	var sep := target.rfind(":")
	if await _try_client(target.substr(0, sep), int(target.substr(sep + 1)), nc.local_port, config.direct_try_sec, gen):
		return
	if gen != _gen:
		return
	# Fallback (06 P10): the tunnel relay learns both addresses from packets sent to one port, so it works
	# behind any NAT. Noray's own relay is not used: it cannot reach a host behind a symmetric NAT.
	var tun := NorayClient.new()
	var answer := ""
	_set_step(&"tunnel")
	if await tun.open(_tunnel_host(), config.tunnel_tcp_port, config.timeout_sec):
		tun.send("join " + oid)
		answer = await tun.wait_command("tunnel", config.timeout_sec)
	tun.close()
	if gen != _gen:
		return
	var tunnel_ip := IP.resolve_hostname(_tunnel_host(), IP.TYPE_IPV4)
	var port := int(answer.get_slice(" ", 0))
	var local_port := 0
	if port > 0:
		local_port = await NorayClient.knock(tunnel_ip, port, _tunnel_token(answer), config.timeout_sec)
	if gen != _gen:
		return
	if local_port == 0:
		_fail(&"relay_failed")
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(tunnel_ip, port, config.channel_count, 0, 0, local_port) != OK:
		_fail(&"join_failed")
		return
	_install_client(peer)


## One ENet client attempt from a fixed local port; true once connected.
func _try_client(address: String, port: int, local_port: int, timeout: float, gen: int) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, port, config.channel_count, 0, 0, local_port) != OK:
		return false
	multiplayer.multiplayer_peer = peer  # SceneMultiplayer must see the connect event, so it polls
	var t0 := Time.get_ticks_msec()
	while peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING \
			and Time.get_ticks_msec() - t0 < timeout * 1000.0 and gen == _gen:
		await get_tree().process_frame
	if gen == _gen and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	if gen == _gen:
		multiplayer.multiplayer_peer = null
	peer.close()
	await get_tree().process_frame  # let the socket release local_port before the relay try
	return false


func _noray_register() -> NorayClient:
	var gen := _gen
	var nc := NorayClient.new()
	_set_step(&"relay")
	var ok: bool = await nc.open(config.relay_host, config.relay_tcp_port, config.timeout_sec) \
		and await nc.register_host(config.timeout_sec) \
		and await nc.register_remote(config.relay_host, config.relay_udp_port, config.timeout_sec)
	if gen != _gen:
		nc.close()
		return null
	if not ok:
		nc.close()
		session_failed.emit(&"relay_unreachable")
		return null
	return nc


func _mark_ready(peer_id: int) -> void:
	_level_ready[peer_id] = true
	loading_state.rpc(PackedInt32Array(_level_ready.keys()))  # before the barrier clears the set
	_check_barrier()


## A peer that left mid-load must not hold the others at the barrier, so this also runs on disconnect.
func _check_barrier() -> void:
	if _level_ready.is_empty():
		return
	for e in _roster:
		if not _level_ready.has(e.peer_id):
			return
	_level_ready.clear()
	all_peers_ready.emit()


## Skins (06 P18): `char_skin` &"" = nothing equipped, the seat's colour applies; `bar_skin` is always a real id.
func _entry(peer_id: int, seat: int) -> Dictionary:
	return {peer_id = peer_id, name = "Player %d" % (seat + 1), seat = seat, ready = false, char_skin = &"", bar_skin = SkinCatalog.DEFAULT_BAR}


func _host_entry() -> Dictionary:
	var e := _entry(HOST_ID, 0)
	e.merge(SkinCatalog.local_pick(), true)
	return e


func _on_peer_connected(peer_id: int) -> void:
	if not is_host() or multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return
	_roster.append(_entry(peer_id, _roster.size()))
	roster_changed.emit()
	_push_roster.rpc(_roster)


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host():
		return
	for i in _roster.size():
		if _roster[i].peer_id == peer_id:
			_roster.remove_at(i)
			break
	for i in _roster.size():
		_roster[i].seat = i
	if _peers_away.erase(peer_id):
		peers_away_changed.emit()
	roster_changed.emit()
	_push_roster.rpc(_roster)
	if not _level_ready.is_empty():
		loading_state.rpc(PackedInt32Array(_level_ready.keys()))
	_check_barrier()


func _on_connected_to_server() -> void:
	_set_step(&"")
	_tune_peer(HOST_ID)
	var pick := SkinCatalog.local_pick()
	register_skins.rpc_id(HOST_ID, pick.char_skin, pick.bar_skin)  # ahead of peer_ready on the same channel: the roster is final before slots spawn
	session_started.emit(false)


## Host: a client's equipped skins join its roster entry, validated (an unknown or non-selectable id falls back).
@rpc("any_peer", "call_remote", "reliable", 3)
func register_skins(char_skin: StringName, bar_skin: StringName) -> void:
	if not is_host():
		return
	for e in _roster:
		if e.peer_id == multiplayer.get_remote_sender_id():
			e.char_skin = char_skin if SkinCatalog.is_selectable_character(char_skin) else &""
			e.bar_skin = SkinCatalog.resolve_bar(bar_skin).id
			roster_changed.emit()
			_push_roster.rpc(_roster)
			return


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED: set_backgrounded(true)
		NOTIFICATION_APPLICATION_RESUMED: set_backgrounded(false)
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			if OS.get_name() == "Android":
				set_backgrounded(true)
		NOTIFICATION_APPLICATION_FOCUS_IN:
			if OS.get_name() == "Android":
				set_backgrounded(false)


## Also the seam tests use to fake a pause. The host tells its clients (best effort, it may be frozen
## right after) so they can show "host away"; the host's resume also re-sends every client full state.
func set_backgrounded(value: bool) -> void:
	if backgrounded == value:
		return
	backgrounded = value
	if is_host() and not multiplayer.get_peers().is_empty():
		_host_away_rpc.rpc(value)
	elif not is_host() and multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		peer_away.rpc_id(HOST_ID, value)  # best effort, the phone may freeze right after: GO LIVE stops waiting on it
	if value:
		app_paused.emit()
	else:
		app_resumed.emit()


@rpc("authority", "call_remote", "reliable", 3)
func _host_away_rpc(away: bool) -> void:
	if away and not host_away:
		host_away_since_msec = Time.get_ticks_msec()
	host_away = away
	host_away_changed.emit(away)


## Client → host: this app went to / came back from the background (04 §6).
@rpc("any_peer", "call_remote", "reliable", 3)
func peer_away(away: bool) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if away:
		_peers_away[id] = true
	else:
		_peers_away.erase(id)
	peers_away_changed.emit()


## "Host away" banner text: the wait so far and the time ENet gives the host before it drops (config.peer_timeout_min_ms).
func host_away_text() -> String:
	var waited := (Time.get_ticks_msec() - host_away_since_msec) / 1000
	return "Host away %d s · connection drops in ~%d s" % [waited, maxi(config.peer_timeout_min_ms / 1000 - waited, 0)]


## A server host left at "unlimited" bandwidth (0) makes ENet clamp every client's packet throttle to 1-4 of 32 in its first
## 1 s pass (measured: the clients' pose stream then dies for seconds); an explicit cap no link reaches avoids the clamp,
## and only when set on the server, right after it is created (NetConfig.bandwidth_bytes_per_sec).
func _cap_bandwidth(peer: MultiplayerPeer) -> void:
	var enet := peer as ENetMultiplayerPeer
	if enet != null:
		enet.get_host().bandwidth_limit(config.bandwidth_bytes_per_sec, config.bandwidth_bytes_per_sec)


## Per-peer ENet tuning, on both ends of every link. Timeouts: the default (5 s min / 30 s max) would drop a phone that
## spent 30 s in the background. Throttle: never closes (NetConfig), so RTT jitter cannot starve the pose stream.
func _tune_peer(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var p := enet.get_peer(peer_id)
	if p != null:
		p.set_timeout(config.peer_timeout_limit, config.peer_timeout_min_ms, config.peer_timeout_max_ms)
		p.throttle_configure(config.throttle_interval_ms, config.throttle_acceleration, config.throttle_deceleration)


func _fail(reason: StringName) -> void:
	_reset()
	session_failed.emit(reason)


func _set_step(step: StringName) -> void:
	if step != connect_step:
		connect_step = step
		connect_step_changed.emit(step)


func _end(reason: StringName) -> void:
	_reset()
	last_notice = reason
	session_ended.emit(reason)
	_show_lobby()


func _reset() -> void:
	_gen += 1
	if _steam != null:
		_steam.leave()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()  # before the relays: its goodbye packets may travel through them
	multiplayer.multiplayer_peer = null
	if _noray != null:
		_noray.close()
		_noray = null
	if _tunnel != null:
		_tunnel.close()
		_tunnel = null
	_roster = []
	_level_ready.clear()
	_peers_away.clear()
	loading_done = PackedInt32Array()
	_close_loading()
	connect_step = &""
	lobby_code = ""
	in_session = false
	backgrounded = false
	host_away = false


## Host → every client at each Round end (04 §2.6): each peer keeps its own copy for a re-host.
@rpc("authority", "call_remote", "reliable", 3)
func push_save_checkpoint(save_version: int, blob: PackedByteArray) -> void:
	SaveManager.receive_checkpoint(lobby_code, _roster.size(), session_seed, save_version, blob)
