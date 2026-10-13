class_name MonsterMouth
extends Node3D
## The thing under the floor (docs/plan/09 §3.8, adhoc-1013c A10): a fleshy maw built to sit in a ~3 m floor shaft. Origin = the middle
## of the lip, +Y up; a fanged lip ring, three rings of teeth (one MultiMesh), a ribbed throat that narrows over DEPTH_M, a tongue
## plugging it, a red glow. Four draw calls (lip, throat, tongue, teeth), one shader, one light pair. It breathes by itself; `close_amount`
## snaps the outer teeth shut over the middle (FallCam does that once the camera has passed). F3b instances MonsterMouth.tscn in the
## Trapdoor's `Pit` anchor. Presentation only: no collider, no physics.

const LIP_CENTRE_R := 1.28  ## the lip ring's tube centre; its outer edge is 1.48, so the whole prop is 2.96 m across
const TUBE_R := 0.2
const WIDTH_M := (LIP_CENTRE_R + TUBE_R) * 2.0
const DEPTH_M := 7.5
const THROAT_R_TOP := 1.1
const THROAT_R_END := 0.4
const SIDES := 20
const ROWS := 36
const TONGUE_Y := -5.4
const FLESH := "res://src/shaders/flesh.gdshader"
const IVORY := Color("e6dcb8")
const GUM := Color("b86a5c")
## [tooth count, ring y, tilt inward (deg), size, how much `close_amount` bends it]
const RINGS := [[22, 0.0, 20.0, 1.0, 1.0], [16, -1.1, 30.0, 0.8, 0.45], [12, -2.3, 38.0, 0.65, 0.2]]

var close_amount := 0.0:  ## 0 open, 1 the outer teeth meet over the throat
	set(v):
		close_amount = clampf(v, 0.0, 1.0)
		_pose_teeth()
var auto := true  ## advances itself every frame; FallCam turns it off and calls pose()
var mouth_seed := 7  ## teeth sizes and angles jitter

var _time := 0.0
var _flesh_mats: Array[ShaderMaterial] = []
var _teeth: MultiMesh
var _tongue: MeshInstance3D
var _glow_low: OmniLight3D
var _glow_lip: OmniLight3D
var _jitter: Array[Vector3] = []  ## per tooth: angle jitter, length scale, radius jitter
var _tooth_ring: Array[int] = []
var _tooth_angle: Array[float] = []
var _built := false


func _ready() -> void:
	build()


func build() -> void:
	if _built:
		return
	_built = true
	var rng := RandomNumberGenerator.new()
	rng.seed = mouth_seed
	_build_flesh()
	_build_teeth(rng)
	_glow_low = CutsceneKit.omni(self, Vector3(0.0, -2.2, 0.0), Color(0.9, 0.1, 0.14), 3.0, 8.0)
	_glow_lip = CutsceneKit.omni(self, Vector3(0.0, 0.7, 0.0), Color(1.0, 0.35, 0.3), 1.2, 5.0)
	pose(0.0)


func _process(delta: float) -> void:
	if auto:
		pose(_time + delta)


## Everything that moves, as a pure function of `seconds`.
func pose(seconds: float) -> void:
	_time = seconds
	for m in _flesh_mats:
		m.set_shader_parameter(&"clock", seconds)
	_tongue.position = Vector3(0.0, TONGUE_Y + 0.12 * sin(seconds * 1.1), 0.15)
	_tongue.rotation = Vector3(0.05 * sin(seconds * 0.8), 0.0, 0.08 * sin(seconds * 0.9))
	_tongue.scale = Vector3(1.0, 1.0 + 0.06 * sin(seconds * 1.7), 1.0)
	var beat := 1.0 + 0.15 * sin(seconds * TAU * 0.7)
	_glow_low.light_energy = 3.0 * beat
	_glow_lip.light_energy = 1.2 * beat
	_pose_teeth()


# --- flesh --------------------------------------------------------------------------------------------------------------------------

func _flesh_material(base: Color, deep: Color, top: float, bottom: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(FLESH) as Shader
	m.set_shader_parameter(&"base_color", base)
	m.set_shader_parameter(&"deep_color", deep)
	m.set_shader_parameter(&"depth_top", top)
	m.set_shader_parameter(&"depth_bottom", bottom)
	_flesh_mats.append(m)
	return m


static func throat_radius(y: float) -> float:
	var u := clampf(-y / DEPTH_M, 0.0, 1.0)
	return lerpf(THROAT_R_TOP, THROAT_R_END, pow(u, 0.8)) * (1.0 + 0.06 * sin(u * DEPTH_M * 5.0))


func _build_flesh() -> void:
	# the throat: a surface of revolution, ribbed, narrowing, closed at the end
	var prof := PackedVector2Array()
	var norm := PackedVector2Array()
	for i in ROWS + 1:
		var y := -DEPTH_M * i / ROWS
		prof.append(Vector2(throat_radius(y), y))
	prof.append(Vector2(0.02, -DEPTH_M - 0.3))
	for i in prof.size():
		var a := prof[maxi(i - 1, 0)]
		var b := prof[mini(i + 1, prof.size() - 1)]
		var tangent := b - a
		norm.append(Vector2(tangent.y, -tangent.x).normalized())  # the profile runs down, so this points at the axis: the inside of the throat
	var throat := MeshInstance3D.new()
	throat.name = "Throat"
	throat.mesh = _lathe(prof, norm)
	throat.material_override = _flesh_material(Color(0.62, 0.16, 0.18), Color(0.16, 0.015, 0.05), 0.0, -DEPTH_M)
	throat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(throat)
	# the lip: a fat ring (a circle swept round the axis)
	var ring := PackedVector2Array()
	var ring_n := PackedVector2Array()
	for i in 13:
		var a := TAU * i / 12.0
		ring.append(Vector2(LIP_CENTRE_R + cos(a) * TUBE_R, sin(a) * TUBE_R * 0.9))
		ring_n.append(Vector2(cos(a), sin(a)))
	var lip := MeshInstance3D.new()
	lip.name = "Lip"
	lip.mesh = _lathe(ring, ring_n)
	lip.material_override = _flesh_material(Color(0.78, 0.27, 0.27), Color(0.5, 0.12, 0.15), 1.0, -1.0)
	lip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lip)
	# the tongue: a wide flat lump plugging the throat
	var soup := CutsceneKit.Soup.new()
	soup.ball(Vector3.ZERO, Vector3(0.95, 0.38, 1.5), 14, 8, Color.WHITE)
	_tongue = MeshInstance3D.new()
	_tongue.name = "Tongue"
	_tongue.mesh = soup.mesh(_flesh_material(Color(0.78, 0.3, 0.32), Color(0.36, 0.08, 0.13), 0.38, -0.38))
	_tongue.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tongue)


