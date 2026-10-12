class_name FxPresets
extends RefCounted

## Builders for the pooled FX nodes (docs/plan/10 §3). Everything is made once by ImpactFx / FxStage and reused: a
## hit only moves a node, sets two parameters and restarts it. No textures on disk: dots and flakes are generated.

const POP_SHADER := preload("res://src/shaders/fx_pop.gdshader")
const FLASH_SHADER := preload("res://src/shaders/fx_flash.gdshader")
const FONT := preload("res://assets/fonts/BarlowCondensed-SemiBold.ttf")

static var _dot: GradientTexture2D
static var _flake: ImageTexture


## Soft round glow, white centre to transparent rim.
static func dot() -> GradientTexture2D:
	if _dot == null:
		var g := Gradient.new()
		g.set_color(0, Color.WHITE)
		g.set_color(1, Color(1, 1, 1, 0))
		_dot = GradientTexture2D.new()
		_dot.gradient = g
		_dot.fill = GradientTexture2D.FILL_RADIAL
		_dot.fill_from = Vector2(0.5, 0.5)
		_dot.fill_to = Vector2(1.0, 0.5)
		_dot.width = 32
		_dot.height = 32
	return _dot


## 12x8 white rectangle: tinted and spun by the 2D confetti.
static func flake() -> ImageTexture:
	if _flake == null:
		var img := Image.create_empty(12, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_flake = ImageTexture.create_from_image(img)
	return _flake


## Colour over life: `from` fading to transparent `to`.
static func fade_ramp(from: Color, to: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, Color(to, 0.0))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


static func shrink_curve() -> CurveTexture:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	var t := CurveTexture.new()
	t.curve = c
	return t


## One reusable one-shot emitter of additive glow dots leaving along its +Y axis inside a `spread`° cone.
## `speed` m/s (min, max), `gravity` m/s² (down), `size` m per dot. The node owns its materials, so colour is per-spawn.
static func emitter3d(amount: int, life: float, speed: Vector2, spread: float, gravity: float, size: float, ramp: GradientTexture1D) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = spread
	pm.initial_velocity_min = speed.x
	pm.initial_velocity_max = speed.y
	pm.gravity = Vector3(0.0, -gravity, 0.0)
	pm.damping_min = 0.4
	pm.damping_max = 1.2
	pm.scale_min = 0.5
	pm.scale_max = 1.5
	pm.scale_curve = shrink_curve()
	pm.color_ramp = ramp
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = dot()
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.particles_anim_h_frames = 1
	m.particles_anim_v_frames = 1
	m.particles_anim_loop = false
	q.material = m
	p.draw_pass_1 = q
	return p


## Camera-facing impact pop; ImpactFx scales the node and drives the `progress` instance uniform.
static func pop_sprite() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var m := ShaderMaterial.new()
	m.shader = POP_SHADER
	q.material = m
	mi.mesh = q
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	return mi


static func label3d() -> Label3D:
	var l := Label3D.new()
	l.font = FONT
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0022
	l.outline_size = 14
	l.outline_modulate = Color(0.05, 0.02, 0.1, 0.9)
	l.shaded = false
	l.double_sided = true
	l.visible = false
	return l


## 2D confetti emitter (screen space); ImpactFx stage sets position / box / direction per spawn.
static func emitter2d(amount: int, life: float) -> GPUParticles2D:
	var p := GPUParticles2D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.85
	p.emitting = false
	p.texture = flake()
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.particle_flag_disable_z = true
	pm.angular_velocity_min = -720.0
	pm.angular_velocity_max = 720.0
	pm.scale_min = 0.6
	pm.scale_max = 1.6
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.25, 0.35))
	g.set_color(1, Color(0.3, 0.85, 1.0))
	g.add_point(0.25, Color(1.0, 0.85, 0.2))
	g.add_point(0.5, Color(0.4, 1.0, 0.5))
	g.add_point(0.75, Color(0.8, 0.4, 1.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	pm.color_initial_ramp = ramp
	pm.color_ramp = fade_ramp(Color.WHITE, Color.WHITE)
	p.process_material = pm
	return p
