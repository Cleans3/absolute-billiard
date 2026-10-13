extends SceneTree
## 09 S1: every campaign Night and the Endless resource carry story text inside the limits (intro cards at most 4, 140
## characters each), no line repeats inside a campaign, the finale (Night 3) alone carries the ending cards, the text holds the
## abduction frame (06 P39, 09 D12) and no money amount (the numbers live on the NightConfig and get recalibrated), no 4th / 5th
## Night is left over, and Nights past the last one share endless.tres.
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
	var money := RegEx.create_from_string("\\$\\s?\\d")
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
		_check(s.paid_line != "", "Night %d has a paid line (Endless plays the finale as a plain Night and reads it)" % (i + 1))
		_check(s.ending_cards.size() == (3 if i == 2 else 0), "Night %d: the three ending cards are the finale's alone (%d)" % [i + 1, s.ending_cards.size()])
		for c in s.ending_cards:
			_check(c.length() <= MAX_CARD_CHARS, "Night %d ending card is %d characters: %s" % [i + 1, c.length(), c])
		for text: String in s.intro_cards + s.call + s.gus_lines + s.ending_cards + [s.paid_line, s.short_line, s.chat_line]:
			if text == "":
				continue
			_check(not money.search(text), "no money amount in the story text, the blackboard has the numbers: %s" % text)
			_check(not seen.has(text), "no line repeats in a campaign: %s" % text)
			seen[text] = true
	# the abduction frame: the Rope, the cabin and the locked door open the story; Moe, Gus and velvet stay
	var opening := " ".join(nights[0].story.intro_cards)
	_check(opening.contains("Rope") and opening.contains("cabin") and opening.contains("locks") and opening.contains("Gus") and opening.contains("Moe"), "Night 1 opens with the abduction: the Rope, a cabin, a lock, Gus, Moe")
	_check(nights[2].story.ending_cards[2].contains("velvet") and nights[2].story.ending_cards[1].contains("Gus stays"), "the ending names velvet and keeps Gus")
	for gone in ["night_4", "night_5"]:
		_check(not ResourceLoader.exists("res://src/resources/story/%s.tres" % gone), "%s.tres is gone with the 5-Night campaign" % gone)
	# the last Night's gate is the Buyout, and Endless Nights share one resource
	var endless := NightConfig.endless(nights[2], 4)
	_check(endless.story != null and endless.story.night == 0, "an Endless Night carries endless.tres")
	_check(endless.story.intro_cards.size() == 1 and endless.story.call.is_empty() and endless.story.gus_lines.is_empty(), "endless.tres: one card, no call, no Gus lines")
	_check(NightConfig.endless(nights[2], 9).story == endless.story, "every Endless Night shares the resource")
	_check(nights[2].story.night == 3, "generating Endless leaves Night 3's own story alone")
	if fails == 0:
		print("STORY DATA OK")
	quit(fails)
