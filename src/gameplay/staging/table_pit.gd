class_name TablePit
extends Node3D
## The clean-up picture (06 P33 U15): the table's bed splits into FLAPS hinged flaps that drop open from the middle outward, the balls fall into
## a dark pit inside the table body and vanish, the flaps close again. Presentation only, on every peer from the frozen ball positions: no
## physics, no collision object (the table's real Bed collider is untouched and the balls are not moved). `begin` hides the real cloth and
## balls and puts stand-ins in their place; `pose(t)` draws the clean-up at time `t` (a pure function of `StagingPlan`); `end` puts the cloth back.
##
## Why flaps and not two halves: under the bed there is only the apron's 0.34 m, and a half is 1.27 m wide, so a half hinged at the rail could
## open no further than 15 degrees. A flap is a 0.32 m strip hinged on one edge (the outer ones on the rail side, so the gap grows from the middle).

const SKIN := 0.02  ## the pit's walls stand this far inside the apron's inner face (no coplanar faces to fight)

var table: Table

var _holder: Node3D                # the table's frame: flaps, pit and ghosts are placed table-local
var _cloth: MeshInstance3D
var _flaps: Array[Node3D] = []     # hinge pivots, index = flap k; rotation.x = sgn(k) * angle
var _pit: MeshInstance3D
var _ghosts: Array[Dictionary] = []
var _src: Mesh                     # the cloth mesh the cached flap meshes were cut from
var _flap_meshes: Array[ArrayMesh] = []
var _z0 := 0.0
var _pitch := 0.0
var _bed_y := 0.0
var _depth := 0.0


## Builds the picture for `balls` (hides them and the cloth) and poses it at t = 0.
func begin(p_table: Table, balls: Array[Ball]) -> void:
	end()
	table = p_table
	_bed_y = table.cloth_y()
	_depth = table.spec.apron_h_m - 0.02
	_holder = Node3D.new()
	_holder.name = "Frame"
	add_child(_holder)
	_holder.global_transform = table.global_transform
	_cloth = table.get_node_or_null(^"Cloth") as MeshInstance3D
	if _cloth != null and _cloth.mesh is ArrayMesh:
		_build_flaps()
		_cloth.visible = false
	_build_pit()
	_build_ghosts(balls)
	pose(0.0)


## Puts the real cloth back and frees every stand-in. The real balls stay hidden: RoundDirector clears them.
func end() -> void:
	if is_instance_valid(_cloth):
		_cloth.visible = true
	_cloth = null
	_flaps.clear()
	_ghosts.clear()
	if _holder != null:
		_holder.queue_free()
		remove_child(_holder)
		_holder = null
	_pit = null


func is_active() -> bool:
	return _holder != null


## Poses the clean-up at `t` seconds: flap angles, the ghosts riding then falling, the pit shown while anything is open.
func pose(t: float) -> void:
	if _holder == null:
		return
	var open_any := false
	for k in _flaps.size():
		var a := StagingPlan.flap_angle(k, t)
		_flaps[k].rotation.x = _sgn(k) * a
		open_any = open_any or a > 0.001
	if _pit != null:
		_pit.visible = open_any
	for g in _ghosts:
		_pose_ghost(g, t)


## The ghost balls' table-local positions right now (probes).
func ghost_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for g in _ghosts:
		out.append((g.node as MeshInstance3D).position)
	return out


func ghost_count() -> int:
	return _ghosts.size()


func flap_count() -> int:
	return _flaps.size()


func pit_depth() -> float:
	return _depth


# ---------------------------------------------------------------- build

func _sgn(k: int) -> float:
	return 1.0 if k < StagingPlan.RANKS else -1.0


## The flap's hinge line (table-local z): the rail-side edge, so the free edges meet in the middle.
func _hinge_z(k: int) -> float:
	return _z0 + _pitch * float(k if k < StagingPlan.RANKS else k + 1)


func _build_flaps() -> void:
	var src := _cloth.mesh as ArrayMesh
	var box := src.get_aabb()
	_z0 = box.position.z
	_pitch = box.size.z / float(StagingPlan.FLAPS)
	if src != _src:
		_src = src
		_flap_meshes.clear()
		for k in StagingPlan.FLAPS:
			_flap_meshes.append(slice(src, _z0 + _pitch * float(k), _z0 + _pitch * float(k + 1), Vector3(0.0, _bed_y, _hinge_z(k))))
	for k in StagingPlan.FLAPS:
		var pivot := Node3D.new()
		pivot.name = "Flap%d" % k
		pivot.position = Vector3(0.0, _bed_y, _hinge_z(k))
		_holder.add_child(pivot)
		var mi := MeshInstance3D.new()
		mi.mesh = _flap_meshes[k]
		mi.material_override = _cloth.material_override  # the felt, the skin's colour included
		mi.layers = 1 | Mirror.LAYER                      # the mirror's window pass draws the table, so it draws the flaps
		mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		pivot.add_child(mi)
		_flaps.append(pivot)


