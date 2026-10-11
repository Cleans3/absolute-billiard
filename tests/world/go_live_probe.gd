extends SceneTree
## GO LIVE, solo (REQ#adhoc-1010a:flow A1/A2): Lobby → Solo → MainLevel at its first Intermission. No phase screen
## and no Start button; the pedestal stands at the contract spot and says 0/1; pressing it from across the room is
## refused (`too_far`, with its sentence); walking up to it shows the prompt, and ONE press starts Round 1; pressing in the
## live Round is refused (`not_intermission`).
## `godot --path . --headless -s tests/world/go_live_probe.gd`


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
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)  # past Night 1's story cards: an open modal would block the player and hold the toast
	var level := current_scene
	var gl: GameLoop = level.get_node("GameLoop")
	await _until(func() -> bool: return gl.phase == GameLoop.Phase.INTERMISSION, "Intermission")
	var phase_screen: PhaseScreen = level.get_node("UILayer/PhaseScreen")
	assert(not phase_screen.visible and not UIRouter.blocking(), "no phase screen at the Intermission: the player is free in the bar")
	var prop: Interactable
	for n in get_nodes_in_group(&"interactable"):
		if (n as Interactable).effective_kind() == &"go_live":
			prop = n
	assert(prop != null and prop.global_position.is_equal_approx(Bar.GO_LIVE_AT), "the go_live prop sits at the contract spot")
	var pedestal: GoLivePedestal
	for n in level.get_node("Bar").get_children():
		if n is GoLivePedestal:
			pedestal = n
	assert(pedestal != null and pedestal.global_position.is_equal_approx(Bar.GO_LIVE_AT), "the pedestal stands on the prop")
	assert(pedestal.get_node("Title").text == "GO LIVE" and "Ready 0/1" in pedestal.get_node("Status").text, "the pedestal says 0/1: " + pedestal.get_node("Status").text)
	assert(gl.ready_peers.is_empty() and Array(gl.waiting_peers) == [1], "solo waits on the host alone")

	var world: WorldInteractions = level.get_node("WorldInteractions")
	var player: Player = level.get_node("PlayerSpawner").get_local_player()
	var refused: Array[StringName] = []
	world.interaction_rejected.connect(func(_k: StringName, r: StringName) -> void: refused.append(r))
	prop.try_use()  # the spawn row is ~3 m from the pedestal
	await create_timer(0.2).timeout
	assert(refused == [&"too_far"] and gl.phase == GameLoop.Phase.INTERMISSION, "pressed from across the room: refused (%s)" % [refused])
	assert(WaitText.interaction(&"go_live", &"too_far") == "Too far away: step closer", "and it says what to do")

	player.global_position = Bar.GO_LIVE_AT + Vector3(-0.8, 0.05, 0.0)
	player.velocity = Vector3.ZERO
	await _until(func() -> bool: return player.prompt == "GO LIVE", "the GO LIVE prompt at the pedestal", 5.0)
	player.interact()
	assert(gl.phase == GameLoop.Phase.ROUND_LIVE and gl.round_index == 1, "one press starts Round 1 (solo)")
	assert(gl.ready_peers.is_empty() and gl.waiting_peers.is_empty(), "the ready set is cleared when the Round starts")
	assert("Opens between Rounds" in pedestal.get_node("Status").text, "the live Round: the pedestal says when it opens again")

	refused.clear()
	player.interact()  # prompt is stale for one frame at most; the host refuses either way
	await create_timer(0.2).timeout
	assert(refused == [&"not_intermission"], "pressed in the live Round: refused (%s)" % [refused])
	assert(UIRouter.instance._toast_label.text == "GO LIVE only works between Rounds", "toast: " + UIRouter.instance._toast_label.text)
	print("GO LIVE OK")
	quit()
