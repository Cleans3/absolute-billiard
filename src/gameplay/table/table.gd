class_name Table
extends Node3D

## Orchestrates bed/cushion/jaw/drop-plane construction from a TableSpec (01 §2, plan.md
## contract): table_builder.gd owns bodies, table_visuals.gd owns meshes, this file only wires
## them to a TableGeometry.layout() and republishes the result. A pot is a ball entering a drop
## plane; jaws make rattle/reject emerge.

signal ball_dropped(ball: Ball, pocket_id: StringName)
signal rebuilt

@export var spec: TableSpec = TableSpec.new()

var pockets: Dictionary = {}  # StringName -> PocketSpec, world-space (doc 01 §5)
var layout: TableLayout  # raw TableGeometry.layout() output, table-local at cloth height (y = 0)

@onready var sim: PhysicsSim = $PhysicsSim


func cloth_y() -> float:
	return spec.bed_height_m


func get_pocket(id: StringName) -> PocketSpec:
	return pockets.get(id)


func _ready() -> void:
	sim.active_changed.connect(_set_pockets_live)
	rebuild()


## Frees every generated child (bodies + visuals; not `sim`), recomputes `layout` from `spec`,
## and rebuilds. Balls are NOT re-spawned here — DemoRack (or a future RoundDirector) owns that.
func rebuild() -> void:
	for c in get_children():
		if c == sim:
			continue
		remove_child(c)
		c.free()

	layout = TableGeometry.layout(spec)
	var y := spec.bed_height_m
	pockets.clear()
	for ps in layout.pockets:
		var world_ps := PocketSpec.new()
		world_ps.id = ps.id
		world_ps.position = ps.position + Vector3(0, y, 0)
		world_ps.mouth_normal = ps.mouth_normal
		world_ps.mouth_width_m = ps.mouth_width_m
		pockets[world_ps.id] = world_ps

	TableBuilder.build(self, spec, layout, y)
	TableVisuals.build(self, spec, layout, y)

	for area in get_children():
		if area is Area3D and area.has_meta(&"pocket_id"):
			area.body_entered.connect(_on_drop_zone_entered.bind(area.get_meta(&"pocket_id")))
	_set_pockets_live(sim.awake > 0)

	rebuilt.emit()


## 07 §1.4: a monitoring Area3D is a Jolt sensor stepped every tick — 6 of them cost ~0.45 ms at rest. Only the
## host resolves pots, and only while balls move; clients keep theirs on (kinematic balls, no awake count).
func _set_pockets_live(on: bool) -> void:
	on = on or not multiplayer.is_server()
	for area in get_children():
		if area is Area3D and area.has_meta(&"pocket_id"):
			area.set_deferred(&"monitoring", on)


func _on_drop_zone_entered(body: Node3D, pocket_id: StringName) -> void:
	if body is Ball and not body.is_pocketed:
		body.pocket(pocket_id)
		ball_dropped.emit(body, pocket_id)
