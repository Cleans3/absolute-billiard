extends SceneTree

## Top-face coverage of the table's visual meshes (adhoc-1013c W1, U3/U11): every point of the table's footprint, seen from above,
## is either a real surface at the right height or an open pit, never a hole in the rail and never a cap over a pocket.
##   rail top   outside the nose rectangle + cushion depth, outside every pocket cut: a surface at rail-top height
##              (a side pocket used to be an open notch behind its liner: no top face there)
##   pit        inside a pocket's ring: no wood or cloth at or above the cloth plane
##              (a corner pocket's outer half used to be capped by the apron top at cloth height)
##   cushion    the strip between the nose line and the rail block: something at or above the cloth plane
##   playfield  inside the nose rectangle, outside every hole: cloth
##   see-through  anywhere in the footprint: some visual mesh below the ray (a grid as fine as the CUT_GAP slot; a slot between the pocket liner and the wood's cut
##              once let a sight line down to the floor under the table, a pale ring at the jaw tips, 06 P40)
## Rays are cast straight down on a 1 cm grid against `Cloth`, `Visual_wood`, `Visual_dark`, `Visual_liner` (CPU triangle meshes).
##   godot --path . --headless -s tests/physics/table_top_probe.gd
## Prints counts, the first misses, and "TABLE TOP PROBE OK" when none.

const TABLE := preload("res://src/gameplay/table/Table.tscn")
const STEP := 0.01
const MARGIN := 0.004      # clear of a cut edge: the wall between wood and liner is not a surface to test
const LEAK_STEP := TableVisuals.CUT_GAP  # the see-through grid: no wider than the slot it looks for
const RIM_CLEAR := 0.003   # a pit point this far inside the footprint edge: the corner pocket leaves a hair of wood out there

var _fails := 0
var _meshes: Array[Dictionary] = []


func _init() -> void:
	_run()


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	var table: Table = TABLE.instantiate()
	root.add_child(table)
	await physics_frame
	_scan(table, "default")
	table.pocket_radius_mult = 1.3  # a shop upgrade: bigger holes
	table.rebuild()
	await physics_frame
	_scan(table, "pocket_radius_mult 1.3")
	if _fails > 0:
		quit(1)
		return
	print("TABLE TOP PROBE OK")
	quit()


func _scan(table: Table, label: String) -> void:
	_meshes.clear()
	for mi: MeshInstance3D in table.find_children("*", "MeshInstance3D", false, false):
		if mi.name in [&"Cloth", &"Visual_wood", &"Visual_dark", &"Visual_liner"]:
			_meshes.append({name = mi.name, tm = mi.mesh.generate_triangle_mesh(), inv = mi.transform.affine_inverse()})
	_check(_meshes.size() == 4, "%s: the table's four visual meshes are all there (%d)" % [label, _meshes.size()])
	var s := table.spec
	var y := s.bed_height_m
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var depth0 := s.ball_radius_m * 2.0
	var fx := hl + s.rail_width_m
	var fz := hw + s.rail_width_m
	var cut_extra := s.bed_thickness_m * 0.5 + TableVisuals.CUT_GAP + MARGIN
	var rail_top := y + s.rail_height_m
	var counts := {rail = 0, pit = 0, cushion = 0, field = 0}
	var misses := {rail = 0, pit = 0, cushion = 0, field = 0}
	var shown := 0
	var x := -fx + 0.0013
	while x < fx:
		var z := -fz + 0.0013
		while z < fz:
			var p := Vector2(x, z)
			var kind := _classify(table, p, hl, hw, depth0, fx, fz, cut_extra)
			if kind != &"":
				var hit := _hits(Vector3(x, y + 1.0, z))
				var ok := false
				match kind:
					&"rail":
						ok = hit.all >= rail_top - 0.001 and hit.all <= rail_top + 0.01
					&"pit":
						ok = hit.cover < y - 0.05
					&"cushion":
						ok = hit.all >= y - 0.001
					&"field":
						ok = hit.cloth >= y - 0.001
				counts[String(kind)] += 1
				if not ok:
					misses[String(kind)] += 1
					if shown < 8:
						shown += 1
						printerr("  miss %s at (%.3f, %.3f): topmost %.3f (all) %.3f (wood+cloth), cloth plane %.3f, rail top %.3f" % [kind, x, z, hit.all, hit.cover, y, rail_top])
			z += STEP
		x += STEP
	var leaks := 0
	var first := ""
	x = -fx + 0.0007
	while x < fx - 0.002:
		var z := -fz + 0.0009
		while z < fz - 0.002:
			if _hits(Vector3(x, y + 1.0, z)).all == -INF:
				leaks += 1
				if first == "":
					first = "(%.3f, %.3f)" % [x, z]
			z += LEAK_STEP
		x += LEAK_STEP
	_check(leaks == 0, "%s: %d see-through samples in the footprint, first at %s" % [label, leaks, first])
	print("%s: samples %s, misses %s, see-through %d" % [label, counts, misses, leaks])
	for k in misses:
		_check(counts[k] > 0, "%s: some %s samples" % [label, k])
		_check(misses[k] == 0, "%s: %d %s samples are wrong" % [label, misses[k], k])


## Which rule applies at table-local `p` (xz), or &"" when none does (a cut edge, a cushion foot, the footprint's outer edge).
func _classify(table: Table, p: Vector2, hl: float, hw: float, depth0: float, fx: float, fz: float, cut_extra: float) -> StringName:
	for hole: TableLayout.Hole in table.layout.holes.values():
		var d := p.distance_to(hole.center)
		var in_ring := d < hole.cup_radius - MARGIN
		if in_ring and absf(p.x) < fx - RIM_CLEAR and absf(p.y) < fz - RIM_CLEAR:
			return &"pit"
		if d < hole.cup_radius + cut_extra:
			return &""
	var outside_nose := absf(p.x) > hl or absf(p.y) > hw
	if not outside_nose:
		return &"field" if absf(p.x) < hl - 0.02 and absf(p.y) < hw - 0.02 else &""
	if absf(p.x) > hl + depth0 + 0.01 or absf(p.y) > hw + depth0 + 0.01:
		return &"rail" if absf(p.x) < fx - 0.005 and absf(p.y) < fz - 0.005 else &""
	if absf(p.x) > hl + 0.01 or absf(p.y) > hw + 0.01:
		return &"cushion"
	return &""


## Topmost hit of a straight-down ray from table-local `from`: over every mesh, over wood + cloth only, and over the cloth only.
func _hits(from: Vector3) -> Dictionary:
	var out := {all = -INF, cover = -INF, cloth = -INF}
	for m in _meshes:
		var inv: Transform3D = m.inv
		var r: Dictionary = (m.tm as TriangleMesh).intersect_ray(inv * from, inv.basis * Vector3.DOWN)
		if r.is_empty():
			continue
		var top := (inv.affine_inverse() * (r.position as Vector3)).y
		out.all = maxf(out.all, top)
		if m.name in [&"Cloth", &"Visual_wood"]:
			out.cover = maxf(out.cover, top)
		if m.name == &"Cloth":
			out.cloth = maxf(out.cloth, top)
	return out
