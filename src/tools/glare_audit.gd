extends SceneTree

## One-shot (adhoc-1014a V3): the data half of the glare hunt, on the real MainLevel (Solo). The glare is a phone-only artefact, so
## before any screenshot this audits what a GPU could mis-draw, from the meshes and cameras themselves:
##   cameras  every Camera3D's near / far / fov / projection (the depth buffer's precision is near-limited)
##   meshes   per surface: NaN or non-unit normals, normal-mapped surfaces without tangents, degenerate triangles, and triangles whose
##            winding disagrees with their vertex normals (flipped faces, a cull mismatch)
##   coplanar visible-from-the-same-side triangles of two different meshes that lie in one plane (within GAP_MAX) and overlap in it:
##            the z-fight candidates, bucketed by gap (a GPU's depth rounding decides which one wins per pixel)
## Needs a renderer (meshes keep no arrays headless): DISPLAY=:0 godot --path . -s src/tools/glare_audit.gd -- <out_dir>
## Prints a summary, writes the full list to <out_dir>/glare_audit.txt.

const GAP_MAX := 0.012                    ## metres: two planes closer than this are "near-coplanar"
const D_BUCKET := 0.001
const N_BUCKET := 0.02
const PARALLEL_MIN := 0.9995             ## two facets count as one plane only when their normals agree this well
const OVERLAP_MIN := 1e-4                 ## metres of in-plane overlap that counts (touching edges do not)
const TOP := 25

var _lines: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var out_dir := OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "/tmp"
	DirAccess.make_dir_recursive_absolute(out_dir)
	Settings.path = "user://glare_audit_settings.cfg"
	SaveManager.root = "user://glare_audit"
	DirAccess.make_dir_recursive_absolute(SaveManager.root)
	root.size = Vector2i(1280, 720)
	var lobby: Node = load("res://src/levels/Lobby.tscn").instantiate()
	root.add_child(lobby)
	await process_frame
	lobby.get_node("LobbyUI/Center/Menu/Solo").pressed.emit()
	await SoloSupport.until_playable(self)
	for i in 30:
		await process_frame
	var level := current_scene
	_cameras(level)
	var tris := _meshes(level)
	_coplanar(tris)
	_decals(level, tris)
	var f := FileAccess.open(out_dir.path_join("glare_audit.txt"), FileAccess.WRITE)
	f.store_string("\n".join(_lines))
	f.close()
	quit()


func _say(s: String) -> void:
	print(s)
	_lines.append(s)


func _cameras(level: Node) -> void:
	_say("=== cameras")
	for c: Camera3D in root.find_children("*", "Camera3D", true, false):
		_say("%-52s near %.3f far %.0f fov %.0f proj %d current %s" % [root.get_path_to(c), c.near, c.far, c.fov, c.projection, c.current])
	_say("viewport: msaa %d aa %d scale %.2f hdr2d %s" % [root.msaa_3d, root.screen_space_aa, root.scaling_3d_scale, root.use_hdr_2d])


