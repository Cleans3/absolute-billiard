class_name JukeboxProp
extends Interactable
## The jukebox's use target (docs/plan/03 §3.7, 06 P55): the once-per-Round hype interaction goes out as before, and any press also skips the
## track for everyone (JukeboxPlayer: free, 3 s gate).


func try_use(payload := {}) -> bool:
	var sent := super.try_use(payload)
	var box := get_tree().get_first_node_in_group(&"jukebox") as JukeboxPlayer
	if box != null:
		box.press()
	return sent or box != null
