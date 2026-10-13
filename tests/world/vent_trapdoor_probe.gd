extends SceneTree
## The staging fixtures (docs/plan/01 §3, 04 §4, 06 P33 D14/A10, adhoc-1013c W5), each built on its own, no MainLevel:
##  - MainLevel/Vent: over the table's east short rail, clear of the ceiling beams / lamp / camera pod, two draw calls, no collision object,
##    `open()` / `close()` tweened and `finished`, `mouth_transform()`, `is_open`; shut it covers the mouth, open it leaves it clear;
##  - MainLevel/Trapdoor: the hole's place against the room's own paths and props, panels that are floor (layer 8) only while shut,
##    `open()` / `close()` / `finished` / `pit()`, the shaft below; and, once the room is rebuilt, a hole in the floor collision that the panels fill;
##  - the table's lid: a player-layer slab over the bed and every pocket, so a player never stands in the playfield or a pocket, and a ball never
##    meets it.
##   godot --path . --headless -s tests/world/vent_trapdoor_probe.gd
## Prints VENT TRAPDOOR OK, or the failing checks and VENT TRAPDOOR FAIL (exit 1).

const TABLE_SCENE := preload("res://src/gameplay/table/Table.tscn")
const ROOM := preload("res://src/gameplay/bar_room/BarRoom.tscn")

var fails := 0
var finished := false
var _vent_done := 0
var _door_done := 0


func _init() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		if not finished:
			print("VENT TRAPDOOR FAIL (script error or hang)")
			quit(1))
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	return root.world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, mask))


func _run() -> void:
	var table: Table = TABLE_SCENE.instantiate()
	table.position = Vector3(0.0, 0.0, -3.5)  # where MainLevel puts it
	root.add_child(table)
	await process_frame
	await _vent(table)
	await _lid(table)
	var room: Node = ROOM.instantiate()
	root.add_child(room)
	await _trapdoor(room)
	finished = true
	if fails == 0:
		print("VENT TRAPDOOR OK")
		quit(0)
	else:
		print("VENT TRAPDOOR FAIL: %d checks" % fails)
		quit(1)


# ---------------------------------------------------------------- the vent

