extends SceneTree
## CutsceneKit.Soup builds from packed arrays (adhoc-1014b C8): the SAME arrays as the SurfaceTool builder it replaced, on a fixed input and on
## a seeded random one (boxes, frustums, cones, ellipsoids, loose triangles and quads, rotated and translated, slivers), and at least
## MIN_SPEEDUP times faster on a cabin-sized workload. The old builder is kept below as the oracle.
##   godot --path . --headless -s tests/cutscene/soup_probe.gd     prints SOUP OK
## Speed, on what the scenes build (the solids' own work, before the engine's `add_surface_from_arrays`, which both builders end in): a box is
## ~4.4x, a capped log ~3.5x, a small cyl (a tree's trunk or cone: 10 triangles, so the call's fixed cost shows) ~2x, the cabin's whole mix ~2.4x.

const MIN_SPEEDUP_MIX := 2.0
const MIN_SPEEDUP_BOXES := 3.5
const MIN_SPEEDUP_LOGS := 3.0
const RUNS := 5  ## the best of these is compared, so a busy machine does not fail it

var fails := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		printerr("FAIL: ", what)


func _run() -> void:
	_same("an empty soup", func(_s: Variant) -> void: pass)
	_same("one box", func(s: Variant) -> void: s.box(Vector3(0.3, 0.2, -0.1), Vector3(0.5, 0.25, 0.4), Color("3a3a3e")))
	_same("a box with a transform", func(s: Variant) -> void:
		s.xf = Transform3D(Basis.from_euler(Vector3(0.3, 1.1, -0.7)), Vector3(2.0, -1.0, 0.5))
		s.box(Vector3(0.3, 0.2, -0.1), Vector3(0.5, 0.25, 0.4), Color.RED))
	_same("a frustum with both caps, a cone, a tube", func(s: Variant) -> void:
		s.cyl(Vector3(0.0, 0.0, 0.0), 1.0, Vector2(0.3, 0.2), Vector2(0.1, 0.12), 9, Color.GREEN)
		s.cyl(Vector3(1.0, 0.0, 0.0), 2.0, Vector2(0.5, 0.5), Vector2(0.0, 0.0), 6, Color.BLUE)
		s.cyl(Vector3(2.0, 0.0, 0.0), 0.5, Vector2(0.2, 0.2), Vector2(0.2, 0.2), 12, Color.WHITE, 0))
	_same("an ellipsoid", func(s: Variant) -> void:
		s.xf = Transform3D(Basis.from_euler(Vector3(-0.4, 0.2, 0.9)), Vector3(0.1, 0.2, 0.3))
		s.ball(Vector3(0.0, 0.5, 0.0), Vector3(0.9, 0.4, 0.6), 10, 7, Color.YELLOW))
	_same("loose triangles and a quad, either winding, and a sliver", func(s: Variant) -> void:
		s.tri(Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3.BACK, Color.RED)
		s.tri(Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3.BACK, Color.RED)
		s.tri(Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0), Vector3.UP, Color.RED)
		s.quad(Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0), Vector3.FORWARD, Color.CYAN)
		s.box(Vector3.ZERO, Vector3(0.0, 0.5, 0.5), Color.WHITE))  # a flat box: four sides are slivers
	for seed_value in range(1, 13):
		_same("seeded random solids (%d)" % seed_value, func(s: Variant) -> void: _random_solids(s, seed_value, 150))
	_speed("the cabin's mix (trees, logs, boxes, a hood)", _scene_like, MIN_SPEEDUP_MIX)
	_speed("boxes", func(s: Variant) -> void: _boxes(s), MIN_SPEEDUP_BOXES)
	_speed("capped logs on a turn", func(s: Variant) -> void: _logs(s), MIN_SPEEDUP_LOGS)
	if fails == 0:
		print("SOUP OK")
	else:
		printerr("SOUP FAILED: %d" % fails)
	quit(1 if fails > 0 else 0)


