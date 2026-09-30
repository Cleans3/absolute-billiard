class_name Table
extends Node3D

## Orchestrates bed/cushion/jaw/drop-plane construction from a TableSpec (01 §2, plan.md
## contract): table_builder.gd owns bodies, table_visuals.gd owns meshes, this file only wires
## them to a TableGeometry.layout() and republishes the result. A pot is a ball entering a drop
## plane; jaws make rattle/reject emerge.

signal ball_dropped(ball: Ball, pocket_id: StringName)
signal rebuilt

## Pocket oscillation period, seconds [tune].
const OSC_PERIOD_SEC := 6.0

@export var spec: TableSpec = TableSpec.new()

var pockets: Dictionary = {}  # StringName -> PocketSpec, world-space (doc 01 §5)
var pocket_radius_mult := 1.0  # 03 `pocket_radius_mult`; geometry is rebuilt when it changes
var pocket_osc_m := 0.0  # 03 `pocket_oscillation_m`: amplitude the drop chutes slide along their rail
var pocket_seed := 0  # Round seed: with the tick clock it fixes every pocket's phase, so no packets
var _pocket_t := 0.0
var layout: TableLayout  # raw TableGeometry.layout() output, table-local at cloth height (y = 0)

@onready var sim: PhysicsSim = $PhysicsSim


func cloth_y() -> float:
	return spec.bed_height_m


func get_pocket(id: StringName) -> PocketSpec:
	return pockets.get(id)


func _ready() -> void:
	set_physics_process(false)
	rebuild()


## Frees every generated child (bodies + visuals; not `sim`), recomputes `layout` from `spec`,
## and rebuilds. Balls are NOT re-spawned here — DemoRack (or a future RoundDirector) owns that.
func rebuild() -> void:
	for c in get_children():
		if c == sim:
			continue
		remove_child(c)
		c.free()

	layout = TableGeometry.layout(spec, pocket_radius_mult)
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

	_apply_pocket_offsets()
	rebuilt.emit()


func _on_drop_zone_entered(body: Node3D, pocket_id: StringName) -> void:
	if body is Ball and not body.is_pocketed:
		body.pocket(pocket_id)
		ball_dropped.emit(body, pocket_id)


## Round setup (host and clients alike: the stats come from the same synced Effects, the seed from the
## Round). Rebuilds only when the radius actually changed; oscillation needs no rebuild.
func apply_pocket_stats(radius_mult: float, osc_m: float, seed: int) -> void:
	pocket_osc_m = osc_m
	pocket_seed = seed
	set_physics_process(osc_m > 0.0)
	if not is_equal_approx(radius_mult, pocket_radius_mult):
		pocket_radius_mult = radius_mult
		rebuild()
	else:
		_apply_pocket_offsets()


## Lateral offset (m) of `pocket_id`'s chute at `t` seconds: a pure function of (seed, id, t).
static func pocket_offset(seed: int, pocket_id: StringName, t: float, amplitude: float) -> float:
	var phase := float(absi(hash([seed, pocket_id])) % 1000) / 1000.0 * TAU
	return amplitude * sin(TAU * t / OSC_PERIOD_SEC + phase)


func set_pocket_time(t: float) -> void:
	_pocket_t = t
	_apply_pocket_offsets()


func _physics_process(delta: float) -> void:
	_pocket_t += delta
	_apply_pocket_offsets()


## Slides each pocket's drop-zone Area3D along the rail (tangent of the mouth normal).
func _apply_pocket_offsets() -> void:
	for area in get_children():
		if not (area is Area3D and area.has_meta(&"pocket_id")):
			continue
		if not area.has_meta(&"base_position"):
			area.set_meta(&"base_position", area.position)
		var id: StringName = area.get_meta(&"pocket_id")
		var ps: PocketSpec = pockets.get(id)
		var base: Vector3 = area.get_meta(&"base_position")
		if ps == null or pocket_osc_m <= 0.0:
			area.position = base
			continue
		var tangent := Vector3(-ps.mouth_normal.y, 0.0, ps.mouth_normal.x).normalized()
		area.position = base + tangent * pocket_offset(pocket_seed, id, _pocket_t, pocket_osc_m)
