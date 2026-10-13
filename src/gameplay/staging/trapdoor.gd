class_name Trapdoor
extends Node3D
## MainLevel/Trapdoor (06 P33 A10): the hole in the bar's floor the failure cutscene drops the crew through (the monster's mouth sits in the
## `Pit` at the bottom). The baked floor has a rectangular hole here (build_bar_room.gd cuts it from the same constants, floor mesh and collision
## alike); this node covers it with two dynamic floor panels in the floor material and owns a dark shaft below.
##
## WHERE: HOLE_CENTER = (0, 0, 3.8), 3 x 3 m: the open floor in the middle of the room's south half, clear of the table and its 1.6 m band (z
## < -1.4), the spawn row (z 1.2) and the paths to GO LIVE, the Blackboard, the counter and its stools (x > 3.9), the jukebox, the round
## tables (x < -1.8) and the TV wall's shelves (z > 6.2). DecorPlan.floor_keep_clear() keeps decor out of it.
##
## Closed = floor: the panels are `world`-layer (8) bodies a player walks on. While open (and while moving) the panels have no collision, the shaft
## walls and floor do (layer 8), so whoever falls in lands on the Pit. Nothing here is on a ball layer.
## API (frozen, F3b codes against it): `open()`, `close()` (tweened, emit `finished`), `pit() -> Node3D`, `is_open`.

signal finished

const HOLE_CENTER := Vector3(DecorPlan.TRAPDOOR_AT.x, 0.0, DecorPlan.TRAPDOOR_AT.y)
const HOLE_SIZE := DecorPlan.TRAPDOOR_SIZE   ## x, z
const SHAFT_DEPTH := 4.0
const THICK := 0.1                     ## the floor slab's thickness (build_bar_room.gd: y -0.1 .. 0)
const LAP_OUT := 0.02                  ## a leaf runs this far under the slab at its hinge ...
const LAP_IN := 0.01                   ## ... and this far past the hole's middle
const OPEN_DEG := 92.0
const OPEN_SEC := 0.7
const CLOSE_SEC := 0.9
const FLOOR_TILE := 2.0                ## the floor texture's metres per repeat (build_bar_room.gd TILE.floor)
const FLOOR_MATERIAL := "res://src/gameplay/bar_room/materials/floor.tres"
const LAYER_WORLD := 8

var is_open := false
var openness := 0.0                    ## 0 closed .. 1 hanging open

var _tween: Tween
var _hinges: Array[Node3D] = []        ## west (rotates down about its west edge), east
var _bodies: Array[StaticBody3D] = []
var _pit: Node3D
var _tray: MeshInstance3D


func _ready() -> void:
	position = HOLE_CENTER
	var half := HOLE_SIZE.x * 0.5
	for side in [-1.0, 1.0]:  # -1 west leaf, +1 east leaf
		var hinge := Node3D.new()
		hinge.name = "Hinge_W" if side < 0.0 else "Hinge_E"
		hinge.position = Vector3(side * half, 0.0, 0.0)
		add_child(hinge)
		# the leaf reaches from its hinge toward the hole's middle, 2 cm further out under the slab and 1 cm past the middle so no seam shows
		# a crack; its top is 1 mm (west) / 3 mm (east) below the floor so the overlapping strips never share a plane
		var span := half + LAP_OUT + LAP_IN
		var centre := Vector3(-side * (half + LAP_IN - LAP_OUT) * 0.5, -THICK * 0.5 - (0.001 if side < 0.0 else 0.003), 0.0)
		var body := StaticBody3D.new()
		body.name = "Panel"
		body.collision_layer = LAYER_WORLD
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(span, THICK, HOLE_SIZE.y)
		shape.shape = box
		shape.position = centre
		body.add_child(shape)
		var mi := MeshInstance3D.new()
		mi.name = "Floor"
		mi.mesh = _panel_mesh(HOLE_CENTER + Vector3(side * half, 0.0, 0.0) + centre, Vector3(span, THICK, HOLE_SIZE.y))
		mi.material_override = load(FLOOR_MATERIAL)
		mi.layers = 1 | Mirror.ROOM_LAYER  # the mirror's room cube keeps a floor, not a hole
		mi.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = centre
		body.add_child(mi)
		hinge.add_child(body)
		_hinges.append(hinge)
		_bodies.append(body)
	_build_shaft()
	_apply()


## The leaves swing down about the hole's west / east edges (`OPEN_SEC`, eased) and the panels stop being floor; `finished` when open.
func open() -> void:
	is_open = true
	_set_solid(false)
	_go(1.0, OPEN_SEC)


## The leaves swing back (`CLOSE_SEC`, eased); the panels are floor again when fully shut; `finished` then.
func close() -> void:
	is_open = false
	_go(0.0, CLOSE_SEC)


