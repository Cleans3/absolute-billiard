extends SceneTree
## Lobby UI: Host LAN → room shows code slot, roster with us as host, Start visible; Leave returns home.
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
	await process_frame
	var ui: Control = lobby.get_node("LobbyUI")
	assert(not ui.get_node("%Resume").visible, "Resume hidden with no checkpoints")
	_resume_flow(ui, nm)
	assert(nm.steam_available() or not ui.get_node("%Steam").visible, "Steam button must be hidden without Steam")
	ui.get_node("%HostLan").pressed.emit()
	await process_frame
	assert(ui.get_node("%Roster").visible and not ui.get_node("%Solo").visible, "room state")
	assert("(host)" in ui.get_node("%Roster").text and "(you)" in ui.get_node("%Roster").text, "roster line")
	assert(ui.get_node("%Start").visible, "host sees Start")
	assert(not ui.get_node("%Share").visible, "no share link without a lobby code")
	assert(DeepLink.code_from_url("absolutebilliard://j/ab3k7q") == "AB3K7Q", "scheme link")
	assert(DeepLink.code_from_url("http://1.2.3.4:8892/j/AB3K7Q") == "AB3K7Q", "share link")
	assert(DeepLink.code_from_url("http://1.2.3.4/x/AB3K7Q") == "", "not an invite")
	var page_port := FileAccess.get_file_as_string("res://deploy/noray/vps/join.service").get_slice("join_page.py ", 1).strip_edges().get_slice("\n", 0)
	assert(NetConfig.new().share_base_url.ends_with(":" + page_port), "share link must hit the deployed join page port")
	ui.get_node("%Leave").pressed.emit()
	await process_frame
	await process_frame
	assert(not nm.is_host() and nm.get_roster().is_empty(), "left")
	for f in DirAccess.get_files_at(SaveManager.checkpoint_dir()):
		DirAccess.remove_absolute(SaveManager.checkpoint_dir().path_join(f))
	DirAccess.remove_absolute(SaveManager.checkpoint_dir())
	DirAccess.remove_absolute(SaveManager.root)
	print("LOBBY UI OK")
	quit()


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
	ui.get_node("%Leave").pressed.emit()
	assert(SaveManager.pending_resume == null, "Leave drops the pick")