func _vent(table: Table) -> void:
	var vent := Vent.new()
	vent.table = table
	vent.finished.connect(func() -> void: _vent_done += 1)
	root.add_child(vent)
	await process_frame
	var rail_x := table.global_position.x + table.spec.length_m * 0.5
	_check(is_equal_approx(vent.global_position.x, rail_x) and is_equal_approx(vent.global_position.y, DecorPlan.CEIL) and is_equal_approx(vent.global_position.z, table.global_position.z), \
			"the vent hangs under the ceiling straight above the table's east short rail: %s" % vent.global_position)
	_check(vent.global_position.x > 0.0 and rail_x < 6.95, "...the end nearest the Blackboard (east wall x 6.95)")
	var lo := vent.global_position.x - Vent.SIZE.x * 0.5
	var hi := vent.global_position.x + Vent.SIZE.x * 0.5
	for beam_x in [-4.5, 0.0, 4.5]:
		_check(hi < beam_x - 0.125 or lo > beam_x + 0.125, "clear of the ceiling beam at x=%s (vent x %.2f..%.2f)" % [beam_x, lo, hi])
	_check(lo > 0.55 + 0.1, "clear of the table lamp's shade (radius 0.55 at x=0) and the ceiling camera's pod: x from %.2f" % lo)
	_check(vent.global_position.z - Vent.SIZE.y * 0.5 > -DecorPlan.HALF and vent.global_position.z + Vent.SIZE.y * 0.5 < DecorPlan.HALF, "...inside the room")
	var mouth := vent.mouth_transform()
	_check(mouth.origin.is_equal_approx(vent.global_position + Vector3(0.0, -Vent.DEPTH, 0.0)), "mouth_transform() origin is the centre of the opening: %s" % mouth.origin)
	_check((mouth.basis * Vector3.FORWARD).is_equal_approx(Vector3.DOWN) and (mouth.basis * Vector3.UP).is_equal_approx(Vector3.FORWARD), "...-Z straight out of the mouth (down), +Y to the north wall")
	var visuals := vent.find_children("*", "VisualInstance3D", true, false)
	_check(visuals.size() == 2, "two draw calls: the housing and the louvres (%d visual instances)" % visuals.size())
	_check(vent.find_children("*", "CollisionObject3D", true, false).is_empty() and vent.find_children("*", "CollisionShape3D", true, false).is_empty() \
			and vent.find_children("*", "Light3D", true, false).is_empty(), "no collision object and no light in the vent")
	_check(_widest_gap(vent.slat_z) < 0.001, "shut: the slats cover the mouth with no gap (widest gap %.4f m)" % _widest_gap(vent.slat_z))
	_check(not vent.is_open and is_zero_approx(vent.openness), "starts shut")
	_vent_done = 0
	var t0 := Time.get_ticks_msec()
	vent.open()
	_check(vent.is_open, "open() sets is_open at once")
	await _until(func() -> bool: return _vent_done == 1, "open()'s finished", 3.0)
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	_check(absf(took - Vent.OPEN_SEC) < 0.3 and is_equal_approx(vent.openness, 1.0) and vent.is_open, "open() ran %.2f s (%.2f) and ended fully open" % [took, Vent.OPEN_SEC])
	var clear := _widest_gap(vent.slat_z)
	_check(clear >= 1.1, "open: the middle %.2f m of the mouth is clear for the saucer" % clear)
	vent.close()
	_check(not vent.is_open, "close() clears is_open at once")
	await _until(func() -> bool: return _vent_done == 2, "close()'s finished", 3.0)
	_check(is_zero_approx(vent.openness) and not vent.is_open and _widest_gap(vent.slat_z) < 0.001, "close() ended shut")
	# interrupted: open() then close() at once is one `finished` (the close), never a stuck half-open vent
	_vent_done = 0
	vent.open()
	await create_timer(0.15).timeout
	vent.close()
	await _until(func() -> bool: return _vent_done >= 1, "the interrupting close()", 3.0)
	await create_timer(0.3).timeout
	_check(_vent_done == 1 and is_zero_approx(vent.openness) and not vent.is_open, "open() cut short by close(): one finished, shut (%d)" % _vent_done)
	vent.set_openness(0.5)
	_check(is_equal_approx(vent.openness, 0.5) and vent.is_open, "set_openness() seeks without a tween")
	vent.set_openness(0.0)
	vent.queue_free()


## The widest stretch of the mouth (metres along z) that no slat covers, from the multimesh placements: ~0 shut, the clear middle open.
func _widest_gap(slat_z: PackedFloat32Array) -> float:
	var half := (Vent.SIZE.y - 2.0 * Vent.WALL) * 0.5
	var blade := (Vent.SIZE.y - 2.0 * Vent.WALL) / float(Vent.SLATS) * 1.15
	var edges: Array[Vector2] = []
	for z in slat_z:
		edges.append(Vector2(z - blade * 0.5, z + blade * 0.5))
	edges.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var gap := 0.0
	var cover := -half
	for e in edges:
		gap = maxf(gap, e.x - cover)
		cover = maxf(cover, e.y)
	return maxf(gap, half - cover)


# ---------------------------------------------------------------- the lid on the table

