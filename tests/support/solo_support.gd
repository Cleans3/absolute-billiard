class_name SoloSupport
extends RefCounted
## For probes that press Lobby > Solo: MainLevel loads on a thread behind the loading screen (docs/plan/04), so wait
## for the bar to be playable (MainLevel is the current scene, the screen has ended, the local player stands in it)
## instead of counting frames.
## The campaign starts as the level comes up and Night 1's story cards open over the bar (docs/plan/09 §3.1); a probe that is
## not about the story reads past them (they close here), because an open modal gates the player and holds the toasts back.
## `keep_story` leaves them open for the probes under tests/story.

static func until_playable(tree: SceneTree, sec := 60.0, keep_story := false) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < sec * 1000.0:
		var scene := tree.current_scene
		if scene != null and scene.name == "MainLevel" and tree.root.get_node_or_null("LoadingScreen") == null:
			if not keep_story:
				await _past_story(tree, scene)
			return
		await tree.process_frame
	push_error("SoloSupport: the bar was not playable after %d s" % int(sec))


## Waits for the campaign to start (the Intermission before Round 1), then closes the intro cards if they opened.
static func _past_story(tree: SceneTree, level: Node) -> void:
	var loop := level.get_node_or_null("GameLoop") as GameLoop
	for i in 120:
		if loop == null or loop.phase == GameLoop.Phase.INTERMISSION:
			break
		await tree.process_frame
	var cards := level.get_node_or_null("UILayer/StoryCards") as StoryCards
	if cards != null and cards.is_open():
		cards.close()
		await tree.process_frame
