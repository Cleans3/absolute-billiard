extends SceneTree
## 09 S1: every campaign Night and the Endless resource carry story text inside the limits (intro cards at most 4, 140
## characters each), no line repeats inside a campaign, and Nights past the last one share endless.tres.
##   godot --path . --headless -s tests/story/story_data_probe.gd      prints STORY DATA OK

const MAX_CARDS := 4
const MAX_CARD_CHARS := 140

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	var nights: Array[NightConfig] = [
		load("res://src/resources/nights/night_1.tres"), load("res://src/resources/nights/night_2.tres"),
		load("res://src/resources/nights/night_3.tres")]
	var seen := {}
	for i in nights.size():
		var s: StoryNight = nights[i].story
		_check(s != null, "Night %d has a StoryNight" % (i + 1))
		if s == null:
			continue
		_check(s.night == nights[i].night_number, "Night %d: story.night matches (%d)" % [i + 1, s.night])
		_check(s.intro_cards.size() >= 1 and s.intro_cards.size() <= MAX_CARDS, "Night %d: 1-%d intro cards (%d)" % [i + 1, MAX_CARDS, s.intro_cards.size()])
		for c in s.intro_cards:
			_check(c.length() <= MAX_CARD_CHARS, "Night %d card is %d characters: %s" % [i + 1, c.length(), c])
		_check(s.call.size() >= 2, "Night %d has a phone call" % (i + 1))
		_check(s.gus_lines.size() == 4, "Night %d has four Gus lines" % (i + 1))
		_check(s.short_line != "" and s.chat_line != "", "Night %d has a short line and a velvet line" % (i + 1))
		_check(s.paid_line != "", "Night %d has a paid line (the finale's own ending is the F3 rewrite)" % (i + 1))
		_check(s.ending_cards.is_empty(), "Night %d: no ending cards until the finale is rewritten" % (i + 1))
		for text: String in s.intro_cards + s.call + s.gus_lines + s.ending_cards + [s.paid_line, s.short_line, s.chat_line]:
			if text == "":
				continue
			_check(not seen.has(text), "no line repeats in a campaign: %s" % text)
			seen[text] = true
	# the last Night's gate is the Buyout, and Endless Nights share one resource
	var endless := NightConfig.endless(nights[2], 4)
	_check(endless.story != null and endless.story.night == 0, "an Endless Night carries endless.tres")
	_check(endless.story.intro_cards.size() == 1 and endless.story.call.is_empty() and endless.story.gus_lines.is_empty(), "endless.tres: one card, no call, no Gus lines")
	_check(NightConfig.endless(nights[2], 9).story == endless.story, "every Endless Night shares the resource")
	_check(nights[2].story.night == 3, "generating Endless leaves Night 3's own story alone")
	if fails == 0:
		print("STORY DATA OK")
	quit(fails)
