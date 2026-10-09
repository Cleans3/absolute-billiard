class_name SpeechBubble
extends Node3D
## A speech bubble over a head (C4, 06 P21): billboarded text on a rounded backing with a tail, popping in and fading out.
## The node origin is the tip of the tail; the bubble grows upward from it. One Label3D and one quad while a line is up,
## nothing drawn otherwise.

const PIXEL_SIZE := 0.0042
const FONT_SIZE := 44
const WRAP_PX := 560.0
const PAD := Vector2(0.10, 0.07)   ## metres of backing around the text
const TAIL_M := 0.14
const POP_SEC := 0.14
const FADE_SEC := 0.35
const NEAR_FAR_M := 6.0            ## at this distance the bubble is at its authored size; closer it shrinks, further it grows
const DIST_SCALE := Vector2(0.5, 1.5)

const _SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec2 size_m = vec2(1.0, 0.5);   // whole quad: body + tail, metres
uniform float tail_m = 0.14;
uniform float radius = 0.10;
uniform vec4 fill : source_color = vec4(1.0, 0.97, 0.86, 1.0);
uniform vec4 edge : source_color = vec4(0.16, 0.09, 0.04, 1.0);
uniform float alpha = 1.0;
varying vec2 p;
void vertex() {
	p = vec2(UV.x - 0.5, 0.5 - UV.y) * size_m;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	vec2 half_body = vec2(size_m.x * 0.5, (size_m.y - tail_m) * 0.5);
	vec2 q = abs(p - vec2(0.0, tail_m * 0.5)) - half_body + vec2(radius);
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float tip_y = -size_m.y * 0.5;
	float up = p.y - tip_y;                       // height above the tail tip
	float tail_d = max(abs(p.x) - up * 0.45, max(-up, up - tail_m * 1.6));
	float dd = min(d, tail_d);
	ALPHA = (1.0 - smoothstep(-0.004, 0.004, dd)) * alpha;
	ALBEDO = mix(fill.rgb, edge.rgb, smoothstep(-0.026, -0.016, dd));
}
"""

var _label: Label3D
var _back: MeshInstance3D
var _mat: ShaderMaterial
var _left := 0.0
var _total := 0.0
var _text := ""
var _pop := 1.0  ## the pop-in/fade factor of the scale


func _ready() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = Shader.new()
	_mat.shader.code = _SHADER
	_mat.render_priority = 1
	_back = MeshInstance3D.new()
	_back.mesh = QuadMesh.new()
	_back.material_override = _mat
	_back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_back)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.shaded = false
	_label.double_sided = true
	_label.pixel_size = PIXEL_SIZE
	_label.font_size = FONT_SIZE
	_label.outline_size = 0
	_label.modulate = Color(0.14, 0.08, 0.04)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.width = WRAP_PX
	_label.render_priority = 2
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_label)
	hide()
	set_process(false)


func text() -> String:
	return _text


func is_showing() -> bool:
	return _left > 0.0


## Show `text` for `seconds`: it replaces whatever is up.
func show_line(line: String, seconds: float) -> void:
	_text = line
	_label.text = line
	var px := ThemeDB.fallback_font.get_multiline_string_size(line, HORIZONTAL_ALIGNMENT_CENTER, WRAP_PX, FONT_SIZE)
	var body := Vector2(minf(px.x, WRAP_PX), px.y) * PIXEL_SIZE + PAD * 2.0
	var full := Vector2(body.x, body.y + TAIL_M)
	(_back.mesh as QuadMesh).size = full
	(_back.mesh as QuadMesh).center_offset = Vector3(0.0, full.y * 0.5, 0.0)
	_mat.set_shader_parameter(&"size_m", full)
	_mat.set_shader_parameter(&"tail_m", TAIL_M)
	_label.offset = Vector2(0.0, (TAIL_M + body.y * 0.5) / PIXEL_SIZE)
	_left = seconds
	_total = seconds
	show()
	_fade(0.0)
	set_process(true)


func hide_line() -> void:
	_left = 0.0
	_text = ""
	hide()
	set_process(false)


func _process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		hide_line()
		return
	_fade(minf(1.0, minf((_total - _left) / POP_SEC, _left / FADE_SEC)))


func _fade(a: float) -> void:
	_mat.set_shader_parameter(&"alpha", a)
	_label.modulate.a = a
	_pop = lerpf(0.7, 1.0, a)
	var cam := get_viewport().get_camera_3d()
	var k := clampf(cam.global_position.distance_to(global_position) / NEAR_FAR_M, DIST_SCALE.x, DIST_SCALE.y) if cam != null else 1.0
	scale = Vector3.ONE * _pop * k
