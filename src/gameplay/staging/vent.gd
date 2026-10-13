class_name Vent
extends Node3D
## MainLevel/Vent (06 P33 U16, D14): the ceiling vent the set-up saucer flies out of. A dynamic fixture flush under the ceiling slab,
## straight above the table's east short rail (the one nearest the Blackboard), clear of the beams at x = 0 / ±4.5, the lamp rod and the
## ceiling camera's pod. Two draw calls (the housing, the louvres as one MultiMesh), no collision object, no light. Not baked: the ceiling
## needs no rebuild for it. The saucer waits inside the housing, hidden behind the closed louvres. The louvres are SLATS thin blades that lie
## side by side across the mouth and slide apart, half to each wall, where they stack (a saucer cannot fly through hinged blades: an open
## louvre is a wall); `openness` 1 leaves the middle metre and a half clear.
## API (frozen, F3b codes against it): `open()`, `close()` (tweened, emit `finished`), `mouth_transform()`, `is_open`.

signal finished

const SIZE := Vector2(1.9, 1.9)   ## x, z of the housing
const DEPTH := 0.5                ## how far it hangs below the ceiling slab
const WALL := 0.05
const SLATS := 8
const PER_WALL := 4               ## slats that stack at each wall when open (SLATS / 2)
const PILE_STEP := 0.02           ## the open stack of four slats at each wall is fanned out by this much, so it reads as slats
const LEVEL_STEP := 0.016         ## neighbours lie at different heights (4 levels): two slats never share a plane
const OPEN_SEC := StagingPlan.VENT_OPEN_SEC
const CLOSE_SEC := StagingPlan.VENT_CLOSE_SEC
const METAL := Color(0.09, 0.09, 0.1)
const VOID := Color(0.01, 0.01, 0.012)
const SLAT_COLOR := Color(0.2, 0.17, 0.12)

@export var table: Table  ## whose east rail it sits over; unset = wherever the scene put it

## The target state: true from `open()` until `close()` (or `set_openness(0)`), whatever the louvres are doing right now.
var is_open := false
## 0 closed .. 1 fully open: how far the louvres have slid apart.
var openness := 0.0

## Where each slat lies along z (housing-local) right now: the placements the MultiMesh was given, kept to read back (a headless run has no
## MultiMesh storage to ask).
var slat_z := PackedFloat32Array()

var _tween: Tween
var _slats: MultiMeshInstance3D
var _housing: MeshInstance3D
var _pitch := 0.0


func _ready() -> void:
	if table != null:
		global_position = Vector3(table.global_position.x + table.spec.length_m * 0.5, DecorPlan.CEIL, table.global_position.z)
	_build()
	_apply()


## The louvres slide apart (`OPEN_SEC`, eased); `finished` when fully open.
func open() -> void:
	is_open = true
	_go(1.0, OPEN_SEC)


## The louvres slide back across the mouth (`CLOSE_SEC`, eased); `finished` when fully closed.
func close() -> void:
	is_open = false
	_go(0.0, CLOSE_SEC)


## The opening's pose in world space: origin at the centre of the mouth (the housing's bottom plane), -Z pointing straight out of it
## (down into the room), +Y toward the north wall. A saucer, gas or a camera placed with this transform comes out of the vent.
func mouth_transform() -> Transform3D:
	return global_transform * Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0.0, -DEPTH, 0.0))


## Seeks the louvres without a tween (RoundStaging drives the set-up from its own clock; probes). Cancels a running `open()`/`close()`.
func set_openness(o: float) -> void:
	_kill()
	openness = clampf(o, 0.0, 1.0)
	is_open = openness > 0.0
	_apply()


