class_name StagingTray
extends RefCounted
## A dark open box seen from inside, for the pit under the table's bed (clean-up) and the trapdoor shaft: five quads (floor + four walls),
## origin at the centre of the lip, `depth` metres down. Visual only, never a collision shape.

const SHADER := preload("res://src/shaders/staging_tray.gdshader")


static func mesh(size: Vector2, depth: float) -> ArrayMesh:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-hx, 0.0, -hz)
	var b := Vector3(hx, 0.0, -hz)
	var c := Vector3(hx, 0.0, hz)
	var d := Vector3(-hx, 0.0, hz)
	var down := Vector3(0.0, -depth, 0.0)
	_quad(st, a + down, b + down, c + down, d + down)  # floor
	_quad(st, a, b, b + down, a + down)                # north wall (-z)
	_quad(st, d, c, c + down, d + down)                # south wall (+z)
	_quad(st, a, d, d + down, a + down)                # west wall (-x)
	_quad(st, b, c, c + down, b + down)                # east wall (+x)
	return st.commit()


static func material(depth: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"depth", depth)
	return m


static func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	for v in [p0, p1, p2, p0, p2, p3]:
		st.add_vertex(v)