## The same drawing instructions into both builders; the surfaces must be equal array for array.
func _same(what: String, draw: Callable) -> void:
	var o := OldSoup.new()
	var n := CutsceneKit.Soup.new()
	draw.call(o)
	draw.call(n)
	var mo := o.mesh()
	var mn := n.mesh()
	_check(o.triangles() == n.triangles(), "%s: the same triangle count (%d vs %d)" % [what, o.triangles(), n.triangles()])
	_check(mo.get_surface_count() == mn.get_surface_count(), "%s: the same surface count" % what)
	if mo.get_surface_count() == 0 or mn.get_surface_count() == 0:
		return
	var ao := mo.surface_get_arrays(0)
	var an := mn.surface_get_arrays(0)
	for k in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR]:
		_check(ao[k] == an[k], "%s: array %d is identical (%d vs %d entries)" % [what, k, (ao[k] as Array).size() if ao[k] is Array else ao[k].size(), an[k].size()])
	_check(mo.surface_get_primitive_type(0) == mn.surface_get_primitive_type(0) and ao[Mesh.ARRAY_INDEX] == an[Mesh.ARRAY_INDEX], "%s: same primitive and index" % what)
	_check(mn.surface_get_material(0) == CutsceneKit.vertex_material(), "%s: the shared vertex-colour material" % what)


## `work` into the old and the new builder `RUNS` times; the best time of each, and what `mesh()` adds to both.
func _speed(what: String, work: Callable, minimum: float) -> void:
	var best_old := 1e18
	var best_new := 1e18
	var best_old_all := 1e18
	var best_new_all := 1e18
	for r in RUNS:
		var t0 := Time.get_ticks_usec()
		var o := OldSoup.new()
		work.call(o)
		var t1 := Time.get_ticks_usec()
		o.mesh()
		best_old = minf(best_old, float(t1 - t0))
		best_old_all = minf(best_old_all, float(Time.get_ticks_usec() - t0))
		t0 = Time.get_ticks_usec()
		var n := CutsceneKit.Soup.new()
		work.call(n)
		t1 = Time.get_ticks_usec()
		n.mesh()
		best_new = minf(best_new, float(t1 - t0))
		best_new_all = minf(best_new_all, float(Time.get_ticks_usec() - t0))
	var speedup := best_old / maxf(best_new, 1.0)
	print("SOUP %s: solids old %.1f ms, new %.1f ms, x%.2f | with mesh(): x%.2f" % [what, best_old * 0.001, best_new * 0.001, speedup, best_old_all / maxf(best_new_all, 1.0)])
	_check(speedup >= minimum, "%s: the packed-array soup builds its solids at least %.1fx faster (x%.2f)" % [what, minimum, speedup])


func _boxes(s: Variant) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	for i in 300:
		s.xf = Transform3D(Basis.from_euler(Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0), 0.0)), Vector3(0.0, 1.0, 2.0)) if i % 2 == 0 else Transform3D.IDENTITY
		s.box(Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.0, 3.0), rng.randf_range(-3.0, 3.0)), Vector3(rng.randf_range(0.05, 1.5), rng.randf_range(0.02, 0.5), rng.randf_range(0.05, 1.5)), Color("3a3a3e"))


func _logs(s: Variant) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	for i in 100:
		s.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(rng.randf_range(-3.0, 3.0), 0.17 + 0.33 * (i % 9), rng.randf_range(-3.0, 3.0)))
		s.cyl(Vector3.ZERO, 7.0, Vector2(0.17, 0.17), Vector2(0.17, 0.17), 8, Color("5c3d24"))
	s.xf = Transform3D.IDENTITY


func _scene_like(s: Variant) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 170:
		var at := Vector3(rng.randf_range(-50.0, 50.0), 0.0, rng.randf_range(-64.0, 18.0))
		var k := rng.randf_range(0.8, 1.7)
		s.cyl(at, 1.6 * k, Vector2(0.2 * k, 0.2 * k), Vector2(0.14 * k, 0.14 * k), 5, Color("2a1d14"), 0)
		for j in 3:
			var w := (1.9 - 0.45 * j) * k
			s.cyl(at + Vector3(0.0, (1.0 + 1.15 * j) * k, 0.0), 1.9 * k, Vector2(w, w), Vector2.ZERO, 6, Color(0.05, 0.2, 0.09), 0)
	for i in 60:
		s.xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(rng.randf_range(-3.0, 3.0), 0.17 + 0.33 * (i % 9), rng.randf_range(-3.0, 3.0)))
		s.cyl(Vector3.ZERO, 7.0, Vector2(0.17, 0.17), Vector2(0.17, 0.17), 8, Color("5c3d24"))
		s.xf = Transform3D.IDENTITY
	for i in 80:
		s.box(Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.0, 3.0), rng.randf_range(-3.0, 3.0)), Vector3(rng.randf_range(0.05, 1.5), rng.randf_range(0.02, 0.5), rng.randf_range(0.05, 1.5)), Color("3a3a3e"))
	for i in 4:
		s.ball(Vector3(0.0, 0.135, 0.0), Vector3(0.13, 0.15, 0.14), 10, 7, Color("8c6d45"))