## A surface of revolution about Y: profile points (radius, y) with their 2D normals, both faces drawn (the shader is double-sided).
func _lathe(prof: PackedVector2Array, norm: PackedVector2Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in prof.size():
		for s in SIDES + 1:
			var a := TAU * s / SIDES
			var c := cos(a)
			var sn := sin(a)
			verts.append(Vector3(prof[i].x * c, prof[i].y, prof[i].x * sn))
			normals.append(Vector3(norm[i].x * c, norm[i].y, norm[i].x * sn).normalized())
			uvs.append(Vector2(float(s) / SIDES, float(i) / maxi(prof.size() - 1, 1)))
	var stride := SIDES + 1
	for i in prof.size() - 1:
		for s in SIDES:
			var a := i * stride + s
			var b := a + 1
			var d := a + stride
			var e := d + 1
			var n := normals[a] + normals[b] + normals[d] + normals[e]
			var cross := (verts[b] - verts[a]).cross(verts[d] - verts[a])
			if cross.dot(n) > 0.0:  # wound clockwise seen from the normal's side
				idx.append_array(PackedInt32Array([a, d, b, b, d, e]))
			else:
				idx.append_array(PackedInt32Array([a, b, d, b, e, d]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# --- teeth --------------------------------------------------------------------------------------------------------------------------

func _build_teeth(rng: RandomNumberGenerator) -> void:
	var soup := CutsceneKit.Soup.new()
	soup.cyl(Vector3.ZERO, 0.5, Vector2(0.17, 0.12), Vector2(0.1, 0.08), 6, GUM, CutsceneKit.Soup.CAP_BOTTOM)
	soup.cyl(Vector3(0.0, 0.5, 0.0), 0.55, Vector2(0.1, 0.08), Vector2(0.012, 0.01), 6, IVORY, 0)
	var tooth_mat := StandardMaterial3D.new()
	tooth_mat.vertex_color_use_as_albedo = true
	tooth_mat.vertex_color_is_srgb = true
	tooth_mat.roughness = 0.3
	tooth_mat.emission_enabled = true
	tooth_mat.emission = Color(0.25, 0.05, 0.05)
	_teeth = MultiMesh.new()
	_teeth.transform_format = MultiMesh.TRANSFORM_3D
	_teeth.mesh = soup.mesh(tooth_mat)
	var total := 0
	for r: Array in RINGS:
		total += int(r[0])
	_teeth.instance_count = total
	for ring_i in RINGS.size():
		var count := int((RINGS[ring_i] as Array)[0])
		for k in count:
			_tooth_ring.append(ring_i)
			_tooth_angle.append(TAU * k / count + (TAU / count) * 0.5 * (ring_i % 2) + rng.randf_range(-0.07, 0.07))
			_jitter.append(Vector3(rng.randf_range(-0.05, 0.05), rng.randf_range(0.75, 1.25), rng.randf_range(-0.04, 0.04)))
	var node := MultiMeshInstance3D.new()
	node.name = "Teeth"
	node.multimesh = _teeth
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)


func _pose_teeth() -> void:
	if _teeth == null:
		return
	for i in _tooth_ring.size():
		var ring: Array = RINGS[_tooth_ring[i]]
		var y: float = ring[1]
		var tilt := deg_to_rad(float(ring[2]))
		var bend: float = ring[4]
		var size: float = float(ring[3]) * _jitter[i].y
		var radius := (LIP_CENTRE_R - 0.1 if _tooth_ring[i] == 0 else throat_radius(y) - 0.04) + _jitter[i].z
		var closed := close_amount * bend
		tilt = lerpf(tilt, deg_to_rad(80.0), closed)
		radius = lerpf(radius, radius * 0.2, closed * (1.0 if _tooth_ring[i] == 0 else 0.0))
		var a := _tooth_angle[i] + _jitter[i].x
		var d := Vector3(cos(a), 0.0, sin(a))
		var up := (Vector3.UP * cos(tilt) - d * sin(tilt)).normalized()  # leans toward the axis
		var tangent := Vector3(-sin(a), 0.0, cos(a))
		var orient := Basis(tangent * size, up * size, tangent.cross(up) * size)
		_teeth.set_instance_transform(i, Transform3D(orient, d * radius + Vector3(0.0, y + 0.35 * closed * bend, 0.0)))
