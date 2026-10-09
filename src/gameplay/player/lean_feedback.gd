class_name LeanFeedback
extends Node3D
## Makes "Lean on the rail" visible (03 §3.7, 06 P25). Every peer hears `interaction_applied`: the presser's body leans
## for LEAN_SEC and a toast names who leaned on which rail and what it does. A marker lies on each rail whose cushion is
## dead right now, derived from the live Effect state — so a client that resumed rebuilds it — and it goes with the Effect
## when the Shot resolves.

const LEAN_SEC := 2.0
const RAIL_NAMES := {
	&"rail_w": "west rail", &"rail_e": "east rail",
	&"rail_n_w": "north-west rail", &"rail_n_e": "north-east rail",  ## the long rails are two segments split by the side pockets
	&"rail_s_w": "south-west rail", &"rail_s_e": "south-east rail",
}
const MARK_COLOR := Color(1.0, 0.72, 0.15)
const MARK_AT := 0.65   ## across the rail wood, outward from the cushion, as a share of the rail width
const MARK_H := 0.012

@export var world: WorldInteractions
@export var effects: EffectManager
@export var table: Table
@export var spawner: Node  ## PlayerSpawner, untyped: a `-s` probe compiles this script before the NetManager autoload exists

var _marks := {}  ## rail id (1 + index in Stats.RAILS) -> MeshInstance3D
var _mat: StandardMaterial3D
var _t := 0.0


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.albedo_color = MARK_COLOR
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	set_process(false)
	world.interaction_applied.connect(_on_applied)
	effects.effect_applied.connect(func(_id: StringName, _t: int, _o: int, _d: float) -> void: _sync())
	effects.effect_expired.connect(func(_id: StringName, _t: int, _o: int) -> void: _sync())
	table.rebuilt.connect(_build)
	_build()


func is_marked(rail_id: int) -> bool:
	return _marks.has(rail_id) and (_marks[rail_id] as MeshInstance3D).visible


func _process(delta: float) -> void:
	_t += delta
	_mat.albedo_color = MARK_COLOR.lerp(Color.WHITE, 0.25 + 0.25 * sin(_t * 6.0))


func _on_applied(peer_id: int, kind: StringName, target_id: int, _payload: Dictionary) -> void:
	if kind != &"lean_on_rail" or target_id < 1 or target_id > Stats.RAILS.size():
		return
	var rail_name: String = RAIL_NAMES[Stats.RAILS[target_id - 1]]
	var player := spawner.call(&"get_player", peer_id) as Player if spawner != null else null
	if player != null:
		player.lean_on(_rail_point(target_id), LEAN_SEC)
	if UIRouter.instance != null:
		UIRouter.instance.toast("%s leaned on the %s: cushion %d%% dead" % [_name_of(peer_id), rail_name, _dead_percent()])


## The rail's wood top mid-way along the segment, where the leaning hands rest.
func _rail_point(rail_id: int) -> Vector3:
	var rail := _rail(rail_id)
	var spec := table.spec
	var mid := (rail.a + rail.b) * 0.5 - rail.inward_normal * (spec.rail_width_m * MARK_AT)
	return table.to_global(mid + Vector3(0.0, table.cloth_y() + spec.rail_height_m, 0.0))


func _rail(rail_id: int) -> TableLayout.RailSegment:
	for r in table.layout.rails:
		if r.id == Stats.RAILS[rail_id - 1]:
			return r
	return null


func _dead_percent() -> int:
	var w := FxCatalog.interaction(&"lean_on_rail")
	for m in w.effect.stat_modifiers:
		if m.stat == &"cushion_restitution_mult":
			return roundi((1.0 - m.value) * 100.0)
	return 0


func _name_of(peer_id: int) -> String:
	var net := get_tree().root.get_node(^"NetManager")  # by path: a `-s` probe compiles this script before the autoloads exist
	for e: Dictionary in net.get_roster():
		if e.peer_id == peer_id:
			return String(e.name)
	return "Someone"


func _build() -> void:
	for m: MeshInstance3D in _marks.values():
		m.free()
	_marks.clear()
	var spec := table.spec
	for i in Stats.RAILS.size():
		var rail := _rail(i + 1)
		if rail == null:
			continue
		var box := BoxMesh.new()
		box.size = Vector3(spec.rail_width_m * 0.4, MARK_H, rail.a.distance_to(rail.b) * 0.8)
		var mi := MeshInstance3D.new()
		mi.name = String(rail.id)
		mi.mesh = box
		mi.material_override = _mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		var at := (rail.a + rail.b) * 0.5 - rail.inward_normal * (spec.rail_width_m * MARK_AT)
		mi.global_transform = table.global_transform * Transform3D(TableGeometry.rail_basis(rail), at + Vector3(0.0, table.cloth_y() + spec.rail_height_m + MARK_H * 0.5, 0.0))
		_marks[i + 1] = mi
	_sync()


func _sync() -> void:
	var any := false
	for id: int in _marks:
		var on := absf(effects.rail_restitution_mult(id) - 1.0) > 0.001
		(_marks[id] as MeshInstance3D).visible = on
		any = any or on
	set_process(any)
