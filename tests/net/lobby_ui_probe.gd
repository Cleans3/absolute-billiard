extends SceneTree
## Lobby UI: Host LAN → room shows code slot, roster with us as host, Start visible; Leave returns home.
## `godot --path . --headless -s tests/net/lobby_ui_probe.gd`


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var nm := root.get_node("NetManager")
	nm.config.direct_port = 27000 + randi() % 5000
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	var ui: Control = lobby.get_node("LobbyUI")
	ui.get_node("%HostLan").pressed.emit()
	await process_frame
	assert(ui.get_node("%Roster").visible and not ui.get_node("%Solo").visible, "room state")
	assert("(host)" in ui.get_node("%Roster").text and "(you)" in ui.get_node("%Roster").text, "roster line")
	assert(ui.get_node("%Start").visible, "host sees Start")
	assert(not ui.get_node("%Share").visible, "no share link without a lobby code")
	assert(DeepLink.code_from_url("absolutebilliard://j/ab3k7q") == "AB3K7Q", "scheme link")
	assert(DeepLink.code_from_url("http://1.2.3.4:8892/j/AB3K7Q") == "AB3K7Q", "share link")
	assert(DeepLink.code_from_url("http://1.2.3.4/x/AB3K7Q") == "", "not an invite")
	ui.get_node("%Leave").pressed.emit()
	await process_frame
	await process_frame
	assert(not nm.is_host() and nm.get_roster().is_empty(), "left")
	print("LOBBY UI OK")
	quit()
