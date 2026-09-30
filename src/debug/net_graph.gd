class_name NetGraph
extends CanvasLayer

## Netcode readout (07 §3): ball events/s and bytes/s through PhysicsSim (sent on the host, received
## on a client), how far the client renders behind the newest event, and the last SimDiff error if a
## SimDiff node is running. Hidden by default; toggled by debug_netgraph (F8).

var table: Table

var _label: Label
var _acc := 0.0
var _last_events := 0
var _last_bytes := 0
var _events_s := 0.0
var _bytes_s := 0.0


func _ready() -> void:
	layer = 10
	var panel := PanelContainer.new()
	panel.offset_left = 8
	panel.offset_top = 230
	panel.offset_right = 330
	panel.offset_bottom = 340
	add_child(panel)
	_label = Label.new()
	panel.add_child(_label)


func _process(delta: float) -> void:
	if not visible or table == null:
		return
	var sim := table.sim
	_acc += delta
	if _acc >= 1.0:
		_events_s = (sim.net_events - _last_events) / _acc
		_bytes_s = (sim.net_bytes - _last_bytes) / _acc
		_last_events = sim.net_events
		_last_bytes = sim.net_bytes
		_acc = 0.0
	var role := "host" if sim.multiplayer.is_server() else "client"
	var lines := PackedStringArray()
	lines.append("net (%s): %.0f events/s, %.0f B/s (budget 16 KB/s up)" % [role, _events_s, _bytes_s])
	lines.append("shot %d: %d events, %d B" % [sim.shot_id, sim.net_events_shot, sim.net_bytes_shot])
	if role == "client":
		lines.append("playback: %.0f ms behind, newest event %.0f ms ahead" % [PhysicsSim.INTERP_DELAY_SEC * 1000.0, sim.event_lead_ms()])
	for d in get_tree().get_nodes_in_group(&"sim_diff"):
		lines.append("SimDiff max err: %.2f mm" % (d.max_err_m * 1000.0))
	_label.text = "\n".join(lines)
