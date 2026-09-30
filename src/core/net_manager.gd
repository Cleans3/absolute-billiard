extends Node
## The one autoload (docs/plan/04 §4, D7). Owns the MultiplayerPeer, the transport, the roster and the
## session start. Solo = host with zero peers: OfflineMultiplayerPeer, no `if singleplayer` anywhere.

enum Transport { ENET_DIRECT, ENET_NORAY, STEAM }

signal session_started(is_host: bool)
signal roster_changed()
signal session_failed(reason: StringName)
signal session_ended(reason: StringName)
signal all_peers_ready()  ## host only; main_level.gd starts the campaign on it

const LOBBY := "res://src/levels/Lobby.tscn"
const MAIN_LEVEL := "res://src/levels/MainLevel.tscn"
const HOST_ID := 1
const STEAM_TRANSPORT := "res://src/core/transport_steam.gd"  # loaded by path: phone builds must not parse it

var config: NetConfig = preload("res://src/resources/net_config.tres")
var transport := Transport.ENET_DIRECT
var lobby_code := ""
var session_seed := 0
var in_session := false  ## true once start_session ran; late joiners are refused after this

var last_notice := &""  ## why the last session ended; the Lobby shows it once via take_notice()

var _roster: Array[Dictionary] = []  # {peer_id, name, seat, ready}; host writes, clients mirror
var _level_ready: Dictionary = {}  # peer_id -> true, host only, this session
var _timeout: SceneTreeTimer
var _steam: Node  # SteamTransport instance, PC + addon + Steam running only
var _noray: NorayClient  # keeps the host's control connection (= its lobby registration) alive
var _gen := 0  # bumped by _reset(); an async join/host from an older generation must stand down


func _ready() -> void:
	_init_steam()
	multiplayer.peer_connected.connect(_on_peer_connected)
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
	_roster = [_entry(HOST_ID, 0)]
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


func leave() -> void:
	_reset()
	if get_tree().current_scene == null or get_tree().current_scene.scene_file_path != LOBBY:
		get_tree().change_scene_to_file(LOBBY)


func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()


func get_roster() -> Array[Dictionary]:
	return _roster


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
	if is_host() and multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.refuse_new_connections = true
	if is_host() and _steam != null:
		_steam.lock()
	get_tree().change_scene_to_file(MAIN_LEVEL)


@rpc("authority", "call_remote", "reliable", 3)
func _push_roster(roster: Array) -> void:
	_roster.assign(roster)
	roster_changed.emit()


## Noray host path replaces this with a relay-registered peer; both end in _install_host.
func _install_host(peer: MultiplayerPeer) -> void:
	multiplayer.multiplayer_peer = peer
	_roster = [_entry(HOST_ID, 0)]
	session_started.emit(true)
	roster_changed.emit()


func _install_client(peer: MultiplayerPeer) -> void:
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
	nc.send("connect " + oid)
	var target := await nc.wait_command("connect", config.timeout_sec)
	if gen != _gen:
		return
	if target == "":
		_fail(&"unknown_code")
		return
	# Direct first (our outbound packet punches our own NAT); relay when that stays silent.
	var sep := target.rfind(":")
	if await _try_client(target.substr(0, sep), int(target.substr(sep + 1)), nc.local_port, config.direct_try_sec, gen):
		return
	if gen != _gen:
		return
	nc.send("connect-relay " + oid)
	var relay_port := int(await nc.wait_command("connect-relay", config.timeout_sec))
	if gen != _gen:
		return
	if relay_port == 0:
		_fail(&"relay_failed")
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(config.relay_host, relay_port, config.channel_count, 0, 0, nc.local_port) != OK:
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


func _entry(peer_id: int, seat: int) -> Dictionary:
	return {peer_id = peer_id, name = "Player %d" % (seat + 1), seat = seat, ready = false}


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
	roster_changed.emit()
	_push_roster.rpc(_roster)
	_check_barrier()


func _on_connected_to_server() -> void:
	session_started.emit(false)


func _fail(reason: StringName) -> void:
	_reset()
	session_failed.emit(reason)


func _end(reason: StringName) -> void:
	_reset()
	last_notice = reason
	session_ended.emit(reason)
	leave()


func _reset() -> void:
	_gen += 1
	if _steam != null:
		_steam.leave()
	if _noray != null:
		_noray.close()
		_noray = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	_roster = []
	_level_ready.clear()
	lobby_code = ""
	in_session = false


## Host → every client at each Round end (04 §2.6): each peer keeps its own copy for a re-host.
@rpc("authority", "call_remote", "reliable", 3)
func push_save_checkpoint(save_version: int, blob: PackedByteArray) -> void:
	SaveManager.receive_checkpoint(lobby_code, _roster.size(), session_seed, save_version, blob)
