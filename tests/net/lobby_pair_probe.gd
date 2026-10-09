extends SceneTree
## Leaving a hosted lobby over the network (REQ#adhoc-1010a:flow A3/A5, run through tests/net/pair.sh): both peers sit in
## the real Lobby scene. The host opens a LAN lobby, the client joins by IP and sees "Waiting for the host to start ·
## 2/4 players"; the host presses Leave and its menu resets; the client is returned to the main menu with the notice
## "The host left the lobby." and can host again.
##   tests/net/pair.sh tests/net/lobby_pair_probe.gd
## Prints `LOBBYPAIR HOST OK` / `LOBBYPAIR CLIENT OK`.

var role := ""
var port := 0
var nm: Node
var ui: Control


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	call_deferred("_run")


func _fail(msg: String) -> void:
	printerr("LOBBYPAIR %s FAIL: %s" % [role.to_upper(), msg])
	quit(1)


func _until(cond: Callable, what: String, sec := 20.0) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_fail("timeout waiting for " + what)
			await create_timer(60).timeout


func _flag(name: String) -> void:
	var f := FileAccess.open(OS.get_environment("PAIR_DIR") + "/" + name, FileAccess.WRITE)
	f.store_string("1")
	f.close()


func _wait_flag(name: String) -> void:
	await _until(func() -> bool: return FileAccess.file_exists(OS.get_environment("PAIR_DIR") + "/" + name), name, 30.0)


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)
		await create_timer(60).timeout


func _home(when: String) -> void:
	for n in ["Host", "Solo", "Footer"]:
		await _check(ui.get_node("%" + n).visible, "%s: %s is back" % [when, n])
	for n in ["Roster", "Start", "Leave", "RoomCode", "Cancel"]:
		await _check(not ui.get_node("%" + n).visible, "%s: %s is gone" % [when, n])
	await _check(not ui.get_node("%Host").disabled and not ui.get_node("%JoinIP").disabled, "%s: the entries work again" % when)


func _run() -> void:
	SaveManager.root = OS.get_environment("PAIR_DIR") + "/save_" + role
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	nm = root.get_node("NetManager")
	nm.config.direct_port = port
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby
	ui = lobby.get_node("LobbyUI")
	await process_frame
	if role == "host":
		ui.get_node("%HostLan").pressed.emit()
		await _until(func() -> bool: return ui.get_node("%Roster").visible and ui.get_node("%Start").visible, "the host's room")
		print("LISTENING")
		await _until(func() -> bool: return nm.get_roster().size() == 2, "the client joined")
		await _until(func() -> bool: return "2/4 players" in ui.get_node("%Status").text, "the host's lobby line counts players: " + ui.get_node("%Status").text)
		_flag("host_has_client")
		await _wait_flag("client_in_room")
		ui.get_node("%Leave").pressed.emit()
		await process_frame
		await _home("host after Leave")
		await _check(not nm.is_host() and nm.get_roster().is_empty(), "the host left the session")
		_flag("host_left")
		await _wait_flag("client_done")
		print("LOBBYPAIR HOST OK")
		quit(0)
	else:
		ui.get_node("%AdvancedToggle").button_pressed = true
		ui.get_node("%Address").text = "127.0.0.1:%d" % port
		ui.get_node("%JoinIP").pressed.emit()
		await _check(ui.get_node("%Cancel").visible and "Connecting: " in ui.get_node("%Status").text, "connecting shows Cancel and its step")
		await _until(func() -> bool: return ui.get_node("%Roster").visible and nm.get_roster().size() == 2, "the client's room")
		await _until(func() -> bool: return "Waiting for the host to start" in ui.get_node("%Status").text and "2/4 players" in ui.get_node("%Status").text, "the client's wait names the host and counts: " + ui.get_node("%Status").text)
		await _check(not ui.get_node("%Start").visible and not ui.get_node("%Cancel").visible, "a client has no Start, and Cancel is gone once connected")
		await _wait_flag("host_has_client")
		_flag("client_in_room")
		await _wait_flag("host_left")
		await _until(func() -> bool: return ui.get_node("%Host").visible and not ui.get_node("%Roster").visible, "the client is back at the main menu")
		await _home("client after the host left")
		await _check(ui.get_node("%Status").text == "The host left the lobby.", "the notice: " + ui.get_node("%Status").text)
		await _check(current_scene == lobby and nm.take_notice() == &"", "still the same Lobby, notice consumed")
		_flag("client_done")
		print("LOBBYPAIR CLIENT OK")
		quit(0)
