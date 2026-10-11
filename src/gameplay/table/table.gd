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
## Footprint slack when thawing resting balls around a hole that moved or grew, in ball radii.
const THAW_REACH_RADII := 2.0

@export var spec: TableSpec = TableSpec.new()

var pockets: Dictionary = {}  # StringName -> PocketSpec, world-space (doc 01 §5)
var pocket_radius_mult := 1.0  # 03 `pocket_radius_mult`; geometry is rebuilt when it changes
var pocket_osc_m := 0.0  # 03 `pocket_oscillation_m`: amplitude the openings slide along their rail (covers over a wider cut)
var pocket_seed := 0  # Round seed: with the tick clock it fixes every pocket's phase, so no packets
var _pocket_t := 0.0
var _pocket_t_manual := false  # set_pocket_time() pins the clock (probes, tools)
var felt_color := TableVisuals.CLOTH_COLOR  # BarSkin felt; re-applied by rebuild()
var layout: TableLayout  # raw TableGeometry.layout() output, table-local at cloth height (y = 0)

@onready var sim: PhysicsSim = $PhysicsSim


func cloth_y() -> float:
	return spec.bed_height_m


func get_pocket(id: StringName) -> PocketSpec:
	return pockets.get(id)


func _ready() -> void:
	sim.active_changed.connect(_set_pockets_live)
	set_physics_process(false)
	set_process(false)  # _process is defined: it would walk every child each frame (~60 us) until oscillation asks for it
	rebuild()


## The cloth colour (06 P18 bar skins). Visual only: friction lives in the spec and the Effects.
func set_felt_color(c: Color) -> void:
	felt_color = c
	TableVisuals.set_cloth_color(self, c)


## Frees every generated child (bodies + visuals; not `sim`), recomputes `layout` from `spec`,
## and rebuilds. Balls are NOT re-spawned here — DemoRack (or a future RoundDirector) owns that.
## A hole that grows or moves takes the support from under any resting ball near it, so those are thawed first (E2).
func rebuild() -> void:
	var next := TableGeometry.layout(spec, pocket_radius_mult, pocket_osc_m)
	_thaw_near_holes(layout, next)
	for c in get_children():
		if c == sim:
			continue
		remove_child(c)
		c.free()

	layout = next
	var y := spec.bed_height_m
	pockets.clear()
	for ps in layout.pockets:
		var world_ps := PocketSpec.new()
		world_ps.id = ps.id
		world_ps.position = ps.position + Vector3(0, y, 0)
		world_ps.mouth_normal = ps.mouth_normal
		world_ps.mouth_width_m = ps.mouth_width_m
		pockets[world_ps.id] = world_ps

	TableBuilder.build(self, spec, layout, y, pocket_osc_m)
	TableVisuals.build(self, spec, layout, y, pocket_osc_m)
	TableVisuals.set_cloth_color(self, felt_color)

	for area in get_children():
		if area is Area3D and area.has_meta(&"pocket_id"):
			area.body_entered.connect(_on_drop_zone_entered.bind(area.get_meta(&"pocket_id")))
	_set_pockets_live(sim.awake > 0)

	_apply_pocket_offsets()
	rebuilt.emit()


## Resting (frozen) balls within reach of any old or new hole wake up, so the changed support drops them instead of
## leaving them hovering over a hole that just opened under them.
func _thaw_near_holes(old: TableLayout, next: TableLayout) -> void:
	if old == null:
		return
	for b in sim.get_balls():
		if b.retired or not b.freeze:
			continue
		var p := to_local(b.global_position)
		for lay in [old, next]:
			for hole: TableLayout.Hole in lay.holes.values():
				if Vector2(p.x, p.z).distance_to(hole.center) < hole.cup_radius + (hole.cup_radius - hole.radius) + b.radius * THAW_REACH_RADII:
					b.freeze = false
					b.wake()
					break


## True when table-local xz `p` lies inside any pocket's cup circle widened by `margin` (a ball in there is dropping
## or potted, never "off the table").
func in_hole(p: Vector2, margin := 0.0) -> bool:
	for hole: TableLayout.Hole in layout.holes.values():
		if p.distance_to(hole.center) < hole.cup_radius + margin:
			return true
	return false


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


## Round setup (host and clients alike: the stats come from the same synced Effects, the seed from the
## Round). Rebuilds only when the radius actually changed; oscillation needs no rebuild.
func apply_pocket_stats(radius_mult: float, osc_m: float, seed: int) -> void:
	pocket_seed = seed
	set_physics_process(osc_m > 0.0)  # host: the tick the covers move on
	set_process(osc_m > 0.0)  # every peer: the frame the covers are drawn on
	if not is_equal_approx(radius_mult, pocket_radius_mult) or not is_equal_approx(osc_m, pocket_osc_m):
		pocket_radius_mult = radius_mult
		pocket_osc_m = osc_m
		rebuild()
	else:
		_apply_pocket_offsets()


## Lateral offset (m) of `pocket_id`'s chute at `t` seconds: a pure function of (seed, id, t).
static func pocket_offset(seed: int, pocket_id: StringName, t: float, amplitude: float) -> float:
	var phase := float(absi(hash([seed, pocket_id])) % 1000) / 1000.0 * TAU
	return amplitude * sin(TAU * t / OSC_PERIOD_SEC + phase)


func set_pocket_time(t: float) -> void:
	_pocket_t = t
	_pocket_t_manual = true
	_apply_pocket_offsets()


## One clock for collider and picture: PhysicsSim.pocket_time() is the host's clock on the host and the same
## clock, playback-delayed, on clients — so the opening you see is where the host's Jolt lets a ball fall.
func _physics_process(_delta: float) -> void:
	_tick_pocket_clock()
	if multiplayer.is_server():
		_release_balls_over_openings()


func _process(_delta: float) -> void:
	_tick_pocket_clock()


func _tick_pocket_clock() -> void:
	if not _pocket_t_manual:
		_pocket_t = sim.pocket_time()
	_apply_pocket_offsets()


## A frozen ball whose centre the sliding opening has just reached is released: the cover left it no support.
func _release_balls_over_openings() -> void:
	for b in sim.get_balls():
		if b.retired or not b.freeze:
			continue
		var p := to_local(b.global_position)
		for hole: TableLayout.Hole in layout.holes.values():
			var ps: PocketSpec = pockets.get(hole.pocket_id)
			var at := hole.center + _tangent(ps) * pocket_offset(pocket_seed, hole.pocket_id, _pocket_t, pocket_osc_m)
			if Vector2(p.x, p.z).distance_to(at) < hole.radius:
				b.freeze = false
				b.wake()
				break


static func _tangent(ps: PocketSpec) -> Vector2:
	return Vector2(-ps.mouth_normal.y, ps.mouth_normal.x).normalized()


## Slides each pocket's cover ring along the rail (tangent of the mouth normal): the opening moves, the cut stays.
func _apply_pocket_offsets() -> void:
	for node in get_children():
		if not (node is AnimatableBody3D and String(node.name).begins_with("Cover_")):
			continue
		if not node.has_meta(&"base_position"):
			node.set_meta(&"base_position", node.position)
		var id := StringName(String(node.name).trim_prefix("Cover_"))
		var ps: PocketSpec = pockets.get(id)
		var base: Vector3 = node.get_meta(&"base_position")
		if ps == null or pocket_osc_m <= 0.0:
			node.position = base
			continue
		var t := _tangent(ps)
		node.position = base + Vector3(t.x, 0.0, t.y) * pocket_offset(pocket_seed, id, _pocket_t, pocket_osc_m)
