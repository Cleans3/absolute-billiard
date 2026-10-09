class_name SoloSupport
extends RefCounted
## For probes that press Lobby > Solo: MainLevel loads on a thread behind the loading screen (docs/plan/04), so wait
## for the bar to be playable (MainLevel is the current scene, the screen has ended, the local player stands in it)
## instead of counting frames.

static func until_playable(tree: SceneTree, sec := 60.0) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < sec * 1000.0:
		var scene := tree.current_scene
		if scene != null and scene.name == "MainLevel" and tree.root.get_node_or_null("LoadingScreen") == null:
			return
		await tree.process_frame
	push_error("SoloSupport: the bar was not playable after %d s" % int(sec))
