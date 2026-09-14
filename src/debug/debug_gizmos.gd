class_name DebugGizmos
extends Node3D

## Gizmo overlay (T2.4): pocket mouths, drop zones, rail inward normals, jaw markers,
## kitchen line, head/foot/centre spots, plus ball velocity vectors + trails while a shot
## is live. Toggled by debug_gizmos (F3).
##
## Reads geometry from TableSpec exports/getters and Table.pockets (both kept, contract
## §Table), never from TableLayout — no guard needed, works before and after the table
## branch merges. Rail/jaw/kitchen/spot positions are recomputed with the same formula
## table.gd uses today; if the table branch changes PocketSpec.position to be relative to
## bed height instead of absolute (contract note), pocket/drop gizmos will sit at the wrong
## height until that is checked at sync (plan.md Log).

var table: Table
var rack: Node3D

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
	if rack:
		for ball in rack.get_children():
			if ball is Ball and not ball.is_pocketed:
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
	for jaw in d.jaws:
		_circle(jaw, d.jaw_radius, COLOR_JAW)
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
	var hl := s.length_m * 0.5
	var hw := s.width_m * 0.5
	var y := s.bed_height_m
	var c := s.corner_mouth_m / sqrt(2.0)
	var side := s.side_mouth_m * 0.5
	var r := s.ball_radius_m

	var pockets := []
	var drops := []
	for ps in table.pockets.values():
		pockets.append({position = table.to_global(ps.position), radius = ps.mouth_width_m * 0.5})
		var drop_pos: Vector3 = ps.position + Vector3(0, -2.0 * r, 0)
		drops.append({
			position = table.to_global(drop_pos),
			size = Vector2(s.corner_mouth_m * 1.4, s.corner_mouth_m * 1.4),
		})

	var rail_segments := [
		[Vector3(-hl + c, y, -hw), Vector3(-side, y, -hw)],
		[Vector3(side, y, -hw), Vector3(hl - c, y, -hw)],
		[Vector3(-hl + c, y, hw), Vector3(-side, y, hw)],
		[Vector3(side, y, hw), Vector3(hl - c, y, hw)],
		[Vector3(-hl, y, -hw + c), Vector3(-hl, y, hw - c)],
		[Vector3(hl, y, -hw + c), Vector3(hl, y, hw - c)],
	]
	var rails := []
	var jaws := []
	for seg in rail_segments:
		var a: Vector3 = seg[0]
		var b: Vector3 = seg[1]
		var mid := (a + b) * 0.5
		var out_normal := Vector3(0, 0, signf(mid.z)) if is_zero_approx((b - a).z) else Vector3(signf(mid.x), 0, 0)
		rails.append({
			a = table.to_global(a),
			b = table.to_global(b),
			normal = table.global_transform.basis * (-out_normal),
		})
		jaws.append(table.to_global(a))
		jaws.append(table.to_global(b))

	var foot_x = s.get("foot_spot_x")
	if foot_x == null:
		foot_x = s.length_m * 0.25

	return {
		pockets = pockets,
		drops = drops,
		rails = rails,
		jaws = jaws,
		jaw_radius = s.jaw_radius_m,
		kitchen_a = table.to_global(Vector3(s.kitchen_line_x, y, -hw)),
		kitchen_b = table.to_global(Vector3(s.kitchen_line_x, y, hw)),
		spots = [
			table.to_global(Vector3(s.kitchen_line_x, y, 0)),
			table.to_global(Vector3(foot_x, y, 0)),
			table.to_global(Vector3(0, y, 0)),
		],
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
