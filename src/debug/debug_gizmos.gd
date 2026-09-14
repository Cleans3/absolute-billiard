class_name DebugGizmos
extends Node3D

## Gizmo overlay (T2.4): pocket mouths, drop zones, rail inward normals, jaw markers,
## kitchen line, head/foot/centre spots, plus ball velocity vectors + trails while a shot
## is live. Toggled by debug_gizmos (F3).
##
## Reads geometry from Table.layout (loop 1, T4.5) — the same TableGeometry.layout() output
## table_builder.gd/table_visuals.gd build from — converted to world space via table.to_global();
## no geometry formula (mouth/shelf/facing maths) is duplicated here. Ball enumeration goes
## through PhysicsSim.get_balls() (contract §PhysicsSim), not DemoRack.

var table: Table

const COLOR_POCKET := Color(1, 1, 0)
const COLOR_DROP := Color(1, 0.4, 0)
const COLOR_RAIL := Color(0, 1, 1)
const COLOR_JAW := Color(1, 0, 1)
const COLOR_KITCHEN := Color(0, 1, 0)
const COLOR_SPOT := Color(1, 1, 1)
const COLOR_VELOCITY := Color(1, 0, 0)
const COLOR_TRAIL := Color(1, 0.6, 0.6)
const TRAIL_LEN := 20
const TRAIL_MIN_SPEED := 0.05

var _mesh: MeshInstance3D
var _im: ImmediateMesh
var _trails: Dictionary = {}  # Ball -> Array[Vector3]


func _ready() -> void:
	_im = ImmediateMesh.new()
	_mesh = MeshInstance3D.new()
	_mesh.mesh = _im
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh.material_override = mat
	add_child(_mesh)


func _process(_delta: float) -> void:
	if not visible or not table:
		return
	_update_trails()
	_draw()


func _live_balls() -> Array:
	var out := []
	if table and table.sim:
		for ball in table.sim.get_balls():
			if not ball.is_pocketed:
				out.append(ball)
	return out


func _update_trails() -> void:
	for ball in _live_balls():
		if ball.linear_velocity.length() < TRAIL_MIN_SPEED:
			_trails.erase(ball)
			continue
		var pts: Array = _trails.get(ball, [])
		pts.append(ball.global_position)
		if pts.size() > TRAIL_LEN:
			pts.pop_front()
		_trails[ball] = pts


func _draw() -> void:
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	var d := _geometry()
	for pocket in d.pockets:
		_circle(pocket.position, pocket.radius, COLOR_POCKET)
	for drop in d.drops:
		_box(drop.position, drop.size, COLOR_DROP)
	for rail in d.rails:
		_seg(rail.a, rail.b, COLOR_RAIL)
		var mid: Vector3 = (rail.a + rail.b) * 0.5
		_seg(mid, mid + rail.normal * 0.3, COLOR_RAIL)
	for f in d.facings:
		_seg(f[0], f[1], COLOR_JAW)
	_seg(d.kitchen_a, d.kitchen_b, COLOR_KITCHEN)
	for spot in d.spots:
		_cross(spot, 0.05, COLOR_SPOT)
	for ball in _live_balls():
		var v: Vector3 = ball.linear_velocity
		if v.length() > TRAIL_MIN_SPEED:
			_seg(ball.global_position, ball.global_position + v * 0.3, COLOR_VELOCITY)
		var pts: Array = _trails.get(ball, [])
		for i in range(1, pts.size()):
			_seg(pts[i - 1], pts[i], COLOR_TRAIL)
	_im.surface_end()


func _geometry() -> Dictionary:
	var s := table.spec
	var lay := table.layout
	var y := Vector3(0, s.bed_height_m, 0)

	var pockets := []
	var drops := []
	for ps in lay.pockets:
		pockets.append({position = table.to_global(ps.position + y), radius = ps.mouth_width_m * 0.5})
	for dz in lay.drop_zones:
		var pos: Vector3 = dz.position
		var size: Vector2 = dz.size
		drops.append({position = table.to_global(pos + y), size = size})

	var rails := []
	var jaws := []
	var facings := []
	var facing_len := s.ball_radius_m * TableBuilder.FACING_LENGTH_RATIO
	for rail in lay.rails:
		rails.append({
			a = table.to_global(rail.a + y),
			b = table.to_global(rail.b + y),
			normal = table.global_transform.basis * (-rail.inward_normal),
		})
		jaws.append(table.to_global(rail.a + y))
		jaws.append(table.to_global(rail.b + y))
		if not rail.facing_a.is_zero_approx():
			facings.append([table.to_global(rail.a + y), table.to_global(rail.a + rail.facing_a * facing_len + y)])
		if not rail.facing_b.is_zero_approx():
			facings.append([table.to_global(rail.b + y), table.to_global(rail.b + rail.facing_b * facing_len + y)])

	var head: Vector3 = lay.spots.head
	var foot: Vector3 = lay.spots.foot
	var centre: Vector3 = lay.spots.centre

	return {
		pockets = pockets,
		drops = drops,
		rails = rails,
		jaws = jaws,
		jaw_radius = s.jaw_radius_m,
		facings = facings,
		kitchen_a = table.to_global(Vector3(s.kitchen_line_x, 0.0, -s.width_m * 0.5) + y),
		kitchen_b = table.to_global(Vector3(s.kitchen_line_x, 0.0, s.width_m * 0.5) + y),
		spots = [table.to_global(head + y), table.to_global(foot + y), table.to_global(centre + y)],
	}


func _seg(a: Vector3, b: Vector3, color: Color) -> void:
	_im.surface_set_color(color)
	_im.surface_add_vertex(to_local(a))
	_im.surface_set_color(color)
	_im.surface_add_vertex(to_local(b))


func _circle(center: Vector3, radius: float, color: Color, segments: int = 16) -> void:
	var prev := center + Vector3(radius, 0, 0)
	for i in range(1, segments + 1):
		var angle := TAU * i / segments
		var p := center + Vector3(cos(angle), 0, sin(angle)) * radius
		_seg(prev, p, color)
		prev = p


func _box(center: Vector3, size: Vector2, color: Color) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var corners := [
		center + Vector3(-hx, 0, -hz), center + Vector3(hx, 0, -hz),
		center + Vector3(hx, 0, hz), center + Vector3(-hx, 0, hz),
	]
	for i in range(corners.size()):
		_seg(corners[i], corners[(i + 1) % corners.size()], color)


func _cross(center: Vector3, size: float, color: Color) -> void:
	_seg(center + Vector3(-size, 0.001, 0), center + Vector3(size, 0.001, 0), color)
	_seg(center + Vector3(0, 0.001, -size), center + Vector3(0, 0.001, size), color)