func _lid(table: Table) -> void:
	await physics_frame
	await physics_frame
	var lid := table.get_node_or_null("Lid") as StaticBody3D
	_check(lid != null and lid.collision_layer == 8 and lid.collision_mask == 0, "the table has a Lid on the player layer (world, 4), mask 0")
	if lid == null:
		return
	var spec := table.spec
	var top := table.global_position.y + table.cloth_y() + spec.rail_height_m
	var points: Array[Vector3] = [table.to_global(Vector3(0.0, table.cloth_y(), 0.0))]
	for id in table.pockets:
		points.append(table.to_global(table.pockets[id].position))
	var x := -spec.length_m * 0.5
	while x <= spec.length_m * 0.5:
		var z := -spec.width_m * 0.5
		while z <= spec.width_m * 0.5:
			points.append(table.to_global(Vector3(x, table.cloth_y(), z)))
			z += 0.25
		x += 0.25
	var misses := 0
	for p in points:
		var hit := _ray(Vector3(p.x, top + 2.0, p.z), Vector3(p.x, -1.0, p.z), 8)
		if hit.is_empty() or hit.collider != lid or absf(hit.position.y - top) > 0.001:
			misses += 1
	_check(misses == 0, "a player-layer ray from above lands on the lid, at rail-top height %.3f, over the bed, all %d sample points and every pocket centre (%d missed)" % [top, points.size(), misses])
	var ball_hit := _ray(Vector3(0.0, top + 2.0, table.global_position.z), Vector3(0.0, -1.0, table.global_position.z), 7)
	_check(not ball_hit.is_empty() and ball_hit.collider != lid, "a ball-layer ray (mask 1|2|3) never meets the lid: it hits %s" % (ball_hit.collider.name if not ball_hit.is_empty() else "nothing"))
	# the Player's own capsule (r 0.3, h 1.75, layer 8, mask 2|8): standing on the lid is free, standing in the playfield is not
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.75
	q.shape = cap
	q.collision_mask = 10
	var centre := table.to_global(Vector3(0.0, table.cloth_y(), 0.0))
	q.transform = Transform3D(Basis.IDENTITY, Vector3(centre.x, top + 0.875 + 0.01, centre.z))
	_check(root.world_3d.direct_space_state.intersect_shape(q, 1).is_empty(), "a player standing on the lid is not inside anything")
	q.transform = Transform3D(Basis.IDENTITY, Vector3(centre.x, centre.y + spec.ball_radius_m + 0.875 + 0.01, centre.z))
	_check(not root.world_3d.direct_space_state.intersect_shape(q, 1).is_empty(), "a player in the playfield, on the cloth, would be blocked: the lid is in the way")
	var pocket := table.to_global(table.pockets[table.pockets.keys()[0]].position)
	q.transform = Transform3D(Basis.IDENTITY, Vector3(pocket.x, pocket.y - 0.4 + 0.875, pocket.z))
	_check(not root.world_3d.direct_space_state.intersect_shape(q, 1).is_empty(), "...and so would one sinking into a pocket")


# ---------------------------------------------------------------- the trapdoor