func _build_pit() -> void:
	var spec := table.spec
	_pit = MeshInstance3D.new()
	_pit.name = "Pit"
	_pit.mesh = StagingTray.mesh(Vector2(spec.length_m - 2.0 * SKIN, spec.width_m - 2.0 * SKIN), _depth)
	_pit.material_override = StagingTray.material(_depth)
	_pit.position = Vector3(0.0, _bed_y, 0.0)
	_pit.layers = 1 | Mirror.LAYER
	_pit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pit.visible = false
	_holder.add_child(_pit)


func _build_ghosts(balls: Array[Ball]) -> void:
	for b in balls:
		if b.retired or b.is_pocketed:
			continue
		var local := table.to_local(b.global_position)
		var k := clampi(floori((local.z - _z0) / maxf(_pitch, 0.001)), 0, StagingPlan.FLAPS - 1) if not _flaps.is_empty() else 0
		var sgn := _sgn(k)
		var hz := _hinge_z(k) if not _flaps.is_empty() else local.z
		var node := MeshInstance3D.new()
		node.name = "Ghost%d" % b.net_id
		node.mesh = (b.get_node(^"Mesh") as MeshInstance3D).mesh
		_holder.add_child(node)
		b.visible = false
		_ghosts.append({
			node = node, k = k, sgn = sgn, hz = hz,
			s = clampf((local.z - hz) * sgn, 0.0, _pitch),
			x = local.x, lift = local.y - _bed_y, net_id = b.net_id,
		})


## The ball on its flap at time `t` (before it lets go): carried round with the flap, table-local.
func _riding(g: Dictionary, t: float) -> Vector3:
	var a := StagingPlan.flap_angle(g.k, t)
	var sgn: float = g.sgn
	var s: float = g.s
	return Vector3(g.x, _bed_y, g.hz) + Vector3(0.0, -sin(a) * s, sgn * cos(a) * s) + Vector3(0.0, cos(a), sgn * sin(a)) * float(g.lift)


func _pose_ghost(g: Dictionary, t: float) -> void:
	var node: MeshInstance3D = g.node
	var rel := StagingPlan.release_time(g.k, g.net_id)
	if t < rel:
		node.position = _riding(g, t)
		node.transparency = 0.0
		node.visible = true
		return
	var from := _riding(g, rel)
	var floor_y := _bed_y - _depth + float(g.lift)
	var dt := t - rel
	var y := maxf(from.y - 0.5 * StagingPlan.FALL_G * dt * dt, floor_y)
	var fell := clampf((from.y - y) / maxf(from.y - floor_y, 0.001), 0.0, 1.0)  # 0 at the flap, 1 on the pit floor
	node.position = Vector3(from.x, y, from.z)
	node.transparency = smoothstep(0.45, 1.0, fell)  # it sinks into the dark
	node.visible = fell < 1.0


# ---------------------------------------------------------------- cutting the cloth

## `src`'s first surface restricted to table-local z in [za, zb], vertices moved by -`pivot`. Positions, normals, tangents and UVs are
## interpolated at the cuts, so the felt's nap and lighting carry over unchanged. Triangle winding is kept.
static func slice(src: ArrayMesh, za: float, zb: float, pivot: Vector3) -> ArrayMesh:
	var arrays := src.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
	var has_tangents := tangents.size() >= v.size() * 4
	var order := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		order = arrays[Mesh.ARRAY_INDEX]
	else:
		order.resize(v.size())
		for i in v.size():
			order[i] = i
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0, order.size() - 2, 3):
		var poly: Array = []
		for j in 3:
			var vi := order[i + j]
			var t4 := Vector4(tangents[vi * 4], tangents[vi * 4 + 1], tangents[vi * 4 + 2], tangents[vi * 4 + 3]) if has_tangents else Vector4(1.0, 0.0, 0.0, 1.0)
			poly.append([v[vi], nrm[vi], t4, uv[vi]])
		poly = _clip_z(poly, za, true)
		poly = _clip_z(poly, zb, false)
		for j in range(1, poly.size() - 1):
			for q: Array in [poly[0], poly[j], poly[j + 1]]:
				var tq: Vector4 = q[2]
				st.set_normal(q[1])
				st.set_tangent(Plane(Vector3(tq.x, tq.y, tq.z), tq.w))
				st.set_uv(q[3])
				st.add_vertex((q[0] as Vector3) - pivot)
	return st.commit()


## Sutherland-Hodgman against the plane z = `z`: keeps the side where z is `keep_greater` (>=) or not.
static func _clip_z(poly: Array, z: float, keep_greater: bool) -> Array:
	var out: Array = []
	var sign_k := 1.0 if keep_greater else -1.0
	var n := poly.size()
	for i in n:
		var a: Array = poly[i]
		var b: Array = poly[(i + 1) % n]
		var da: float = ((a[0] as Vector3).z - z) * sign_k
		var db: float = ((b[0] as Vector3).z - z) * sign_k
		if da >= 0.0:
			out.append(a)
		if (da >= 0.0) != (db >= 0.0):
			var w := da / (da - db)
			out.append([(a[0] as Vector3).lerp(b[0], w), ((a[1] as Vector3).lerp(b[1], w)).normalized(), (a[2] as Vector4).lerp(b[2], w), (a[3] as Vector2).lerp(b[3], w)])
	return out
