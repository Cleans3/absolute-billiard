class_name DebugSpecPanel
extends CanvasLayer

## Live TableSpec tweak panel (T2.5): a spinbox for every float/int @export on TableSpec,
## generated from get_property_list() so it tracks whichever TableSpec is live (today's
## explicit fields, or the contract's `scale` knob post-merge) with no hardcoded list.
## Edits rebuild the table and re-spawn the rack. Toggled by debug_spec (F4).
##
## `Table.rebuild()` does not exist on today's main — guarded; until the table branch
## lands, edits still change live cloth/cushion feel (Ball/PhysicsSim read spec fields
## every tick) but not the baked CSG geometry. Guard removed at sync (plan.md Log).

var table: Table
var rack: Node3D

var _box: VBoxContainer


func _ready() -> void:
	layer = 10
	var panel := PanelContainer.new()
	panel.offset_left = -280
	panel.offset_top = 8
	panel.offset_right = -8
	panel.offset_bottom = 600
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	add_child(panel)
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	_box = VBoxContainer.new()
	scroll.add_child(_box)


func refresh() -> void:
	for c in _box.get_children():
		c.queue_free()
	if not table or not table.spec:
		return
	for prop in table.spec.get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		if prop.type != TYPE_FLOAT and prop.type != TYPE_INT:
			continue
		_add_row(prop.name)


func _add_row(prop_name: String) -> void:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = prop_name
	label.custom_minimum_size = Vector2(140, 0)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.step = 0.001
	spin.value = table.spec.get(prop_name)
	spin.value_changed.connect(func(v: float) -> void:
		table.spec.set(prop_name, v)
		_apply())
	row.add_child(spin)
	_box.add_child(row)


func _apply() -> void:
	if table.has_method("rebuild"):
		table.rebuild()
	if rack.has_method("spawn_layout") and rack.has_method("default_rack"):
		rack.spawn_layout(rack.default_rack())
	elif rack.has_method("spawn"):
		rack.spawn()
