class_name SlotProp
extends Interactable
## The slot machine's use target: Interact opens the SlotScreen (the spin is that screen's own request), not a bare request.


func try_use(_payload := {}) -> bool:
	var screen := get_tree().get_first_node_in_group(&"slot_screen") as SlotScreen
	if screen == null:
		return false
	screen.open()
	return true
