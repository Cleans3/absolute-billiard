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
	panel.offset_bottom = 220
	add_child(panel)
	_label = Label.new()
	panel.add_child(_label)


func _process(_delta: float) -> void:
	if not visible:
		return
	var lines := PackedStringArray()
	lines.append("fps: %d" % Engine.get_frames_per_second())
	lines.append("physics tick: %d Hz" % Engine.physics_ticks_per_second)
	lines.append("physics step: %.2f ms" % (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0))
	# PHYSICS_3D_COLLISION_PAIRS reads 0 under Jolt (verified live, gamma_probe.log case J; no
	# Jolt-specific replacement monitor documented for 4.7 — src/debug/README.md). Sum each ball's
	# own get_colliding_bodies() instead, valid while contact_monitor is on (only during a shot).
	var pairs := 0
	if table and table.sim:
		for ball in table.sim.get_balls():
			if ball.contact_monitor:
				pairs += ball.get_colliding_bodies().size()
	lines.append("contact pairs: %d" % pairs)
	if table and table.sim:
		lines.append("awake balls: %d" % table.sim.awake)
		for ball in table.sim.get_balls():
			if not ball.is_pocketed:
				lines.append("  %s: %.2f m/s" % [ball.id, ball.linear_velocity.length()])
	_label.text = "\n".join(lines)
