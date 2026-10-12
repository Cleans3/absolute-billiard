shader_type spatial;
render_mode unshaded, blend_add, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled;
// Camera-facing impact pop (docs/plan/10 §3): hot core + expanding ring + star rays on one quad. ImpactFx drives
// `progress` 0 -> 1 per instance; the node scale is the size. Additive, so it never needs sorting or a light.

instance uniform float progress : hint_range(0.0, 1.0) = 0.0;
instance uniform vec4 tint : source_color = vec4(1.0, 0.85, 0.5, 1.0);
instance uniform float rays = 6.0;

void vertex() {
	mat4 mv = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	mv = mv * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = mv;
	MODELVIEW_NORMAL_MATRIX = mat3(mv);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float fade = 1.0 - progress;
	float core = exp(-r * r * 16.0) * fade * fade * 2.5;
	float ring_r = 0.12 + progress * 0.8;
	float ring = exp(-pow((r - ring_r) * 10.0, 2.0)) * fade * 1.4;
	float star = pow(abs(cos(a * rays * 0.5)), 24.0) * exp(-r * 3.0) * fade * 1.6;
	float v = (core + ring + star) * smoothstep(1.0, 0.8, r);
	ALBEDO = tint.rgb * v;
	ALPHA = 1.0;
}
