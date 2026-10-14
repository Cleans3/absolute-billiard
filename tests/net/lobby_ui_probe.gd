extends SceneTree
## Lobby UI: Host LAN → room shows code slot, roster with us as host, Start visible; Leave returns home with the
## host controls reset; Cancel aborts a connect; a vanished host returns a client home with a notice; Esc leaves.
## `godot --path . --headless -s tests/net/lobby_ui_probe.gd`


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var nm := root.get_node("NetManager")
	nm.config.direct_port = 27000 + randi() % 5000
	SaveManager.root = "user://test_lobby_ui_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(SaveManager.checkpoint_dir())
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	current_scene = lobby  # so NetManager knows the Lobby is already up and never reloads it
	await process_frame
	var ui: Control = lobby.get_node("LobbyUI")
	assert(not ui.get_node("%Resume").visible, "Resume hidden with no checkpoints")
	assert(ui.get_node("%ModeBox").visible and ui.get_node("%ModeCampaign").button_pressed and GameLoop.pending_mode == GameLoop.MODE_CAMPAIGN, "the Lobby opens on Campaign")
	ui.get_node("%ModeEndless").button_pressed = true
	assert(GameLoop.pending_mode == GameLoop.MODE_ENDLESS and not ui.get_node("%ModeCampaign").button_pressed and "Never ends" in ui.get_node("%ModeHint").text, "Endless is the pick")
	ui.get_node("%ModeCampaign").button_pressed = true
	assert(GameLoop.pending_mode == GameLoop.MODE_CAMPAIGN, "and back to Campaign")
	_resume_flow(ui, nm)
	assert(nm.steam_available() or not ui.get_node("%Steam").visible, "Steam button must be hidden without Steam")
	ui.get_node("%HostLan").pressed.emit()
	await process_frame
	assert(ui.get_node("%Roster").visible and not ui.get_node("%Solo").visible, "room state")
	assert("(host)" in ui.get_node("%Roster").text and "(you)" in ui.get_node("%Roster").text, "roster line")
	assert(ui.get_node("%Start").visible, "host sees Start")
	assert(ui.get_node("%ModeBox").visible, "the host still picks the mode in the room")
	assert(not ui.get_node("%Share").visible, "no share link without a lobby code")
	assert(DeepLink.code_from_url("absolutebilliard://j/ab3k7q") == "AB3K7Q", "scheme link")
	assert(DeepLink.code_from_url("http://1.2.3.4:8892/j/AB3K7Q") == "AB3K7Q", "share link")
	assert(DeepLink.code_from_url("http://1.2.3.4/x/AB3K7Q") == "", "not an invite")
	var page_port := FileAccess.get_file_as_string("res://deploy/noray/vps/join.service").get_slice("join_page.py ", 1).get_slice("\n", 0).strip_edges()  # strip after the split: a CRLF checkout (git autocrlf) leaves a \r
	assert(NetConfig.new().share_base_url.ends_with(":" + page_port), "share link must hit the deployed join page port")
	ui.get_node("%Leave").pressed.emit()
	await process_frame
	await process_frame
	assert(not nm.is_host() and nm.get_roster().is_empty(), "left")
	_assert_home(ui, "after Leave")
	await _cancel_flow(ui, nm)
	await _host_left_flow(ui, nm)
	await _esc_flow(ui, nm)
	for f in DirAccess.get_files_at(SaveManager.checkpoint_dir()):
		DirAccess.remove_absolute(SaveManager.checkpoint_dir().path_join(f))
	DirAccess.remove_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root)
	print("LOBBY UI OK")
	quit()


## The main menu, host controls gone: nothing of the room is left on screen and every entry button works again.
func _assert_home(ui: Control, when: String) -> void:
	for n in ["Host", "Solo", "Footer", "ModeBox"]:
		assert(ui.get_node("%" + n).visible, "%s: %s is back" % [when, n])
	for n in ["Roster", "Start", "Leave", "RoomCode", "Share", "Cancel"]:
		assert(not ui.get_node("%" + n).visible, "%s: %s is gone" % [when, n])
	for n in ["Host", "Solo", "Join", "JoinIP", "HostLan"]:
		assert(not ui.get_node("%" + n).disabled, "%s: %s is enabled again" % [when, n])


