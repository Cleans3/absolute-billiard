class_name Materialise
extends RefCounted
## Fades any mesh in or out with a hologram glow (docs/plan/10 §3.6), whatever material it wears: the instance `transparency` fades the
## mesh itself (it is the ALPHA a StandardMaterial3D starts from), a shared additive overlay adds the shell and the climbing band. So the
## ball types (gimmicks, the cue ball) need no material of their own, and a ball material the shop or a skin changes still works.

const SHADER := preload("res://src/shaders/materialise.gdshader")
const FADE_PART := 0.7  ## the mesh itself is fully there at this progress; the glow runs on to 1

static var _overlay: ShaderMaterial


static func overlay() -> ShaderMaterial:
	if _overlay == null:
		_overlay = ShaderMaterial.new()
		_overlay.shader = SHADER
	return _overlay


## `p` 0 = gone, 1 = solid. At 1 the mesh is exactly as it was before (no overlay, opaque pipeline).
static func set_progress(mi: GeometryInstance3D, p: float) -> void:
	if p >= 1.0:
		mi.material_overlay = null
		mi.transparency = 0.0
		return
	p = maxf(p, 0.0)
	mi.material_overlay = overlay()
	mi.set_instance_shader_parameter(&"progress", p)
	mi.transparency = 1.0 - smoothstep(0.0, FADE_PART, p)