func _go(target: float, seconds: float) -> void:
	_kill()
	is_open = target > 0.5
	if is_equal_approx(openness, target):
		call_deferred(&"emit_signal", &"finished")
		return
	_tween = create_tween()
	_tween.tween_method(_set_value, openness, target, seconds * absf(target - openness)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.finished.connect(func() -> void: finished.emit())


func _kill() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _set_value(o: float) -> void:
	openness = o
	_apply()


func _apply() -> void:
	if _slats == null:
		return
	var half := (SIZE.y - 2.0 * WALL) * 0.5
	var blade := _pitch * 1.15
	slat_z.resize(SLATS)
	for i in SLATS:
		var north := i < PER_WALL
		var k := i if north else SLATS - 1 - i  # 0 at the wall
		var closed_z := -half + _pitch * (float(i) + 0.5)
		var open_z := (-half + blade * 0.5 + PILE_STEP * float(k)) if north else (half - blade * 0.5 - PILE_STEP * float(k))
		var y := -DEPTH + 0.02 + LEVEL_STEP * float(i % 4)
		var z := lerpf(closed_z, open_z, openness)
		slat_z[i] = z
		_slats.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(0.0, y, z)))


func _build() -> void:
	var inner := Vector2(SIZE.x - 2.0 * WALL, SIZE.y - 2.0 * WALL)
	_pitch = inner.y / float(SLATS)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0.0, -DEPTH * 0.5, -(SIZE.y - WALL) * 0.5), Vector3(SIZE.x, DEPTH, WALL), METAL)   # north wall
	_box(st, Vector3(0.0, -DEPTH * 0.5, (SIZE.y - WALL) * 0.5), Vector3(SIZE.x, DEPTH, WALL), METAL)    # south wall
	_box(st, Vector3(-(SIZE.x - WALL) * 0.5, -DEPTH * 0.5, 0.0), Vector3(WALL, DEPTH, inner.y), METAL)  # west wall
	_box(st, Vector3((SIZE.x - WALL) * 0.5, -DEPTH * 0.5, 0.0), Vector3(WALL, DEPTH, inner.y), METAL)   # east wall
	_box(st, Vector3(0.0, -0.011, 0.0), Vector3(inner.x, 0.02, inner.y), VOID)                          # the dark inside, over the ceiling's texture
	var lip := 0.1
	_box(st, Vector3(0.0, -DEPTH + 0.03, -(SIZE.y + lip) * 0.5), Vector3(SIZE.x + 2.0 * lip, 0.06, lip), METAL)  # the flange round the mouth
	_box(st, Vector3(0.0, -DEPTH + 0.03, (SIZE.y + lip) * 0.5), Vector3(SIZE.x + 2.0 * lip, 0.06, lip), METAL)
	_box(st, Vector3(-(SIZE.x + lip) * 0.5, -DEPTH + 0.03, 0.0), Vector3(lip, 0.06, SIZE.y), METAL)
	_box(st, Vector3((SIZE.x + lip) * 0.5, -DEPTH + 0.03, 0.0), Vector3(lip, 0.06, SIZE.y), METAL)
	var housing_mat := StandardMaterial3D.new()
	housing_mat.vertex_color_use_as_albedo = true
	housing_mat.metallic = 0.6
	housing_mat.roughness = 0.55
	_housing = MeshInstance3D.new()
	_housing.name = "Housing"
	_housing.mesh = st.commit()
	_housing.material_override = housing_mat
	_housing.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC  # no UV2: lit by the bake's probes, like the tripods
	_housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_housing)

	var slat := BoxMesh.new()
	slat.size = Vector3(inner.x - 0.02, 0.014, _pitch * 1.15)
	var slat_mat := StandardMaterial3D.new()
	slat_mat.albedo_color = SLAT_COLOR
	slat_mat.metallic = 0.5
	slat_mat.roughness = 0.45
	slat.material = slat_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = SLATS
	mm.mesh = slat
	_slats = MultiMeshInstance3D.new()
	_slats.name = "Louvres"
	_slats.multimesh = mm
	_slats.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	_slats.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_slats)


static func _box(st: SurfaceTool, centre: Vector3, size: Vector3, color: Color) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	var a := bm.get_mesh_arrays()
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	for i in a[Mesh.ARRAY_INDEX]:
		st.set_color(color)
		st.set_normal(n[i])
		st.add_vertex(v[i] + centre)