## Pressing a join that never answers: the wait names its step and the seconds, Cancel returns home and frees the peer.
func _cancel_flow(ui: Control, nm: Node) -> void:
	ui.get_node("%AdvancedToggle").button_pressed = true
	ui.get_node("%Address").text = "10.255.255.1:9"
	ui.get_node("%JoinIP").pressed.emit()
	await process_frame
	assert(ui.get_node("%Cancel").visible and ui.get_node("%Host").disabled, "connecting: Cancel shows, the entries lock")
	var status: String = ui.get_node("%Status").text
	assert(status.begins_with("Connecting: ") and "direct link" in status and status.ends_with(" s"), "the wait names its step and the seconds: " + status)
	assert(nm.multiplayer.multiplayer_peer != null, "the connect is in flight")
	ui.get_node("%Cancel").pressed.emit()
	await process_frame
	assert(nm.multiplayer.multiplayer_peer == null and nm.connect_step == &"", "Cancel drops the pending connection")
	_assert_home(ui, "after Cancel")
	ui.get_node("%AdvancedToggle").button_pressed = false


## The server vanishes under a connected client: home again with the notice, which is consumed (not shown twice).
func _host_left_flow(ui: Control, nm: Node) -> void:
	ui.get_node("%HostLan").pressed.emit()
	await process_frame
	assert(ui.get_node("%Roster").visible, "in the room")
	nm._end(&"host_left")
	await process_frame
	_assert_home(ui, "after the host left")
	assert(ui.get_node("%Status").text == "The host left the lobby." and nm.take_notice() == &"", "the notice shows once")


## Esc / Back: leaves the room, cancels a connect, and does nothing at the menu.
func _esc_flow(ui: Control, nm: Node) -> void:
	var esc := InputEventAction.new()
	esc.action = &"ui_cancel"
	esc.pressed = true
	ui._input(esc)
	assert(not nm.is_host(), "Esc at the menu does nothing")
	ui.get_node("%HostLan").pressed.emit()
	await process_frame
	ui._input(esc)
	await process_frame
	_assert_home(ui, "after Esc in the room")
	ui.get_node("%JoinIP").pressed.emit()
	await process_frame
	ui._input(esc)
	await process_frame
	_assert_home(ui, "after Esc while connecting")
	ui.get_node("%HostLan").pressed.emit()
	await process_frame
	ui.get_node("%Start").pressed.emit()
	assert(ui.get_node("%Start").disabled and ui.get_node("%Status").text.begins_with("Starting: sending everyone to the bar ("), "Start locks after the press")
	var t0 := Time.get_ticks_msec()  # let the load finish: quitting under a threaded load prints teardown errors
	while (current_scene == null or current_scene.name != "MainLevel" or root.get_node_or_null("LoadingScreen") != null) and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
	assert(current_scene != null and current_scene.name == "MainLevel", "Start loads MainLevel")


## Two checkpoints → Resume shows both newest first; picking one sets pending_resume and hosts from it.
func _resume_flow(ui: Control, nm: Node) -> void:
	var old := SaveProfile.new()
	old.crew_cash = 700
	old.current_night = 1
	old.round_index = 1
	old.crew_size = 2
	SaveManager.write_checkpoint("OLDONE", SaveManager.encode(old))
	var newer := SaveProfile.new()
	newer.crew_cash = 1500
	newer.current_night = 3
	newer.round_index = 2
	newer.crew_size = 3
	SaveManager.write_checkpoint("NEWEST", SaveManager.encode(newer))
	DirAccess.remove_absolute(SaveManager.checkpoint_path("OLDONE"))  # stale file must vanish from the list
	SaveManager.write_checkpoint("OLDONE", SaveManager.encode(old))
	ui._set_home(true)
	assert(ui.get_node("%Resume").visible, "Resume visible with checkpoints")
	ui.get_node("%Resume").pressed.emit()
	var rows := ui.get_node("%ResumeList").get_child_count()
	assert(rows == 2 and ui.get_node("%ResumeScroll").visible and not ui.get_node("%Host").visible, "resume screen lists both: %d" % rows)
	var first: Button = ui.get_node("%ResumeList").get_child(0)
	assert("Night" in first.text and "crew" in first.text and first.custom_minimum_size.y >= 48, "row label: " + first.text)
	ui.get_node("%ResumeBack").pressed.emit()
	assert(ui.get_node("%Host").visible and not ui.get_node("%ResumeScroll").visible, "Back returns home")
	ui.get_node("%Resume").pressed.emit()
	ui.get_node("%AdvancedToggle").button_pressed = true
	var entries: Array[Dictionary] = SaveManager.list_checkpoints()
	ui._on_resume_pick(entries[0])
	assert(SaveManager.pending_resume != null and SaveManager.pending_resume.crew_cash == entries[0].cash, "pending_resume set from the pick")
	assert(nm.is_host() and ui.get_node("%Roster").visible, "picking hosts and opens the room")
	assert("Resuming" in ui.get_node("%Status").text, "room says it is a resume")
	assert(not ui.get_node("%ModeBox").visible, "a resume brings its own mode: no pick")
	ui.get_node("%Leave").pressed.emit()
	assert(SaveManager.pending_resume == null, "Leave drops the pick")
