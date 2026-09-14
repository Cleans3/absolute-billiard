extends SceneTree

## Headless gizmo-vs-layout probe (loop 1, gamma K, plan.md T4.5): every value debug_gizmos draws
## must equal what TableGeometry.layout()/table_builder.gd actually built, not a duplicated
## formula — prints a delta per rail/drop-zone/pocket, all of which must read 0.
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

	# Three-way per T5.3: gizmo vs layout (should be trivially 0, gizmo just echoes layout now)
	# AND layout vs the actual built Area3D collider shapes (the real regression check — loop-1's
	# gizmo_probe only ever compared gizmo-vs-layout, so it stayed green while table_builder.gd
	# quietly built something else entirely; catch that class of drift here for good).
	var built_shapes: Array = []  # [{pocket_id, position: Vector3 (global), size: Vector3}]
	for area in table.find_children("Drop_*", "Area3D", true, false):
		var pid: StringName = area.get_meta(&"pocket_id")
		for c in area.get_children():
			if c is CollisionShape3D:
				built_shapes.append({pocket_id = pid, position = c.global_position, size = c.shape.size})

	for i in lay.drop_zones.size():
		var dz: Dictionary = lay.drop_zones[i]
		var gd: Dictionary = geo.drops[i]
		var dz_pos: Vector3 = dz.position
		var dz_size: Vector3 = dz.size
		var gd_pos: Vector3 = gd.position
		var gd_size: Vector2 = gd.size
		var world_pos := table.to_global(dz_pos + y)
		var gizmo_delta := (gd_pos - world_pos).length()
		var gizmo_size_delta := (gd_size - Vector2(dz_size.x, dz_size.z)).length()
		max_delta = maxf(max_delta, maxf(gizmo_delta, gizmo_size_delta))

		var best_built_delta := INF
		var best_built_size_delta := INF
		for bs in built_shapes:
			if bs.pocket_id != dz.pocket_id:
				continue
			var d: float = (bs.position - world_pos).length()
			if d < best_built_delta:
				best_built_delta = d
				best_built_size_delta = (bs.size - dz_size).length()
		max_delta = maxf(max_delta, maxf(best_built_delta, best_built_size_delta))
		print("drop %s: gizmo delta pos=%.5f size=%.5f | collider delta pos=%.5f size=%.5f" % [dz.pocket_id, gizmo_delta, gizmo_size_delta, best_built_delta, best_built_size_delta])

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