## Audits every visible mesh surface; returns the world-space triangles for the coplanar pass.
func _meshes(level: Node) -> Array:
	_say("=== meshes (surface: verts tris | nan-n bad-len-n no-tangent-with-normalmap degenerate flipped)")
	var tris: Array = []  # [owner_id, owner_name, a, b, c] world space
	var totals := {nan = 0, badlen = 0, notan = 0, degen = 0, flipped = 0, surfaces = 0, tris = 0}
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var xf := mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var norms = arr[Mesh.ARRAY_NORMAL]
			var tans = arr[Mesh.ARRAY_TANGENT]
			var idx = arr[Mesh.ARRAY_INDEX]
			var mat := mi.get_active_material(s)
			var nmap := mat is BaseMaterial3D and (mat as BaseMaterial3D).normal_enabled
			var nan_n := 0
			var bad_len := 0
			if norms != null:
				for n: Vector3 in norms:
					if not n.is_finite():
						nan_n += 1
					elif absf(n.length() - 1.0) > 0.05:
						bad_len += 1
			var no_tan := nmap and tans == null
			var count: int = (idx.size() if idx != null else verts.size()) / 3
			var degen := 0
			var flipped := 0
			for t in count:
				var ia: int = idx[t * 3] if idx != null else t * 3
				var ib: int = idx[t * 3 + 1] if idx != null else t * 3 + 1
				var ic: int = idx[t * 3 + 2] if idx != null else t * 3 + 2
				var a := verts[ia]
				var b := verts[ib]
				var c := verts[ic]
				var cr := (b - a).cross(c - a)
				if cr.length() < 1e-9:
					degen += 1
					continue
				if norms != null and norms[ia].is_finite() and norms[ib].is_finite() and norms[ic].is_finite():
					var avg: Vector3 = norms[ia] + norms[ib] + norms[ic]
					if -cr.dot(avg) < 0.0:  # Godot's front face is clockwise: the geometric normal is -(b-a)x(c-a)
						flipped += 1
						if flipped <= 3:
							_say("      flipped e.g. at %s geo-n %s vertex-n %s" % [str(xf * ((a + b + c) / 3.0)), str((xf.basis * -cr).normalized().snapped(Vector3.ONE * 0.01)), str((xf.basis * avg).normalized().snapped(Vector3.ONE * 0.01))])
				tris.append([mi.get_instance_id(), "%s/s%d" % [mi.name, s], xf * a, xf * b, xf * c])
			totals.surfaces += 1
			totals.tris += count
			totals.nan += nan_n
			totals.badlen += bad_len
			totals.notan += 1 if no_tan else 0
			totals.degen += degen
			totals.flipped += flipped
			if nan_n > 0 or bad_len > 0 or no_tan or degen > 0 or flipped > 0:
				_say("  %-44s %6d %6d | %d %d %s %d %d  mat=%s" % [str(root.get_path_to(mi)) + ":" + str(s), verts.size(), count, nan_n, bad_len, "NOTAN" if no_tan else "-", degen, flipped, mat.resource_name if mat != null else "none"])
	_say("meshes total: %s" % str(totals))
	return tris


func _coplanar(tris: Array) -> void:
	_say("=== coplanar (same-plane triangles of different meshes, gap <= %.0f mm, overlapping)" % (GAP_MAX * 1000.0))
	var buckets := {}
	var info: Array = []  # per triangle: [nx, ny, nz, d, sign, axis]
	for i in tris.size():
		var t: Array = tris[i]
		var n: Vector3 = -((t[3] - t[2]).cross(t[4] - t[2])).normalized()  # the facing normal
		var sg := 1.0
		var cn := n
		var lead := 0
		for k in 3:
			if absf(n[k]) > 0.01:
				lead = k
				break
		if n[lead] < 0.0:
			sg = -1.0
			cn = -n
		var d := cn.dot(t[2])
		var key := Vector4i(roundi(cn.x / N_BUCKET), roundi(cn.y / N_BUCKET), roundi(cn.z / N_BUCKET), roundi(d / D_BUCKET))
		info.append([cn, d, sg])
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(i)
	var span := roundi(GAP_MAX / D_BUCKET)
	var pairs := {}   # "ownerA|ownerB" -> [count, min gap, same-facing count, example]
	var gap_hist := {c0 = 0, c1 = 0, c5 = 0, c12 = 0}
	var seen := {}
	for key: Vector4i in buckets:
		for dk in range(0, span + 1):
			var key2 := Vector4i(key.x, key.y, key.z, key.w + dk)
			if not buckets.has(key2):
				continue
			var la: Array = buckets[key]
			var lb: Array = buckets[key2]
			for ia: int in la:
				for ib: int in lb:
					if dk == 0 and ib <= ia:
						continue
					var ta: Array = tris[ia]
					var tb: Array = tris[ib]
					if ta[0] == tb[0]:
						continue
					var cn: Vector3 = info[ia][0]
					if cn.dot(info[ib][0] as Vector3) < PARALLEL_MIN:
						continue
					# the separation along the normal between a vertex of each: the planes' distances from the origin differ by
					# (normal error) x (distance from the origin) too, which at the table (3.5 m out) read a hidden 4 mm gap as 0.6 mm
					var gap := absf(cn.dot((ta[2] as Vector3) - (tb[2] as Vector3)))
					if gap > GAP_MAX:
						continue
					if not _overlap2d(ta, tb, cn):
						continue
					var same: bool = info[ia][2] == info[ib][2]
					var na: String = ta[1]
					var nb: String = tb[1]
					var pk := (na + " | " + nb) if na < nb else (nb + " | " + na)
					if not pairs.has(pk):
						pairs[pk] = [0, 1e9, 0, ta[2], cn * (info[ia][2] as float)]
					var p: Array = pairs[pk]
					p[0] += 1
					p[1] = minf(p[1], gap)
					if same:
						p[2] += 1
						if gap < 0.0001:
							gap_hist.c0 += 1
						elif gap < 0.001:
							gap_hist.c1 += 1
						elif gap < 0.005:
							gap_hist.c5 += 1
						else:
							gap_hist.c12 += 1
	_say("same-facing overlapping pairs by gap: <0.1mm %d | <1mm %d | <5mm %d | <=12mm %d" % [gap_hist.c0, gap_hist.c1, gap_hist.c5, gap_hist.c12])
	var keys := pairs.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return pairs[a][2] > pairs[b][2])
	_say("pair (mesh/surface | mesh/surface): overlapping tri pairs, same-facing, min gap mm, example world point")
	for k: String in keys.slice(0, TOP):
		var p: Array = pairs[k]
		_say("  %-60s %5d %5d  %.3f mm  at %s facing %s" % [k, p[0], p[2], p[1] * 1000.0, str(p[3].snapped(Vector3.ONE * 0.01)), str(p[4].snapped(Vector3.ONE * 0.1))])
	_say("(%d distinct mesh pairs, %d triangles scanned)" % [pairs.size(), tris.size()])