func _random_solids(s: Variant, seed_value: int, count: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in count:
		s.xf = Transform3D(Basis.from_euler(Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0))), Vector3(rng.randf_range(-20.0, 20.0), rng.randf_range(-3.0, 3.0), rng.randf_range(-20.0, 20.0)))
		var col := Color(rng.randf(), rng.randf(), rng.randf())
		var at := Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(0.0, 3.0), rng.randf_range(-2.0, 2.0))
		match rng.randi() % 7:
			0, 1:
				s.box(at, Vector3(rng.randf_range(0.003, 1.5), rng.randf_range(0.003, 1.5), rng.randf_range(0.003, 1.5)), col)
			2:  # any frustum, however lopsided: the general path
				s.cyl(at, rng.randf_range(0.1, 4.0), Vector2(rng.randf_range(0.05, 1.0), rng.randf_range(0.05, 1.0)), Vector2(rng.randf_range(0.0, 1.0), rng.randf_range(0.0, 1.0)), 3 + rng.randi() % 10, col, rng.randi() % 4)
			5, 6:  # what the scenes build: nearly round, a cone or a taper, thin and fat, short and tall: the fast path, and its edges
				var r := rng.randf_range(0.01, 1.2)
				var r0 := Vector2(r, r * rng.randf_range(0.75, 1.3))
				var r1 := Vector2.ZERO if rng.randi() % 3 == 0 else Vector2(r0.x * rng.randf_range(0.05, 1.2), r0.y * rng.randf_range(0.05, 1.2))
				s.cyl(at, rng.randf_range(0.01, 4.0), r0, r1, 3 + rng.randi() % 12, col, rng.randi() % 4)
			3:
				s.ball(at, Vector3(rng.randf_range(0.1, 1.0), rng.randf_range(0.1, 1.0), rng.randf_range(0.1, 1.0)), 4 + rng.randi() % 8, 3 + rng.randi() % 6, col)
			_:
				s.quad(at, at + Vector3(1, 0, 0) * rng.randf_range(0.1, 2.0), at + Vector3(1, 1, 0), at + Vector3(0, 1, 0), Vector3(rng.randf_range(-1.0, 1.0), 1.0, rng.randf_range(-1.0, 1.0)).normalized(), col)


