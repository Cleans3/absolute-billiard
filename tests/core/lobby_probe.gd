extends SceneTree
## C1 + C3: Lobby boots, Solo → NetManager.host_solo() installs OfflineMultiplayerPeer, the loading screen covers the
## load (present at once, in every stage, and still up when all_peers_ready fires), MainLevel loads, this peer is the
## host with id 1, and the screen ends once the local player stands in the bar.
## `godot --path . --headless -s tests/core/lobby_probe.gd`

const LOBBY := "res://src/levels/Lobby.tscn"


func _init() -> void:
	call_deferred("_run")


func _until(cond: Callable, what: String, sec := 30.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			assert(false, "timeout waiting for " + what)
			quit(1)


func _run() -> void:
	var lobby: Node = load(LOBBY).instantiate()
	root.add_child(lobby)
	current_scene = lobby
	await process_frame
	var nm := root.get_node("NetManager")
	var solo: Button = lobby.get_node("LobbyUI/Center/Menu/Solo")
	assert(solo != null, "Solo button missing")
	assert(root.get_node_or_null("LoadingScreen") == null, "no loading screen at the menu")
	var at_ready := []  # the loading screen's stage when all_peers_ready fired
	nm.all_peers_ready.connect(func() -> void:
		var l := root.get_node_or_null("LoadingScreen") as LoadingScreen
		at_ready.append(l.stage if l != null else -1))
	solo.pressed.emit()
	assert(nm.is_host(), "not host after Solo")
	assert(root.multiplayer.get_unique_id() == 1, "host id must be 1 (OfflineMultiplayerPeer)")
	assert(root.multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "peer is not Offline")
	var screen := root.get_node_or_null("LoadingScreen") as LoadingScreen
	assert(screen != null and screen.stage == LoadingScreen.Stage.LOADING, "Solo shows the loading screen at once, in its Loading stage")
	await _until(func() -> bool: return current_scene != null and current_scene.name == "MainLevel", "MainLevel")
	assert(at_ready == [LoadingScreen.Stage.WAITING], "all_peers_ready fired under the loading screen, in its Waiting stage: %s" % [at_ready])
	await _until(func() -> bool: return root.get_node_or_null("LoadingScreen") == null, "the loading screen to end", 10.0)
	assert(current_scene.get_node("PlayerSpawner").get_local_player() != null, "the screen ends once the local player stands in the bar")
	print("LOBBY OK")
	quit()
