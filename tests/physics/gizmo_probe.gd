extends SceneTree

## Headless gizmo-vs-layout probe (loop 1, gamma K, plan.md T4.5): every value debug_gizmos draws
## must equal what TableGeometry.layout()/table_builder.gd actually built, not a duplicated
## formula — prints a delta per rail/pot sensor/pocket, all of which must read 0.
##   godot --path . --headless -s tests/physics/gizmo_probe.gd

const TABLE := preload("res://src/gameplay/table/Table.tscn")


func _init() -> void:
	_run()


func _run() -> void:
	await physics_frame
	var table: Table = TABLE.instantiate()
	root.add_child(table)
	await physics_frame
	var g := DebugGizmos.new()
	g.table = table
	root.add_child(g)
	var geo: Dictionary = g._geometry()
	var lay := table.layout
	var y := Vector3(0, table.spec.bed_height_m, 0)
	var max_delta := 0.0

	for i in lay.rails.size():
		var rail: TableLayout.RailSegment = lay.rails[i]
		var gr: Dictionary = geo.rails[i]
		var ga: Vector3 = gr.a
		var gb: Vector3 = gr.b
		var da := (ga - table.to_global(rail.a + y)).length()
		var db := (gb - table.to_global(rail.b + y)).length()
		max_delta = maxf(max_delta, maxf(da, db))
		print("rail %s delta a=%.5f b=%.5f" % [rail.id, da, db])

	# Three-way: gizmo vs layout (should be trivially 0, gizmo just echoes layout) AND layout vs the actual built
	# pot-sensor shapes (the real regression check: a gizmo that only ever echoed the layout stayed green while
	# table_builder.gd quietly built something else).
	var built_shapes: Array = []  # [{pocket_id, position: Vector3 (global), radius}]
	for area in table.find_children("Drop_*", "Area3D", true, false):
		var pid: StringName = area.get_meta(&"pocket_id")
		for c in area.get_children():
			if c is CollisionShape3D:
				built_shapes.append({pocket_id = pid, position = c.global_position, radius = c.shape.radius})

	for i in lay.pockets.size():
		var pid: StringName = lay.pockets[i].id
		var hole: TableLayout.Hole = lay.holes[pid]
		var gd: Dictionary = geo.drops[i]
		var gd_pos: Vector3 = gd.position
		var gd_radius: float = gd.radius
		var built: Dictionary = {}
		for bs in built_shapes:
			if bs.pocket_id == pid:
				built = bs
		var sensor_xz := Vector2(built.position.x, built.position.z) - Vector2(table.global_position.x, table.global_position.z)
		var d_xz := (sensor_xz - hole.center).length()
		var d_r := absf(float(built.radius) - hole.apothem)
		var d_gizmo_r := absf(gd_radius - hole.apothem)
		var d_gizmo_xz := (Vector2(gd_pos.x, gd_pos.z) - Vector2(table.global_position.x, table.global_position.z) - hole.center).length()
		max_delta = maxf(max_delta, maxf(maxf(d_xz, d_r), maxf(d_gizmo_r, d_gizmo_xz)))
		print("sensor %s: gizmo delta pos=%.5f r=%.5f | collider delta pos=%.5f r=%.5f" % [pid, d_gizmo_xz, d_gizmo_r, d_xz, d_r])

	for i in lay.pockets.size():
		var ps: PocketSpec = lay.pockets[i]
		var gp: Dictionary = geo.pockets[i]
		var gp_pos: Vector3 = gp.position
		var pdelta := (gp_pos - table.to_global(ps.position + y)).length()
		max_delta = maxf(max_delta, pdelta)
		print("pocket %s position delta=%.5f" % [ps.id, pdelta])

	print("gizmo probe: max_delta=%.5f" % max_delta)
	assert(max_delta < 0.0001, "debug_gizmos must draw exactly what Table.layout/table_builder built")
	print("GIZMO PROBE OK")
	quit()