func _trapdoor(room: Node) -> void:
	var rect := Rect2(Trapdoor.HOLE_CENTER.x - Trapdoor.HOLE_SIZE.x * 0.5, Trapdoor.HOLE_CENTER.z - Trapdoor.HOLE_SIZE.y * 0.5, Trapdoor.HOLE_SIZE.x, Trapdoor.HOLE_SIZE.y)
	_check(is_equal_approx(Trapdoor.HOLE_CENTER.x, DecorPlan.TRAPDOOR_AT.x) and is_equal_approx(Trapdoor.HOLE_CENTER.z, DecorPlan.TRAPDOOR_AT.y) and Trapdoor.HOLE_SIZE == DecorPlan.TRAPDOOR_SIZE, "Trapdoor and the room builder read the same hole")
	_check(Rect2(-DecorPlan.HALF, -DecorPlan.HALF, 2.0 * DecorPlan.HALF, 2.0 * DecorPlan.HALF).encloses(rect), "the hole is inside the room: %s" % rect)
	var band := DecorPlan.floor_keep_clear()[0]
	_check(not rect.intersects(band), "clear of the table and its 1.6 m walking band %s" % band)
	var grown := rect.grow(0.4)
	var in_the_way: Array[String] = []
	for prop: Array in Bar.PROPS:
		if grown.has_point(Vector2(prop[1].x, prop[1].z)):
			in_the_way.append(String(prop[0]))
	for seat: Array in Bar.SEATS:
		if grown.has_point(Vector2(seat[1].x, seat[1].z)):
			in_the_way.append(String(seat[0]))
	for s in 4:  # the spawn row: seat 0.. of the crew
		var at: Vector3 = PlayerSpawner.SPAWN_ROW + Vector3(PlayerSpawner.SEAT_SPACING * s, 0.0, 0.0)
		if grown.has_point(Vector2(at.x, at.z)):
			in_the_way.append("spawn seat %d" % s)
	_check(in_the_way.is_empty(), "no prop, seat or spawn within 0.4 m of the hole: %s" % [in_the_way])

	var door := Trapdoor.new()
	door.finished.connect(func() -> void: _door_done += 1)
	root.add_child(door)
	await physics_frame
	await physics_frame
	var panels := door.find_children("Panel", "StaticBody3D", true, false)
	_check(panels.size() == 2, "two floor panels")
	var solid := true
	for p: StaticBody3D in panels:
		solid = solid and p.collision_layer == 8 and p.collision_mask == 0
	_check(solid and not door.is_open, "shut: the panels are world-layer floor")
	_check(door.pit() != null and door.pit().is_inside_tree() and is_equal_approx(door.pit().global_position.y, -Trapdoor.SHAFT_DEPTH) \
			and door.pit().global_position.is_equal_approx(Vector3(Trapdoor.HOLE_CENTER.x, -Trapdoor.SHAFT_DEPTH, Trapdoor.HOLE_CENTER.z)), "pit() is the anchor at the shaft's bottom: %s" % door.pit().global_position)
	_check(is_equal_approx(float(door.pit().get_meta(&"width", 0.0)), 3.0), "...about 3 m wide")
	var visuals := door.find_children("*", "MeshInstance3D", true, false)
	var floor_mat := load(Trapdoor.FLOOR_MATERIAL)
	var panel_meshes := 0
	for v: MeshInstance3D in visuals:
		if v.name == &"Floor":
			panel_meshes += 1
			_check(v.material_override == floor_mat, "a panel wears the room's floor material")
	_check(panel_meshes == 2, "two panel meshes (%d)" % panel_meshes)
	# is the room's collision cut at the hole? (it is once build_bar_room.gd has been re-run: without the hole, only the panels' own part of the test holds)
	var centre := Vector3(Trapdoor.HOLE_CENTER.x, 1.0, Trapdoor.HOLE_CENTER.z)
	var down := Vector3(centre.x, -6.0, centre.z)
	var shut_hit := _ray(centre, down, 8)
	_check(not shut_hit.is_empty() and shut_hit.position.y > -0.01, "shut: a player-layer ray lands on the floor at the hole (y %.3f)" % (shut_hit.position.y if not shut_hit.is_empty() else -9.0))
	var cut := not shut_hit.is_empty() and (shut_hit.collider as Node).name == &"Panel"
	if not cut:
		print("NOTE: the baked room's floor collision has no hole yet (build_bar_room.gd has not been re-run); the panels cannot be told from the floor")
	door.open()
	_check(door.is_open, "open() sets is_open at once")
	var off := true
	for p: StaticBody3D in panels:
		off = off and p.collision_layer == 0
	_check(off, "...and the panels are not floor any more")
	await _until(func() -> bool: return _door_done == 1, "open()'s finished", 4.0)
	_check(is_equal_approx(door.openness, 1.0) and absf(door.get_node("Hinge_W").rotation.z + deg_to_rad(Trapdoor.OPEN_DEG)) < 0.01 and absf(door.get_node("Hinge_E").rotation.z - deg_to_rad(Trapdoor.OPEN_DEG)) < 0.01, "open: the leaves hang down from their hinges")
	var open_hit := _ray(centre, down, 8)
	if cut:
		_check(not open_hit.is_empty() and open_hit.position.y < -Trapdoor.SHAFT_DEPTH + 0.05 and open_hit.position.y > -Trapdoor.SHAFT_DEPTH - 0.4, "open: whoever falls in lands at the shaft's floor (y %.2f)" % (open_hit.position.y if not open_hit.is_empty() else -9.0))
	else:
		_check(not open_hit.is_empty(), "open: the ray still lands somewhere")
	_check(door.find_children("*", "Light3D", true, false).is_empty(), "no light in the trapdoor")
	var leaf_hit := _ray(Vector3(centre.x - 1.4, 1.0, centre.z), Vector3(centre.x - 1.4, -0.05, centre.z), 8)
	_check(leaf_hit.is_empty() or (leaf_hit.collider as Node).name != &"Panel", "open: a leaf hanging at the hole's edge is not floor")
	door.close()
	_check(not door.is_open, "close() clears is_open at once")
	await _until(func() -> bool: return _door_done == 2, "close()'s finished", 4.0)
	var back := true
	for p: StaticBody3D in panels:
		back = back and p.collision_layer == 8
	_check(back and is_zero_approx(door.openness), "shut again: the panels are floor again")
	door.queue_free()
	room.queue_free()


func _until(cond: Callable, what: String, sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t0 > sec * 1000.0:
			_check(false, "timeout waiting for " + what)
			return
