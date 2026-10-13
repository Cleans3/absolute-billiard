class_name ShotGuide
extends MeshInstance3D

## The aim guide (01 §3 "Shot guide", 10-fx §3.5): draws `ShotModel`'s trace of the live `ShotIntent` on the cloth while the local
## shooter aims. One unshaded alpha `ImmediateMesh` rebuilt only when an input changes (aim, power, spin, elevation, the cue
## ball, the cloth/tilt numbers); a few hundred vertices, one draw call, nothing allocated per frame. Local shooter only: the
## puppets' cues never carry it (no spin on the wire, 08 §2.6).
##   cue-ball path  warm white, cyan where the ball is off the cloth (jump: the arc, with a strip on edge and its shadow on the cloth), red when the stroke miscues
##   ghost ring     the cue ball where it first touches; a ring, so the contact point reads on any cloth
##   object line    orange, from the struck ball along its post-impact direction, an arrow at the end
##   past contact   the same path, dimmer: the cue ball past the ball, or the bounce off the cushion
## With no power charged yet it previews at a fixed power (dimmer) so the spin, massé and jump shapes can be set up.

## Render layer 12: the local player's camera draws it (it sees every layer but HEAD_LAYER), the mirror's passes do not; a feed camera (a
## tripod, the ceiling cam) must leave it out of its cull mask - it is the shooter's aid, not the show.
const LAYER := 1 << 11
const LIFT_M := 0.004   # above the cloth (never coplanar with it)
const HALF_W_M := 0.006
const RING_SEGS := 28
const PREVIEW_BELOW := 0.02
const PREVIEW_POWER := 0.5
const PREVIEW_POWER_JUMP := 0.7  # a jump needs Ball.JUMP_MIN_POWER; the middle of its range
const PREVIEW_ALPHA := 0.55
const AIR_SHADOW := 0.4   # the arc's shadow on the cloth, against the arc's own alpha
const C_MAIN := Color(1.0, 0.93, 0.55)
const C_AIR := Color(0.55, 0.9, 1.0)
const C_MISCUE := Color(1.0, 0.35, 0.3)
const C_OBJ := Color(1.0, 0.58, 0.2)
const C_GHOST := Color(1.0, 1.0, 1.0)
const SIG_SIZE := 14

var model := ShotModel.new()

var _im := ImmediateMesh.new()
var _sig := PackedFloat32Array()
var _cur := PackedFloat32Array()
var _drop := 0.0       # ball radius - LIFT: the ribbon runs along the ball's bottom
var _floor_y := 0.0
var _alpha := 1.0


func _ready() -> void:
	_sig.resize(SIG_SIZE)
	_cur.resize(SIG_SIZE)
	mesh = _im
	top_level = true
	global_transform = Transform3D.IDENTITY  # top_level keeps the transform the node had: under the Head that is 1.6 m up and a seat aside, and the ribbon is built in world coordinates (V7: it drew on the ceiling)
	layers = LAYER
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	material_override = mat
	hide()


func clear() -> void:
	_im.clear_surfaces()
	_sig.fill(NAN)
	hide()


## Re-traces and redraws if any input changed since the last call. `preview` = no power charged yet (the caller picked one).
func update(cue: Ball, intent: ShotIntent, spec: CueSpec, table: Table, preview: bool) -> void:
	if cue == null or table == null or cue.sim == null or cue.motion == null:
		clear()
		return
	var p := cue.global_position
	var m := cue.motion
	_cur[0] = intent.aim_dir.x
	_cur[1] = intent.aim_dir.y
	_cur[2] = intent.power
	_cur[3] = intent.spin_offset.x
	_cur[4] = intent.spin_offset.y
	_cur[5] = intent.elevation_deg
	_cur[6] = p.x
	_cur[7] = p.y
	_cur[8] = p.z
	_cur[9] = 1.0 if preview else 0.0
	_cur[10] = m.friction_mult
	_cur[11] = m.tilt.x
	_cur[12] = m.tilt.y
	_cur[13] = cue.sim.cushion_restitution_mult
	if _cur == _sig and visible:
		return
	_sig = _cur.duplicate()
	model.trace(cue, intent, spec, table)
	if model.path.size() < 2 or model.path[0].distance_to(model.path[model.path.size() - 1]) < 1e-4:  # nothing to draw (an empty surface is an engine error)
		clear()
		return
	_drop = cue.radius - LIFT_M
	_floor_y = m.floor_y
	_alpha = PREVIEW_ALPHA if preview else 1.0
	_rebuild(cue.radius)
	show()