## Label3D / Sprite3D / Decal-like quads (not MeshInstance3D, so the pass above never sees them): any mesh triangle behind or in front of
## the quad's centre within GAP_MAX and facing the same way is the plane it z-fights with.
func _decals(level: Node, tris: Array) -> void:
	_say("=== decals (Label3D / Sprite3D centre vs a same-facing triangle within %.0f mm)" % (GAP_MAX * 1000.0))
	var n := 0
	for d: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		if not (d is Label3D or d is Sprite3D) or not d.is_visible_in_tree():
			continue
		var fn: Vector3 = d.global_basis.z.normalized()
		var c: Vector3 = d.global_transform * d.get_aabb().get_center()
		var worst := 1e9
		var hit := ""
		for t: Array in tris:
			var tn: Vector3 = -((t[3] - t[2]).cross(t[4] - t[2])).normalized()
			if tn.dot(fn) < 0.98:
				continue
			var gap: float = (c - t[2]).dot(tn)
			if absf(gap) > GAP_MAX or absf(gap) >= worst:
				continue
			var p := c - tn * gap
			if _in_tri(p, t[2], t[3], t[4]):
				worst = absf(gap)
				hit = t[1]
		if hit != "":
			n += 1
			_say("  %-50s %.1f mm from %s" % [root.get_path_to(d), worst * 1000.0, hit])
	_say("(%d decals within reach)" % n)


static func _in_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-12:
		return false
	var v := (d11 * d20 - d01 * d21) / den
	var w := (d00 * d21 - d01 * d20) / den
	return v >= 0.0 and w >= 0.0 and v + w <= 1.0


## Do triangles `a` and `b` (world, coplanar to within the gap) overlap in their shared plane by more than OVERLAP_MIN? SAT in 2D.
func _overlap2d(a: Array, b: Array, n: Vector3) -> bool:
	var ax := 0
	var m := absf(n.x)
	if absf(n.y) > m:
		ax = 1
		m = absf(n.y)
	if absf(n.z) > m:
		ax = 2
	var u := (ax + 1) % 3
	var v := (ax + 2) % 3
	var pa: Array[Vector2] = []
	var pb: Array[Vector2] = []
	for k in 3:
		pa.append(Vector2(a[2 + k][u], a[2 + k][v]))
		pb.append(Vector2(b[2 + k][u], b[2 + k][v]))
	for poly in [pa, pb]:
		for k in 3:
			var e: Vector2 = poly[(k + 1) % 3] - poly[k]
			var axis := Vector2(-e.y, e.x)
			var l := axis.length()
			if l < 1e-12:
				return false
			axis /= l
			var amin := 1e9
			var amax := -1e9
			var bmin := 1e9
			var bmax := -1e9
			for q in 3:
				var da := axis.dot(pa[q])
				var db := axis.dot(pb[q])
				amin = minf(amin, da)
				amax = maxf(amax, da)
				bmin = minf(bmin, db)
				bmax = maxf(bmax, db)
			if minf(amax, bmax) - maxf(amin, bmin) <= OVERLAP_MIN:
				return false
	return true
