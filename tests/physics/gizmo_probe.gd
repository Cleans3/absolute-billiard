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

	for i in lay.drop_zones.size():
		var dz: Dictionary = lay.drop_zones[i]
		var gd: Dictionary = geo.drops[i]
		var dz_pos: Vector3 = dz.position
		var dz_size: Vector2 = dz.size
		var gd_pos: Vector3 = gd.position
		var gd_size: Vector2 = gd.size
		var pos_delta := (gd_pos - table.to_global(dz_pos + y)).length()
		var size_delta := (gd_size - dz_size).length()
		max_delta = maxf(max_delta, maxf(pos_delta, size_delta))
		print("drop %s position delta=%.5f size delta=%.5f (gizmo %s vs layout %s)" % [dz.pocket_id, pos_delta, size_delta, gd_size, dz_size])

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
