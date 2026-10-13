class_name CutScreen
extends ColorRect
## The screen pass the in-room cutscenes use (docs/plan/09 §3.8, adhoc-1013c F3b): a colour wash over the room (red alert, green gas), a blur
## and a fade to black, one ColorRect + one shader, uniforms only. Hidden (no pass at all) while idle. Local presentation; it is not the
## drink effects' ViewOverlay, so an Effect expiring mid-cutscene cannot switch it off and the effects never pay for the mip chain.

const SHADER := preload("res://src/shaders/cut_screen.gdshader")

var active := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = -1  # under the HUD, like the ViewOverlay
	visible = false
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	material = mat


## `tint` washes the picture by `amount` 0..1, `blur` 0..1 is the gas, `dark` 0..1 fades to black, `wobble` 0..1 swims the picture.
func set_wash(tint: Color, amount: float, blur := 0.0, dark := 0.0, wobble := 0.0) -> void:
	active = amount > 0.001 or blur > 0.001 or dark > 0.001 or wobble > 0.001
	visible = active
	if not active:
		return
	var mat := material as ShaderMaterial
	mat.set_shader_parameter(&"tint", tint)
	mat.set_shader_parameter(&"amount", clampf(amount, 0.0, 1.0))
	mat.set_shader_parameter(&"blur", clampf(blur, 0.0, 1.0))
	mat.set_shader_parameter(&"dark", clampf(dark, 0.0, 1.0))
	mat.set_shader_parameter(&"wobble", clampf(wobble, 0.0, 1.0))


func clear() -> void:
	set_wash(Color.BLACK, 0.0)
