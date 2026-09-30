extends PerfFixture

## 07 §9 fixture: every visual_hook at once — the ViewOverlay ubershader at full uniforms (lights_out darkening,
## fog, shake), 8 one-shot-style GPUParticles3D bursts, 4 impact Decals — over the bar room. Reports the GPU cost of
## the stack against the same 13.0 ms budget. Needs a window.

const OVERLAY := preload("res://src/ui/ViewOverlay.tscn")
const JANK_TOL_MS := 1.0

var _cam: Camera3D
var _particles := 0


func _init() -> void:
	fixture_name = "perf_effects"


func _run() -> void:
	var vp := get_viewport()
	vp.scaling_3d_scale = float(arg("scale", 0.85))
	vp.msaa_3d = Viewport.MSAA_2X
	add_room()
	add_table()
	await get_tree().physics_frame
	spawn_balls(12)
	_cam = add_camera(Vector3(-2.6, 1.8, -0.4), TABLE_POS + Vector3(0, 0.8, 0))
	var layer := CanvasLayer.new()
	add_child(layer)
	var ov: ViewOverlay = OVERLAY.instantiate()
	layer.add_child(ov)
	ov.visible = true
	var mat := ov.material as ShaderMaterial
	mat.set_shader_parameter(&"light_level", 0.4)
	mat.set_shader_parameter(&"fog_density", 0.5)
	mat.set_shader_parameter(&"shake_amp", 1.0)
	for i in 8:
		_add_burst(TABLE_POS + Vector3(cos(i * TAU / 8.0) * 1.2, 1.0, sin(i * TAU / 8.0) * 0.8))
	var tex := GradientTexture2D.new()
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	for i in 4:
		var d := Decal.new()
		d.size = Vector3(0.6, 0.5, 0.6)
		d.texture_albedo = tex
		d.position = TABLE_POS + Vector3((i - 1.5) * 0.7, 0.92, 0.0)
		add_child(d)
	logger.begin(fixture_name)
	var seconds := float(arg("seconds", 30.0))
	while logger.elapsed_s() < seconds:
		await get_tree().process_frame
	vp.scaling_3d_scale = 1.0
	var limit := 1000.0 / 60.0 + JANK_TOL_MS
	var gpu_mean := logger.mean(logger.gpu_ms)
	check("gpu_frame_mean_all_effects", gpu_mean, 13.0, "<=", "ms", true, true, gpu_mean > 0.0)
	check("frames_within_vsync_pct", logger.pct_under(logger.frame_ms, limit), 95.0, ">=", "%", true)
	check("particles_alive", _particles, 2000, "<=", "particles", false, false)
	check("draw_calls_max", logger.draw_calls.size() if logger.draw_calls.is_empty() else _max_i(logger.draw_calls), 120, "<=", "calls", true, false)


func _max_i(a: PackedInt32Array) -> int:
	var m := 0
	for v in a:
		m = maxi(m, v)
	return m


func _add_burst(pos: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 128
	p.lifetime = 1.5
	p.position = pos
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 40.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.4
	pm.gravity = Vector3(0, -1.0, 0)
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.06, 0.06)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.albedo_color = Color(1.0, 0.7, 0.3)
	q.material = qm
	p.draw_pass_1 = q
	add_child(p)
	_particles += p.amount