# --- the oracle: the SurfaceTool builder this probe replaced, verbatim ---------------------------------------------------------------
class OldSoup extends RefCounted:
	const CAP_BOTTOM := 1
	const CAP_TOP := 2
	const BOX_FACES := [[0, 2, 6, 4], [1, 3, 7, 5], [0, 1, 5, 4], [2, 3, 7, 6], [0, 1, 3, 2], [4, 5, 7, 6]]
	const BOX_NORMALS: Array[Vector3] = [Vector3.LEFT, Vector3.RIGHT, Vector3.DOWN, Vector3.UP, Vector3.FORWARD, Vector3.BACK]

	var xf := Transform3D.IDENTITY
	var _st := SurfaceTool.new()
	var _tris := 0

	func _init() -> void:
		_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	func triangles() -> int:
		return _tris

	## One triangle with outward normal `n`, wound the way Godot front-faces it (clockwise seen from outside) whatever the order given.
	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
		var pa := xf * a
		var pb := xf * b
		var pc := xf * c
		var nn := (xf.basis * n).normalized()
		var cross := (pb - pa).cross(pc - pa)
		if cross.length_squared() < 0.0000001:
			return
		var v1 := pb
		var v2 := pc
		if cross.dot(nn) > 0.0:
			v1 = pc
			v2 = pb
		for p: Vector3 in [pa, v1, v2]:
			_st.set_color(col)
			_st.set_normal(nn)
			_st.add_vertex(p)
		_tris += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
		tri(a, b, c, n, col)
		tri(a, c, d, n, col)

	func box(centre: Vector3, half: Vector3, col: Color) -> void:
		var c: Array[Vector3] = []
		for n in 8:
			c.append(centre + Vector3(half.x if n & 1 else -half.x, half.y if n & 2 else -half.y, half.z if n & 4 else -half.z))
		for f in 6:
			var idx: Array = BOX_FACES[f]
			quad(c[idx[0]], c[idx[1]], c[idx[2]], c[idx[3]], BOX_NORMALS[f], col)

	## Vertical frustum from `base` up by `h`; elliptical radii (x, z) at the bottom and the top; r1 = 0 is a cone.
	func cyl(base: Vector3, h: float, r0: Vector2, r1: Vector2, sides: int, col: Color, caps := CAP_BOTTOM | CAP_TOP) -> void:
		var top := base + Vector3(0.0, h, 0.0)
		var slope := Vector3.UP * ((r0.x + r0.y - r1.x - r1.y) * 0.5)
		for n in sides:
			var a0 := TAU * n / sides
			var a1 := TAU * (n + 1) / sides
			var d0 := Vector3(cos(a0), 0.0, sin(a0))
			var d1 := Vector3(cos(a1), 0.0, sin(a1))
			var b0 := base + Vector3(d0.x * r0.x, 0.0, d0.z * r0.y)
			var b1 := base + Vector3(d1.x * r0.x, 0.0, d1.z * r0.y)
			var t0 := top + Vector3(d0.x * r1.x, 0.0, d0.z * r1.y)
			var t1 := top + Vector3(d1.x * r1.x, 0.0, d1.z * r1.y)
			var mid := (d0 + d1).normalized()
			var nm := (Vector3(mid.x * r0.y, 0.0, mid.z * r0.x).normalized() * maxf(h, 0.001) + slope).normalized()
			tri(b0, b1, t1, nm, col)
			tri(b0, t1, t0, nm, col)
			if caps & CAP_BOTTOM:
				tri(base, b1, b0, Vector3.DOWN, col)
			if caps & CAP_TOP and r1.x > 0.0:
				tri(top, t0, t1, Vector3.UP, col)

	## Ellipsoid, smooth normals.
	func ball(centre: Vector3, radii: Vector3, seg: int, rings: int, col: Color) -> void:
		var grid: Array = []
		for r in rings + 1:
			var row: Array[Vector3] = []
			var phi := PI * r / rings
			for s in seg:
				var th := TAU * s / seg
				row.append(Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th)))
			grid.append(row)
		for r in rings:
			for s in seg:
				var s2 := (s + 1) % seg
				var q: Array[Vector3] = [grid[r][s], grid[r][s2], grid[r + 1][s2], grid[r + 1][s]]
				var p: Array[Vector3] = []
				for v in q:
					p.append(centre + v * radii)
				var nrm: Array[Vector3] = []
				for v in q:
					nrm.append((v / radii).normalized())
				if r > 0:
					_smooth_tri(p[0], p[1], p[2], nrm[0], nrm[1], nrm[2], col)
				if r < rings - 1:
					_smooth_tri(p[0], p[2], p[3], nrm[0], nrm[2], nrm[3], col)

	func _smooth_tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, col: Color) -> void:
		var pa := xf * a
		var pb := xf * b
		var pc := xf * c
		var cross := (pb - pa).cross(pc - pa)
		if cross.length_squared() < 0.0000001:
			return
		var sum := xf.basis * (na + nb + nc)
		var order: Array[int] = [0, 1, 2]
		if cross.dot(sum) > 0.0:
			order = [0, 2, 1]
		var pts: Array[Vector3] = [pa, pb, pc]
		var nrm: Array[Vector3] = [(xf.basis * na).normalized(), (xf.basis * nb).normalized(), (xf.basis * nc).normalized()]
		for k in order:
			_st.set_color(col)
			_st.set_normal(nrm[k])
			_st.add_vertex(pts[k])
		_tris += 1

	## The merged mesh (null material = the shared vertex-colour one).
	func mesh(material: Material = null) -> ArrayMesh:
		var m := _st.commit()
		if m.get_surface_count() > 0:
			m.surface_set_material(0, material if material != null else CutsceneKit.vertex_material())
		return m
