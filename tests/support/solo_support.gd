class_name SoloSupport
extends RefCounted
## For probes that press Lobby > Solo: MainLevel loads on a thread behind the loading screen (docs/plan/04), so wait
## for the bar to be playable (MainLevel is the current scene, the screen has ended, the local player stands in it)
## instead of counting frames.
## The campaign starts as the level comes up and Night 1's story cards open over the bar (docs/plan/09 §3.1); a probe that is
## not about the story reads past them (they close here), because an open modal gates the player and holds the toasts back.
## `keep_story` leaves them open for the probes under tests/story.
## The Night's first Intermission also pours the crew one house Drink (docs/plan/02 §3.10), which takes a slot and a Reward
## term; a probe that is not about Drinks reads past it too (it ends here as a Round would end it). `keep_pour` leaves it
## for the probes that test the pour.
## The Round's set-up / clean-up pictures (docs/plan/01 §3, 06 P33 A4) are skipped (`RoundDirector.skip_staging`): a probe that presses Solo wants
## the rack on the table the moment GO LIVE is pressed. `keep_staging` leaves them on for the probes that test them.

static func until_playable(tree: SceneTree, sec := 60.0, keep_story := false, keep_pour := false, keep_staging := false) -> void:
	RoundDirector.skip_staging = not keep_staging
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < sec * 1000.0:
		var scene := tree.current_scene
		if scene != null and scene.name == "MainLevel" and tree.root.get_node_or_null("LoadingScreen") == null:
			if not keep_story:
				await _past_story(tree, scene)
			if not keep_pour:
				await _past_pour(tree, scene)
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


## The pour lands with the first Intermission (host, same frame as the phase change); then the house Drink is ended.
static func _past_pour(tree: SceneTree, level: Node) -> void:
	var loop := level.get_node_or_null("GameLoop") as GameLoop
	for i in 120:
		if loop == null or loop.phase == GameLoop.Phase.INTERMISSION:
			break
		await tree.process_frame
	var fx := level.get_node_or_null("EffectManager") as EffectManager
	if fx != null:
		fx._on_round_ended(&"timer", 0)
