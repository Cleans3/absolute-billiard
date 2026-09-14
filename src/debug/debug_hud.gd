class_name DebugHud
extends CanvasLayer

## HUD panel (T2.2): fps, physics tick, physics step time, awake balls, contact pairs,
## per-ball speed. Toggled by debug_hud (F1).

var table: Table
var rack: Node3D

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
	lines.append("physics step: %.2f ms" % Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
	lines.append("contact pairs: %d" % int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)))
	if table and table.sim:
		lines.append("awake balls: %d" % table.sim.awake)
	if rack:
		for ball in rack.get_children():
			if ball is Ball and not ball.is_pocketed:
				lines.append("  %s: %.2f m/s" % [ball.id, ball.linear_velocity.length()])
	_label.text = "\n".join(lines)
