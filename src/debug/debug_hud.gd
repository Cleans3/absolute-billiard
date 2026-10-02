class_name DebugHud
extends CanvasLayer

## HUD panel (T2.2): fps, physics tick, physics step time, awake balls, contact pairs,
## per-ball speed. Toggled by debug_hud (F1).

var table: Table

var _label: Label


func _ready() -> void:
	layer = 10
	var panel := PanelContainer.new()
	panel.offset_left = 8
	panel.offset_top = 8
	panel.offset_right = 260
	panel.offset_bottom = 240
	add_child(panel)
	_label = Label.new()
	panel.add_child(_label)


func _process(_delta: float) -> void:
	if not visible:
		return
	var lines := PackedStringArray()
	lines.append("fps: %d" % Engine.get_frames_per_second())
	var loop := get_tree().current_scene.get_node_or_null("GameLoop") if get_tree().current_scene != null else null
	if loop != null:  # the Round seed left the player HUD for here (docs 08 §2.7)
		lines.append("seed: %d" % loop.round_seed)
	lines.append("physics tick: %d Hz" % Engine.physics_ticks_per_second)
	lines.append("physics step: %.2f ms" % (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0))
	# PHYSICS_3D_COLLISION_PAIRS reads 0 under Jolt (verified live, gamma_probe.log case J; no
	# Jolt-specific replacement monitor documented for 4.7 — src/debug/README.md). Sum each ball's
	# own get_colliding_bodies() instead, valid while contact_monitor is on (only during a shot).
	# Loop-2 T5.4 (gamma F3b): a ball-ball contact is reported from BOTH balls' own lists, so a raw
	# sum double-counts every pair; a ball-vs-Bed contact isn't a "cushion" hit either. Halve the
	# ball-ball tally and keep cushion/jaw hits in their own count, bed contacts in neither.
	var ball_ball := 0
	var ball_cushion := 0
	if table and table.sim:
		for ball in table.sim.get_balls():
			if not ball.contact_monitor:
				continue
			for o in ball.get_colliding_bodies():
				if o is Ball:
					ball_ball += 1
				elif o.has_meta(&"rail_normal") or o.has_meta(&"jaw"):
					ball_cushion += 1
	lines.append("contact pairs: %d (ball-cushion: %d)" % [ball_ball / 2, ball_cushion])
	if table and table.sim:
		lines.append("awake balls: %d" % table.sim.awake)
		for ball in table.sim.get_balls():
			if not ball.is_pocketed:
				lines.append("  %s: %.2f m/s" % [ball.id, ball.linear_velocity.length()])
	_label.text = "\n".join(lines)