func _rebuild(radius: float) -> void:
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var base := C_MISCUE if model.plan.miscue else C_MAIN
	_ribbon(model.path, base, Color(base, 0.7), HALF_W_M)
	if model.hit != ShotModel.Hit.NONE:
		_ring(model.hit_pos, radius, C_GHOST)
	if model.after.size() >= 2:
		_ribbon(model.after, Color(base, 0.5), Color(base, 0.12), HALF_W_M * 0.8)
	if model.obj_path.size() >= 2:
		_ribbon(model.obj_path, C_OBJ, Color(C_OBJ, 0.45), HALF_W_M * 1.2)
		_arrow(model.obj_path[model.obj_path.size() - 1], model.obj_dir, C_OBJ)
	if model.has_land:
		_ring(model.land_pos, radius * 0.5, C_AIR)
	_im.surface_end()


## A flat ribbon along `pts` (half-width `hw`), colour fading `c0` -> `c1`; points off the cloth are tinted cyan.
func _ribbon(pts: PackedVector3Array, c0: Color, c1: Color, hw: float) -> void:
	var n := pts.size()
	for i in n - 1:
		var p := pts[i]
		var q := pts[i + 1]
		var dx := q.x - p.x
		var dz := q.z - p.z
		var l := sqrt(dx * dx + dz * dz)
		if l < 1e-5:
			continue
		var sx := -dz / l * hw
		var sz := dx / l * hw
		var cp := _tint(c0.lerp(c1, float(i) / float(n - 1)), p)
		var cq := _tint(c0.lerp(c1, float(i + 1) / float(n - 1)), q)
		var a := Vector3(p.x + sx, p.y - _drop, p.z + sz)
		var b := Vector3(p.x - sx, p.y - _drop, p.z - sz)
		var c := Vector3(q.x + sx, q.y - _drop, q.z + sz)
		var d := Vector3(q.x - sx, q.y - _drop, q.z - sz)
		_tri(a, cp, b, cp, c, cq)
		_tri(b, cp, d, cq, c, cq)
		if BallMotion.is_airborne(p.y, _floor_y) or BallMotion.is_airborne(q.y, _floor_y):
			# a jump's arc: a second strip standing on edge so it reads from the side, and its shadow on the cloth so it reads from behind
			var up := Vector3(0.0, hw, 0.0)
			var pa := Vector3(p.x, p.y - _drop, p.z)
			var qa := Vector3(q.x, q.y - _drop, q.z)
			_tri(pa + up, cp, pa - up, cp, qa + up, cq)
			_tri(pa - up, cp, qa - up, cq, qa + up, cq)
			var sp := Color(cp, cp.a * AIR_SHADOW)
			var sq := Color(cq, cq.a * AIR_SHADOW)
			var gp := Vector3(p.x, _floor_y - _drop, p.z)
			var gq := Vector3(q.x, _floor_y - _drop, q.z)
			_tri(gp + Vector3(sx, 0.0, sz), sp, gp - Vector3(sx, 0.0, sz), sp, gq + Vector3(sx, 0.0, sz), sq)
			_tri(gp - Vector3(sx, 0.0, sz), sp, gq - Vector3(sx, 0.0, sz), sq, gq + Vector3(sx, 0.0, sz), sq)


func _tint(c: Color, p: Vector3) -> Color:
	var out := c
	if BallMotion.is_airborne(p.y, _floor_y):
		out = Color(C_AIR, c.a)
	out.a *= _alpha
	return out


## A ring of outer radius `radius` on the cloth under `centre` (a ball-bottom height point).
func _ring(centre: Vector3, radius: float, c: Color) -> void:
	var col := Color(c, 0.9 * _alpha)
	var y := centre.y - _drop
	var ro := radius
	var ri := radius - HALF_W_M * 1.6
	for k in RING_SEGS:
		var a0 := TAU * k / RING_SEGS
		var a1 := TAU * (k + 1) / RING_SEGS
		var o0 := Vector3(centre.x + cos(a0) * ro, y, centre.z + sin(a0) * ro)
		var i0 := Vector3(centre.x + cos(a0) * ri, y, centre.z + sin(a0) * ri)
		var o1 := Vector3(centre.x + cos(a1) * ro, y, centre.z + sin(a1) * ro)
		var i1 := Vector3(centre.x + cos(a1) * ri, y, centre.z + sin(a1) * ri)
		_tri(o0, col, i0, col, o1, col)
		_tri(i0, col, i1, col, o1, col)


## An arrowhead on the cloth at `tip`, pointing along `dir`.
func _arrow(tip: Vector3, dir: Vector3, c: Color) -> void:
	if dir == Vector3.ZERO:
		return
	var col := Color(c, 0.95 * _alpha)
	var side := Vector3(-dir.z, 0.0, dir.x) * HALF_W_M * 3.0
	var y := Vector3(0.0, -_drop, 0.0)
	_tri(tip + dir * HALF_W_M * 6.0 + y, col, tip + side + y, col, tip - side + y, col)


func _tri(a: Vector3, ca: Color, b: Vector3, cb: Color, c: Vector3, cc: Color) -> void:
	_im.surface_set_color(ca)
	_im.surface_add_vertex(a)
	_im.surface_set_color(cb)
	_im.surface_add_vertex(b)
	_im.surface_set_color(cc)
	_im.surface_add_vertex(c)
