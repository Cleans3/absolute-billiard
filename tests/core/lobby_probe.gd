extends SceneTree
## C1: Lobby boots, Solo → NetManager.host() installs OfflineMultiplayerPeer, MainLevel loads,
## this peer is the host with id 1. `godot --path . --headless -s tests/core/lobby_probe.gd`

const LOBBY := "res://src/levels/Lobby.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var lobby: Node = load(LOBBY).instantiate()
	root.add_child(lobby)
	await process_frame
	var solo: Button = lobby.get_node("LobbyUI/Center/Menu/Solo")
	assert(solo != null, "Solo button missing")
	solo.pressed.emit()
	assert(root.get_node("/root/NetManager").is_host(), "not host after Solo")
	assert(root.multiplayer.get_unique_id() == 1, "host id must be 1 (OfflineMultiplayerPeer)")
	assert(root.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "peer is not Offline")
	await process_frame
	await process_frame
	assert(current_scene != null and current_scene.name == "MainLevel", "MainLevel not loaded: %s" % [current_scene])
	print("LOBBY OK")
	quit()
