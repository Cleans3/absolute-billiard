extends Label
## The "host away" banner (docs/plan/04 §6): how long the host has been gone and how long ENet gives it before it drops.

func _process(_delta: float) -> void:
	if visible:
		text = get_node(^"/root/NetManager").host_away_text()