## The anchor at the bottom of the shaft (centred under the hole, the shaft floor level): the failure cutscene puts the monster's mouth here.
## `get_meta(&"width")` is the shaft's width, 3 m.
func pit() -> Node3D:
	return _pit


## Seeks the leaves without a tween (probes, tools). Cancels a running `open()`/`close()`.
func set_openness(o: float) -> void:
	_kill()
	openness = clampf(o, 0.0, 1.0)
	is_open = openness > 0.0
	_set_solid(openness <= 0.0)
	_apply()


func _go(target: float, seconds: float) -> void:
	_kill()
	if is_equal_approx(openness, target):
		_set_solid(target <= 0.0)
		call_deferred(&"emit_signal", &"finished")
		return
	_tween = create_tween()
	_tween.tween_method(_set_value, openness, target, seconds * absf(target - openness)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.finished.connect(func() -> void:
		_set_solid(target <= 0.0)
		finished.emit())


func _kill() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _set_value(o: float) -> void:
	openness = o
	_apply()


func _apply() -> void:
	var a := deg_to_rad(OPEN_DEG) * openness
	if _tray != null:
		_tray.visible = openness > 0.0  # a shut floor needs no shaft drawn under it
	if _hinges.size() == 2:
		_hinges[0].rotation.z = -a  # west leaf: hinged at its west edge, extends +x, drops with a negative turn about z
		_hinges[1].rotation.z = a


func _set_solid(on: bool) -> void:
	for b in _bodies:
		b.collision_layer = LAYER_WORLD if on else 0


## Four walls and a floor in the shaft, plus the Pit anchor. The walls stand 2 cm inside the hole so they never share a plane with the slab's edge.
func _build_shaft() -> void:
	var inset := 0.02
	var size := HOLE_SIZE - Vector2(inset, inset) * 2.0
	_tray = MeshInstance3D.new()
	_tray.name = "Shaft"
	_tray.mesh = StagingTray.mesh(size, SHAFT_DEPTH)
	_tray.material_override = StagingTray.material(SHAFT_DEPTH * 0.7)  # black well before the bottom
	_tray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tray.visible = false
	add_child(_tray)
	var walls := StaticBody3D.new()
	walls.name = "ShaftBody"
	walls.collision_layer = LAYER_WORLD
	walls.collision_mask = 0
	add_child(walls)
	var t := 0.3
	for w: Array in [
		[Vector3(0.0, -SHAFT_DEPTH - t * 0.5, 0.0), Vector3(HOLE_SIZE.x + 2.0 * t, t, HOLE_SIZE.y + 2.0 * t)],
		[Vector3(-(HOLE_SIZE.x + t) * 0.5, -SHAFT_DEPTH * 0.5, 0.0), Vector3(t, SHAFT_DEPTH, HOLE_SIZE.y + 2.0 * t)],
		[Vector3((HOLE_SIZE.x + t) * 0.5, -SHAFT_DEPTH * 0.5, 0.0), Vector3(t, SHAFT_DEPTH, HOLE_SIZE.y + 2.0 * t)],
		[Vector3(0.0, -SHAFT_DEPTH * 0.5, -(HOLE_SIZE.y + t) * 0.5), Vector3(HOLE_SIZE.x, SHAFT_DEPTH, t)],
		[Vector3(0.0, -SHAFT_DEPTH * 0.5, (HOLE_SIZE.y + t) * 0.5), Vector3(HOLE_SIZE.x, SHAFT_DEPTH, t)],
	]:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = w[1]
		cs.shape = bs
		cs.position = w[0]
		walls.add_child(cs)
	_pit = Node3D.new()
	_pit.name = "Pit"
	_pit.position = Vector3(0.0, -SHAFT_DEPTH, 0.0)
	_pit.set_meta(&"width", HOLE_SIZE.x)
	add_child(_pit)


## A box mesh with the floor's world-metre UVs (the room's own mapping: position / tile on the dominant axis), so the panels continue the
## boards of the baked floor around the hole. `world_centre` is where the box stands when closed.
static func _panel_mesh(world_centre: Vector3, size: Vector3) -> ArrayMesh:
	var bm := BoxMesh.new()
	bm.size = size
	var a := bm.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in a[Mesh.ARRAY_INDEX]:
		var p := v[i] + world_centre
		var an := n[i].abs()
		var uv: Vector2
		if an.y >= an.x and an.y >= an.z:
			uv = Vector2(p.x, p.z) / FLOOR_TILE
		elif an.x >= an.z:
			uv = Vector2(p.z, -p.y) / FLOOR_TILE
		else:
			uv = Vector2(p.x, -p.y) / FLOOR_TILE
		st.set_color(Color.WHITE)  # the floor material multiplies its vertex colour
		st.set_normal(n[i])
		st.set_uv(uv)
		st.add_vertex(v[i])
	st.generate_tangents()  # the floor has a normal map (a mesh without tangents shades black on a phone)
	return st.commit()
