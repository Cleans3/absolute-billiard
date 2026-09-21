extends Node
## The one autoload (docs/plan/04 §4, D7). Owns the MultiplayerPeer and the transport choice.
## Singleplayer = host with zero peers: OfflineMultiplayerPeer, same host() path, no `if singleplayer`.

enum Transport { ENET_DIRECT, ENET_NORAY, STEAM }

signal session_started(is_host: bool)

const MAIN_LEVEL := "res://src/levels/MainLevel.tscn"

var transport := Transport.ENET_DIRECT


func host(p_transport := Transport.ENET_DIRECT) -> void:
	transport = p_transport
	# ponytail: every transport is Offline until M2 wires ENet; the enum is the seam, not the code.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	session_started.emit(true)
	get_tree().change_scene_to_file(MAIN_LEVEL)


func is_host() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()
