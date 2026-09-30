extends Node
## Steam lobby transport (M7, docs/plan/04 §2.3). PC-only and optional: NetManager loads this script BY PATH
## and only when OS.has_feature("pc") and the GodotSteam + SteamMultiplayerPeer GDExtensions are present
## (src/tools/fetch_godotsteam.sh), so a phone build never parses a Steam identifier. Everything Steam is
## a dynamic call on the `Steam` engine singleton / ClassDB for exactly that reason.

signal join_requested(lobby_id: int)  ## friend invite accepted in the overlay / "Join game" in the friends list

const APP_ID := 480  ## Spacewar, public dev id; the real id replaces steam_appid.txt at release
const LOBBY_TYPE_FRIENDS_ONLY := 1  # k_ELobbyTypeFriendsOnly
const ENTER_SUCCESS := 1  # k_EChatRoomEnterResponseSuccess

var lobby_id := 0
var _steam: Object
var _ok := false


static func supported() -> bool:
	return OS.has_feature("pc") and Engine.has_singleton(&"Steam") and ClassDB.class_exists(&"SteamMultiplayerPeer")


## True when the Steam client is running and the API initialised for app 480.
func init_steam() -> bool:
	OS.set_environment("SteamAppId", str(APP_ID))
	OS.set_environment("SteamGameId", str(APP_ID))
	_steam = Engine.get_singleton(&"Steam")
	var r: Variant = _steam.steamInit()
	_ok = r if r is bool else int((r as Dictionary).get("status", 1)) == 0
	if _ok:
		_steam.connect(&"join_requested", func(id: int, _friend: int) -> void: join_requested.emit(id))
	return _ok


func _process(_delta: float) -> void:
	if _ok:
		_steam.run_callbacks()


func _exit_tree() -> void:
	if _ok:
		_steam.steamShutdown()


## Opens a friends-only lobby and returns the host SteamMultiplayerPeer, or null.
func host(max_players: int, timeout_sec: float) -> MultiplayerPeer:
	var made := {}
	_steam.connect(&"lobby_created", func(result: int, id: int) -> void: made.merge({result = result, id = id}), CONNECT_ONE_SHOT)
	_steam.createLobby(LOBBY_TYPE_FRIENDS_ONLY, max_players)
	if not await _until(func() -> bool: return not made.is_empty(), timeout_sec) or made.result != 1:
		return null
	lobby_id = made.id
	var peer: MultiplayerPeer = ClassDB.instantiate(&"SteamMultiplayerPeer")
	return peer if peer.create_host(0) == OK else null


## Joins a lobby (from an invite) and returns the client peer aimed at the lobby owner, or null.
func join(id: int, timeout_sec: float) -> MultiplayerPeer:
	var done := {}
	_steam.connect(&"lobby_joined", func(lobby: int, _perm: int, _locked: bool, response: int) -> void: done.merge({lobby = lobby, response = response}), CONNECT_ONE_SHOT)
	_steam.joinLobby(id)
	if not await _until(func() -> bool: return not done.is_empty(), timeout_sec) or done.response != ENTER_SUCCESS:
		return null
	lobby_id = id
	var owner: int = _steam.getLobbyOwner(id)
	if owner == _steam.getSteamID():
		return null
	var peer: MultiplayerPeer = ClassDB.instantiate(&"SteamMultiplayerPeer")
	return peer if peer.create_client(owner, 0) == OK else null


func invite_overlay() -> void:
	if lobby_id != 0:
		_steam.activateGameOverlayInviteDialog(lobby_id)


## After start_session nobody else may join.
func lock() -> void:
	if lobby_id != 0:
		_steam.setLobbyJoinable(lobby_id, false)


func leave() -> void:
	if lobby_id != 0:
		_steam.leaveLobby(lobby_id)
		lobby_id = 0


func _until(cond: Callable, timeout_sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > timeout_sec * 1000.0:
			return false
		await get_tree().process_frame
	return true
